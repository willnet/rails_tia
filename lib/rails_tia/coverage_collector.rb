require 'coverage'
require 'set'
require 'rails_tia'
require 'rails_tia/run_report'
require 'rails_tia/rails_support'
require 'rails_tia/action_view_support'

module RailsTia
  class CoverageCollector
    def initialize
      @config = RailsTia.config
      @root = @config.root.end_with?('/') ? @config.root : "#{@config.root}/"
      @map = Map.new(generated_at: Time.now, commit_sha: RailsTia.commit_sha)
      @report = RunReport.for('map_worker', @config)
      @coverage_calls = 0
      @example_count = 0
      @current_spec = nil
      @rails_support = nil
      @action_view_support = nil
    end

    def start
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @report
      @rails_support ||= build_rails_support
      @action_view_support ||= build_action_view_support
      @tracking = { active_record: !!@rails_support, action_view: !!@action_view_support }
      if @config.rails_enabled? && @config.constant_reads_enabled?
        @constant_reads ||= build_constant_reads
      end
      @tracking[:constant_reads] = !!@constant_reads
      baseline = coverage_result
      @rails_support&.flush
      @action_view_support&.flush
      @object_allocations ||= build_object_allocations
      @object_allocations&.start
      @tracking[:object_allocations] = !!@object_allocations
      baseline
    end

    def switch_spec(spec)
      return if spec == @current_spec

      flush
      @current_spec = spec
    end

    def finish
      flush
      @map.specs.each { |spec| @map.add(spec, @suite_sources) } if @suite_sources
      @map
    ensure
      unsubscribe
    end

    def count_example
      @example_count += 1
    end

    def save(failed, described_class: false, **runner)
      if failed
        @map.mark_stale!
        warn '[rails_tia] Test run failed; saving the generated map as stale'
      end
      if @report
        save_fragment_with_report(failed, runner, described_class)
      else
        @map.dump(fragment_path)
      end
    end

    # Write a separate file for each parallel_tests process and CI node.
    # Reusing a filename would let processes overwrite dependencies recorded by other processes.
    def fragment_path
      return ENV['RAILS_TIA_FRAGMENT_PATH'] if ENV['RAILS_TIA_FRAGMENT_PATH']

      File.join(@config.map_fragment_dir, "map-#{fragment_suffix}.json.gz")
    end

    private

    def unsubscribe
      @object_allocations&.stop
      @object_allocations = nil
      @rails_support&.unsubscribe
      @action_view_support&.unsubscribe
      @rails_support = @action_view_support = nil
    end

    def fragment_suffix
      parts = [ENV['CI_NODE_INDEX'], ENV['TEST_ENV_NUMBER']].map { |v| v.to_s.empty? ? nil : v }.compact
      parts.empty? ? Process.pid.to_s : parts.join('-')
    end

    def coverage_result
      return read_coverage unless @report

      @coverage_calls += 1
      @report.measure(:coverage) { read_coverage }
    end

    def read_coverage
      Coverage.result(stop: false, clear: true)
    end

    def save_fragment_with_report(failed, runner, described_class)
      path = fragment_path
      json = nil
      @report.measure(:write_fragment) { @map.dump(path) { |serialized| json = serialized } }
      suite_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
      @report.write do
        {
          fragment_id: Digest::SHA256.hexdigest(json), fragment_bytes: File.size(path),
          spec_count: @map.specs.size, example_count: @example_count, coverage_calls: @coverage_calls,
          suite_seconds: suite_seconds, failed: !!failed,
          ruby_version: RUBY_VERSION, **runner,
          rails_version: Gem.loaded_specs['railties']&.version&.to_s,
          tracking: @tracking.merge(described_class: described_class),
        }
      end
    end

    def build_constant_reads
      require 'rails_tia/constant_reads'
      return ConstantReads.new(@config) unless @report

      @report.measure(:constant_index) { ConstantReads.new(@config) }
    rescue LoadError, StandardError => e
      warn "[rails_tia] Cannot index constant reads: #{e.class}: #{e.message}; marking the map stale for a full run"
      @map.mark_stale!
      nil
    end

    def build_object_allocations
      return unless @config.rails_enabled? && @config.object_allocations_enabled?

      require 'rails_tia/object_allocations'
      ObjectAllocations.new(@root, directories: @config.app_dirs)
    rescue LoadError => e
      message = "Cannot load object allocation tracking: #{e.message}"
      raise Error, message if @config.object_allocations_required?

      warn "[rails_tia] #{message}; marking the map stale for a full run"
      @map.mark_stale!
      nil
    end

    def build_rails_support
      return nil unless @config.rails_enabled? && @config.active_record_enabled?
      return nil unless RailsSupport.available?

      RailsSupport.new(root: @root).subscribe
    end

    def build_action_view_support
      return nil unless @config.rails_enabled? && @config.action_view_enabled?
      return nil unless ActionViewSupport.available?

      ActionViewSupport.new(root: @root).subscribe
    end

    def relative(path)
      absolute = File.expand_path(path.to_s.sub(%r{\A\./}, ''), @config.root)
      absolute.start_with?(@root) ? absolute.delete_prefix(@root) : absolute
    end

    def flush
      allocated = @object_allocations&.flush || []
      result = coverage_result
      touched = (@rails_support&.flush || []) + (@action_view_support&.flush || [])
      files = @report ? @report.measure(:scan) { project_files(result) } : project_files(result)
      sources = files + touched + allocated
      if @current_spec.nil?
        # Attribute before/after(:suite) dependencies to every spec, not just the first or last.
        (@suite_sources ||= Set.new).merge(sources)
      else
        Array(@current_spec).each { |file| @map.add(file, sources) }
      end
    end

    def append_covered_file(files, path, lines, previous = nil)
      file = path.delete_prefix(@root)
      files << file
      files.concat(@constant_reads.sources(file, lines, previous)) if @constant_reads
    end

    def project_files(result)
      result.each_with_object([]) do |(path, coverage), files|
        next unless path.start_with?(@root)

        lines = coverage[:lines]
        next if lines.nil?
        next unless lines.any? { |hits| hits.to_i.positive? }

        append_covered_file(files, path, lines)
      end
    end
  end
end
