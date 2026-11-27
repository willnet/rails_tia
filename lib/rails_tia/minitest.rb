require 'rails_tia/boot'
require 'minitest'
require 'tmpdir'
require 'rails_tia/coverage_collector'

module RailsTia
  class MinitestCollector < CoverageCollector
    class << self
      attr_accessor :current
    end

    def initialize
      super
      @owner = Thread.current
      @parent = Process.pid
      @workers = 0
      @declarations = {}
      @runnable_files = {}
      # const_source_location only identifies the first file to open a class.
      @class_trace = TracePoint.new(:class) do |event|
        klass = event.self
        next unless klass.is_a?(Class) && klass < ::Minitest::Runnable

        path = test_file(event.path)
        (@declarations[klass] ||= Set.new) << path if path
      end
      @class_trace.enable
      # A load error or interrupted worker pool may never reach after_run.
      Map.new(generated_at: Time.at(0), commit_sha: RailsTia.commit_sha).dump(fragment_path)
    end

    def start
      @class_trace.disable
      super
      install_rails_worker_hooks
    end

    def collect
      Dir.mktmpdir('rails-tia-workers') do |dir|
        @directory = dir
        passed = yield
        switch_spec(nil)
        merge_workers
        raise Error, @collection_error if @collection_error
        @passed = passed
      end
    end

    def publish
      return unless Process.pid == @parent && @tracking

      finish
      save(!@passed, minitest_version: ::Minitest::VERSION)
    end

    def enter(klass, name)
      if defined?(::ActiveSupport::Testing::Isolation) && klass < ::ActiveSupport::Testing::Isolation
        @collection_error ||= "Cannot collect #{klass}##{name} with ActiveSupport::Testing::Isolation"
        return
      end
      if Thread.current != @owner
        raise Error, 'Minitest coverage collection does not support thread-parallel tests'
      end

      if Process.pid != @parent && @workers.zero?
        raise Error, 'Minitest forked outside the supported Rails process pool'
      end

      method = klass.instance_method(name)
      # Inherited and mixed-in tests run when their consumer file is selected.
      # A reopened class can also define its own methods in separate test files.
      files = runnable_files(klass)
      path = test_file(method.source_location&.first) if method.owner == klass
      files = files | [path] if path
      if files.empty?
        @collection_error ||= "Cannot locate #{klass}##{name} under spec_glob #{@config.spec_glob.inspect}"
        return
      end

      if files.size > 1 && files != @current_spec
        files.each { |file| @map.add(file, files) }
      end
      switch_spec(files)
      count_example
    end

    attr_writer :workers

    def start_worker
      # The fork inherits the parent’s pre-fork counters and timings.
      @coverage_calls = @example_count = 0
      @report = RunReport.for('map_worker', @config) if @report
    end

    def write_worker
      data = finish.to_h
      data['collection_error'] = @collection_error
      data['example_count'] = @example_count
      data['coverage_calls'] = @coverage_calls
      data['timings'] = @report.timings if @report
      path = File.join(@directory, "#{Process.pid}.json")
      File.write("#{path}.tmp", JSON.generate(data))
      File.rename("#{path}.tmp", path)
    end

    private

    def coverage_result
      unless Coverage.running?
        raise Error, 'Coverage stopped before Minitest map collection finished. Disable SimpleCov or other coverage tools during map generation.'
      end
      super
    end

    def merge_workers
      files = Dir.glob(File.join(@directory, '*.json'))
      unless files.size == @workers
        raise Error, "Incomplete Minitest coverage: expected #{@workers} worker maps, received #{files.size}"
      end

      files.each do |path|
        data = JSON.parse(File.read(path))
        @collection_error ||= data['collection_error']
        @map.merge!(Map.new.load_hash(data))
        @example_count += data.fetch('example_count')
        @coverage_calls += data.fetch('coverage_calls')
        data.fetch('timings').each { |key, value| @report.timings[key.to_sym] += value } if @report
      end
    end

    def test_file(path)
      return unless path

      file = relative(path)
      file if File.fnmatch?(@config.spec_glob, file, Configuration::FNMATCH_FLAGS)
    end

    def runnable_files(klass)
      @runnable_files[klass] ||= begin
        paths = Set.new
        klass.ancestors.each do |ancestor|
          files = @declarations[ancestor]
          next unless files

          # A subclass can acquire tests from a reopening of its superclass.
          paths.merge(files) if ancestor == klass || files.size > 1
        end
        origin = class_file(klass)
        paths << origin if origin
        paths.to_a
      end
    end

    def class_file(klass)
      name = Module.instance_method(:name).bind_call(klass)
      if name && Object.const_defined?(name, false) && Object.const_get(name, false).equal?(klass)
        test_file(Object.const_source_location(name, false)&.first)
      end
    end

    def install_rails_worker_hooks
      return unless defined?(::ActiveSupport::Testing::Parallelization::Worker)

      parallel = ::ActiveSupport::Testing::Parallelization
      parallel.prepend(ProcessPool)
      parallel::Worker.prepend(Worker)
    end

    module ProcessPool
      def start
        MinitestCollector.current.workers = size
        super
      end
    end

    # Rails sends results back to a reporter in the parent. Coverage and
    # ActiveSupport notifications must be read in the process running the test.
    module Worker
      def perform_job(job)
        collect_coverage { |collector| collector.enter(job[0], job[1]) }
        super
      end

      def work_from_queue
        collect_coverage(&:start_worker)
        super
      ensure
        collect_coverage { |collector| collector.switch_spec(nil) }
      end

      def run_cleanup
        super
        collect_coverage(&:write_worker)
      end

      private

      def collect_coverage
        yield MinitestCollector.current unless @rails_tia_collection_failed
      rescue StandardError => error
        # Rails deregisters the worker after cleanup returns. Leave its map
        # missing so the parent rejects the run after the test queue drains.
        @rails_tia_collection_failed = true
        warn "[rails_tia] Cannot collect Minitest worker map: #{error.message}"
      end
    end

    module Runner
      def init_plugins(...)
        super
        # Rails can load test files while Minitest parses its options.
        MinitestCollector.current.start
        reporter << LocalReporter.new
      end

      def run(...)
        MinitestCollector.current.collect { super }
      end
    end

    class LocalReporter < ::Minitest::AbstractReporter
      def prerecord(klass, name)
        # Rails replays remote results using a name-only stand-in for the class.
        MinitestCollector.current.enter(klass, name) if klass.is_a?(Class)
      end
    end

    module Suite
      # Minitest 6 renamed the class-level suite entry point.
      define_method(::Minitest::Runnable.respond_to?(:run_suite) ? :run_suite : :run) do |*args|
        super(*args)
      ensure
        MinitestCollector.current.switch_spec(nil)
      end
    end
  end
end

RailsTia::MinitestCollector.current = RailsTia::MinitestCollector.new
Minitest.singleton_class.prepend(RailsTia::MinitestCollector::Runner)
Minitest::Runnable.singleton_class.prepend(RailsTia::MinitestCollector::Suite)
# after_run hooks run in reverse registration order, including application hooks.
Minitest.after_run { RailsTia::MinitestCollector.current.publish }
