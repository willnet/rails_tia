require 'rspec/core'
require 'rspec/core/formatters'
require 'rails_tia/coverage_collector'
require 'rails_tia/described_class_support'

module RailsTia
  # RSpec formatter that records coverage dependencies per spec file as map fragments.
  class Formatter < CoverageCollector
    RSpec::Core::Formatters.register self, :start, :example_group_started, :example_group_finished, :example_started, :stop

    def initialize(_output)
      super()
      @described_class_support = DescribedClassSupport.new(root: @root) if @config.described_class_enabled?
    end

    def start(_notification)
      @previous_lines = project_lines(super())
    rescue StandardError
      # RSpec only sends :stop if all :start callbacks return successfully.
      unsubscribe
      raise
    end

    # Group start arrives before before(:context); group finish arrives after after(:context).
    def example_group_started(notification)
      switch_spec(relative(group_spec_path(notification.group)))
    end

    def example_group_finished(notification)
      return unless notification.group.parent_groups.size == 1

      switch_spec(nil)
    end

    def example_started(notification)
      count_example if @report
      switch_spec(relative(spec_path_of(notification.example)))
      if @described_class_support
        @map.add(@current_spec, @described_class_support.files_for(notification.example.example_group.described_class))
      end
    end

    def stop(notification)
      finish
      failed = notification.failed_examples.any? || RSpec.world.non_example_failure
      save(failed, rspec_version: RSpec::Core::Version::STRING, described_class: !!@described_class_support)
    end

    private

    def read_coverage
      # SimpleCov needs the cumulative counters, including hits from eager loading.
      Coverage.peek_result
    end

    def project_lines(snapshot)
      snapshot.each_with_object({}) do |(path, counts), files|
        next unless path.start_with?(@root)

        # Coverage.start without explicit modes returns line arrays directly.
        lines = counts.is_a?(Array) ? counts : counts[:lines]
        raise Error, 'RSpec mapping requires cumulative line coverage (lines: true)' unless lines

        files[path] = lines
      end
    end

    def project_files(snapshot)
      previous = @previous_lines
      @previous_lines = project_lines(snapshot)
      @previous_lines.filter_map do |path, lines|
        before = previous[path]
        touched = before ? before != lines : lines.any? { |hits| hits.to_i.positive? }
        path.delete_prefix(@root) if touched
      end
    end

    def spec_path_of(example)
      group_spec_path(example.example_group)
    end

    def group_spec_path(group)
      # Use the runnable top-level group’s spec, rather than the shared examples definition.
      metadata = group.parent_groups.last.metadata
      metadata[:absolute_file_path] || metadata[:file_path]
    end
  end
end
