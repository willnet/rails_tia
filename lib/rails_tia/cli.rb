require 'optparse'
require 'rails_tia'
require 'rails_tia/audit'
require 'rails_tia/ci'
require 'rails_tia/junit_report'
require 'rails_tia/metrics'
require 'rails_tia/run_report'

module RailsTia
  class Cli
    USAGE = <<~TEXT.freeze
      Usage: rails-tia <command> [options]

        select                Print selected specs (or full_run_token for a full run)
        map merge             Merge map fragments into a single map
        map fetch             Fetch and merge map fragments from CI
        audit                 Compare full-suite results with predictions to detect missed failures
        doctor                Check configuration and environment
        version               Print the version

      Common options:
        --config PATH         Configuration file (default: .rails_tia.yml)
        --root PATH           Project root (default: current directory)

      Set RAILS_TIA_REPORT_DIR to write JSON reports for CI storage.
    TEXT

    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {}
    end

    def run
      command = @argv.shift
      case command
      when 'select' then select
      when 'map' then map_command
      when 'audit' then audit
      when 'doctor' then doctor
      when 'version', '--version', '-v' then puts(VERSION) || 0
      when nil, 'help', '--help', '-h' then puts(USAGE) || 0
      else
        warn "Unknown command: #{command}\n\n#{USAGE}"
        1
      end
    rescue Ci::Gitlab::AuthenticationError, Ci::GithubActions::Error, Http::Error, Ci::Git::CommandError,
           Ci::UnknownAdapterError, Ci::Base::UnsupportedError, Map::FormatError, RunReport::Error, Errno::ENOENT => e
      warn "[rails_tia] #{e.message}"
      1
    end

    private

    def select
      parse!('select') do |parser|
        parser.on('--junit-dir DIR', 'JUnit XML directory for timing-based savings estimates') { |v| @options[:junit_dir] = v }
        parser.on('--metrics PATH', 'Metrics output path') { |v| @options[:metrics] = v }
        parser.on('--changed-files-from PATH', 'Read changed files from a file instead of CI (- for stdin)') do |v|
          @options[:changed_files_from] = v
        end
      end

      report = RunReport.for('select', config)
      map_id = nil
      map = load_map { |json| map_id = Digest::SHA256.hexdigest(json) if report }
      result = Predictor.new(config: config, map: map).call(select_context, trace: !!report)

      metrics = Metrics.new(config: config, result: result, junit_report: junit_report(@options[:junit_dir]))
      data = metrics.to_h
      metrics.write(@options[:metrics] || config.metrics_path, data: data)
      report&.write do
        data.merge(
          'map_id' => map_id, 'changed_files' => result.sources, 'selected_specs' => result.specs,
          'reason_code' => result.reason_code, 'matches' => result.matches,
        )
      end
      puts(result.full_run? ? config.full_run_token : result.specs)
      warn metrics.summary(data)
      0
    end

    def map_command
      case @argv.shift
      when 'merge' then map_merge
      when 'fetch' then map_fetch
      else
        warn "Usage: rails-tia map [merge|fetch]"
        1
      end
    end

    def map_merge
      parse!('map merge') do |parser|
        parser.on('--fragments DIR', 'Map fragment directory') { |v| @options[:fragments] = v }
        parser.on('-o', '--output PATH', 'Merged map output path') { |v| @options[:output] = v }
      end

      dir = @options[:fragments] || config.map_fragment_dir
      fragments = Dir.glob(File.join(dir, '*.json*')).sort
      if fragments.empty?
        warn "[rails_tia] No map fragments found: #{dir}"
        return 1
      end

      merge_fragments(fragments)
    end

    def map_fetch
      parse!('map fetch') do |parser|
        parser.on('--dest DIR', 'Fragment download directory') { |v| @options[:dest] = v }
        parser.on('--[no-]merge', 'Merge after downloading (default: enabled)') { |v| @options[:merge] = v }
      end

      adapter = Ci.build(config)
      dest = @options[:dest] || adapter.map_download_dir
      fragments = adapter.fetch_map_fragments(dest)
      if fragments.empty?
        # Ensure even a reused workspace falls back to a full run when no map is available.
        File.delete(config.map_path) if File.exist?(config.map_path)
        warn '[rails_tia] No map fragments available (selection will fall back to a full run)'
        return 0
      end

      warn "[rails_tia] Fetched #{fragments.size} fragments -> #{dest}"
      return 0 if @options[:merge] == false

      merge_fragments(fragments)
    end

    def merge_fragments(fragments)
      path = @options[:output] || config.map_path
      report = RunReport.for('map_merge', config)
      if report
        map = report.merge_map(fragments, path)
      else
        map = Map.merge_files(fragments)
        map.dump(path)
      end
      warn format('[rails_tia] Merged %d fragments -> %s (%d specs / %d sources)',
                  fragments.size, path, map.specs.size, map.sources.size)
      0
    end

    def audit
      parse!('audit') do |parser|
        parser.on('--junit DIR', 'JUnit XML directory from a full-suite run') { |v| @options[:junit] = v }
        parser.on('--predicted PATH', 'Predicted spec list (one path per line)') { |v| @options[:predicted] = v }
        parser.on('--selection-report PATH', 'Use the JSON report from select as the prediction') { |v| @options[:selection_report] = v }
        parser.on('--expect-junit FILE', 'Expected XML path relative to --junit (repeat per shard)') do |v|
          (@options[:expected_junit] ||= []) << v
        end
      end

      unless @options[:junit] && [@options[:predicted], @options[:selection_report]].compact.one?
        warn '[rails_tia] Required options: --junit and exactly one of --predicted or --selection-report'
        return 1
      end

      if @options[:selection_report]
        selection = RunReport.load_selection(@options[:selection_report])
        if selection['commit_sha'] && RailsTia.commit_sha && selection['commit_sha'] != RailsTia.commit_sha
          raise RunReport::Error, 'Selection report is from a different commit'
        end
        predicted = selection.fetch('selected_specs')
        full_run = selection.fetch('full_run')
      else
        predicted = File.readlines(@options[:predicted], chomp: true).reject(&:empty?)
        full_run = predicted == [config.full_run_token]
      end

      expected = @options.fetch(:expected_junit, [])
      junit = JunitReport.load_dir(@options[:junit], expected_files: expected)
      result = Audit.new(junit_report: junit, predicted_specs: predicted, full_run: full_run).call
      report = RunReport.for('audit', config)
      report&.write do
        valid = result.validation_errors.empty?
        {
          prediction_id: selection&.fetch('report_id'), map_id: selection&.fetch('map_id', nil),
          full_run: full_run, valid: valid, failed_specs: result.failed_specs.sort,
          missed_specs: valid ? result.missed_specs.sort : nil, validation_errors: result.validation_errors,
          junit_file_count: junit.parsed_file_count, expected_junit_files: expected,
          missing_junit_files: junit.missing_files, junit_complete: junit.complete?,
        }
      end
      warn result.summary
      result.ok? ? 0 : 1
    end

    def doctor
      parse!('doctor')
      checks = [
        ['Configuration', config_status],
        ['Spec discovery', spec_status],
        ['Coverage map', map_status],
        ['CI adapter', adapter_status],
        ['Static mappings', static_mapping_status],
      ]
      ok = checks.all? { |_, (result, _)| result }
      checks.each { |name, (result, detail)| puts format('%s %-16s %s', result ? 'ok  ' : 'NG  ', name, detail) }
      ok ? 0 : 1
    end

    def config_status
      path = @options[:config] || File.join(root, Configuration::DEFAULT_PATH)
      File.exist?(path) ? [true, path] : [false, "#{path} not found (using defaults)"]
    end

    def spec_status
      count = config.all_specs.size
      [count.positive?, "#{config.spec_glob} -> #{count} specs"]
    end

    def map_status
      return [false, "#{config.map_path} does not exist"] unless File.exist?(config.map_path)

      map = Map.load(config.map_path)
      stale = map.stale?(max_age_days: config.map_max_age_days)
      detail = "#{map.specs.size} specs / #{map.sources.size} sources / generated #{map.generated_at&.utc&.iso8601 || 'unknown'}"
      [!stale, stale ? "#{detail} (stale)" : detail]
    rescue Map::FormatError => e
      [false, e.message]
    end

    def adapter_status
      adapter = Ci.build(config)
      [true, "#{adapter.class.name} (MR: #{adapter.merge_request?})"]
    rescue Ci::UnknownAdapterError => e
      [false, e.message]
    end

    def static_mapping_status
      StaticMapping.new(config.static_mapping_rules, root: root)
      [true, "#{config.static_mapping_rules.size} rules"]
    rescue RegexpError, KeyError => e
      [false, e.message]
    end

    def parse!(command)
      OptionParser.new do |parser|
        parser.banner = "Usage: rails-tia #{command} [options]"
        parser.on('--config PATH') { |v| @options[:config] = v }
        parser.on('--root PATH') { |v| @options[:root] = v }
        yield parser if block_given?
      end.parse!(@argv)
    end

    def root
      @options[:root] || Dir.pwd
    end

    def config
      @config ||= Configuration.load(@options[:config], root: root)
    end

    # Allow changed files to be supplied externally.
    # This supports offline evaluation of savings and missed failures using historical merge commits.
    def select_context
      source = @options[:changed_files_from]
      return Ci.build(config).context if source.nil?

      lines = source == '-' ? $stdin.read : File.read(source)
      Context.new(
        changed_files: lines.split("\n").map(&:strip).reject(&:empty?),
        merge_request: true,
      )
    end

    def load_map(&on_json)
      path = config.map_path
      return Map.new unless File.exist?(path)

      Map.load(path, &on_json)
    end

    def junit_report(dir)
      return nil if dir.nil? || !Dir.exist?(dir)

      JunitReport.load_dir(dir)
    end
  end
end
