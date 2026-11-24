require 'coverage'
require 'rspec/core'
require 'rspec/core/formatters'
require 'set'
require 'rails_tia'
require 'rails_tia/run_report'
require 'rails_tia/rails_support'
require 'rails_tia/action_view_support'
require 'rails_tia/described_class_support'

module RailsTia
  # RSpec formatter that records coverage dependencies per spec file as map fragments.
  #
  #   RUBYOPT="-rrails_tia/boot" bundle exec rspec \
  #     --require rails_tia/formatter --format RailsTia::Formatter
  #
  # How it works:
  #   - Clear coverage once at suite start. With eager_load enabled, boot executes
  #     every class definition; retaining those hits would link every spec to every file.
  #   - Call Coverage.result(clear: true) whenever the spec file changes.
  #     Each result then contains only files touched by that spec, avoiding cumulative diffs.
  #
  # Collect coverage per spec file because per-example collection increases calls by two orders of magnitude.
  # Observed collection cost per spec file was 25–31 ms.
  class Formatter
    RSpec::Core::Formatters.register self, :start, :example_group_started, :example_group_finished, :example_started, :stop

    def initialize(_output)
      @config = RailsTia.config
      @root = @config.root.end_with?('/') ? @config.root : "#{@config.root}/"
      @map = Map.new(generated_at: Time.now, commit_sha: RailsTia.commit_sha)
      @report = RunReport.for('map_worker', @config)
      @coverage_calls = 0
      @example_count = 0
      @current_spec = nil
      @rails_support = nil
      @action_view_support = nil
      @described_class_support = DescribedClassSupport.new(root: @root) if @config.described_class_enabled?
    end

    def start(_notification)
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @report
      @rails_support ||= build_rails_support
      @action_view_support ||= build_action_view_support
      # Discard lines executed during boot and spec loading.
      coverage_result
      @rails_support&.flush
      @action_view_support&.flush
    end

    # Group start arrives before before(:context); group finish arrives after after(:context).
    def example_group_started(notification)
      switch_spec(relative(group_spec_path(notification.group)))
    end

    def example_group_finished(notification)
      return unless notification.group.parent_groups.size == 1

      flush
      @current_spec = nil
    end

    def example_started(notification)
      @example_count += 1 if @report
      switch_spec(relative(spec_path_of(notification.example)))
      if @described_class_support
        @map.add(@current_spec, @described_class_support.files_for(notification.example.example_group.described_class))
      end
    end

    def stop(notification)
      flush
      @map.specs.each { |spec| @map.add(spec, (@suite_sources || []).to_a) }
      failed = notification.failed_examples.any? || RSpec.world.non_example_failure
      if failed
        # Maps with unexecuted paths due to failed hooks or fail-fast must not pass freshness checks.
        @map.load_hash(@map.to_h.merge('generated_at' => Time.at(0).utc.iso8601))
        warn '[rails_tia] Test run failed; saving the generated map as stale'
      end
      if @report
        save_fragment_with_report(failed)
      else
        @map.dump(fragment_path)
      end
    ensure
      @rails_support&.unsubscribe
      @action_view_support&.unsubscribe
      @rails_support = nil
      @action_view_support = nil
    end

    private

    def coverage_result
      return Coverage.result(stop: false, clear: true) unless @report

      @coverage_calls += 1
      @report.measure(:coverage) { Coverage.result(stop: false, clear: true) }
    end

    def save_fragment_with_report(failed)
      path = fragment_path
      json = nil
      @report.measure(:write_fragment) { @map.dump(path) { |serialized| json = serialized } }
      suite_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
      @report.write do
        {
          fragment_id: Digest::SHA256.hexdigest(json), fragment_bytes: File.size(path),
          spec_count: @map.specs.size, example_count: @example_count, coverage_calls: @coverage_calls,
          suite_seconds: suite_seconds, failed: !!failed,
          ruby_version: RUBY_VERSION, rspec_version: RSpec::Core::Version::STRING,
          rails_version: Gem.loaded_specs['railties']&.version&.to_s,
          tracking: { active_record: !!@rails_support, action_view: !!@action_view_support,
                      described_class: !!@described_class_support },
        }
      end
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

    def switch_spec(spec)
      return if spec == @current_spec

      flush
      @current_spec = spec
    end

    def spec_path_of(example)
      group_spec_path(example.example_group)
    end

    def group_spec_path(group)
      # Use the runnable top-level group’s spec, rather than the shared examples definition.
      metadata = group.parent_groups.last.metadata
      metadata[:absolute_file_path] || metadata[:file_path]
    end

    def relative(path)
      absolute = File.expand_path(path.to_s.sub(%r{\A\./}, ''), @config.root)
      absolute.start_with?(@root) ? absolute.delete_prefix(@root) : absolute
    end

    def flush
      result = coverage_result
      touched = (@rails_support&.flush || []) + (@action_view_support&.flush || [])
      files = @report ? @report.measure(:scan) { project_files(result) } : project_files(result)
      sources = files + touched
      if @current_spec.nil?
        # Attribute before/after(:suite) dependencies to every spec, not just the first or last.
        (@suite_sources ||= Set.new).merge(sources)
      else
        @map.add(@current_spec, sources)
      end
    end

    def project_files(result)
      result.filter_map do |path, coverage|
        next unless path.start_with?(@root)

        lines = coverage[:lines]
        next if lines.nil?
        next unless lines.any? { |hits| hits.to_i.positive? }

        path.delete_prefix(@root)
      end
    end

    # Write a separate file for each parallel_tests process and CI node.
    # Reusing a filename would let processes overwrite dependencies recorded by other processes.
    def fragment_path
      return ENV['RAILS_TIA_FRAGMENT_PATH'] if ENV['RAILS_TIA_FRAGMENT_PATH']

      File.join(@config.map_fragment_dir, "map-#{fragment_suffix}.json.gz")
    end

    def fragment_suffix
      parts = [ENV['CI_NODE_INDEX'], ENV['TEST_ENV_NUMBER']].map { |v| v.to_s.empty? ? nil : v }.compact
      parts.empty? ? Process.pid.to_s : parts.join('-')
    end
  end
end
