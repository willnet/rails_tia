require 'rspec/core'
require 'rspec/core/formatters'
require 'rails_tia/coverage_collector'
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
  class Formatter < CoverageCollector
    RSpec::Core::Formatters.register self, :start, :example_group_started, :example_group_finished, :example_started, :stop

    def initialize(_output)
      super()
      @described_class_support = DescribedClassSupport.new(root: @root) if @config.described_class_enabled?
    end

    def start(_notification)
      super()
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
