require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tempfile'
require 'time'
require 'zlib'

module RailsTia
  class RunReport
    SCHEMA_VERSION = 1
    class Error < StandardError; end

    def self.for(type, config)
      path = ENV['RAILS_TIA_REPORT_DIR']
      new(type, config.absolute(path)) unless path.to_s.empty?
    end

    def self.load_selection(path)
      data = JSON.parse(File.read(path))
      valid = data.is_a?(Hash) && data['schema_version'] == SCHEMA_VERSION && data['type'] == 'select' &&
        data['report_id'].is_a?(String) && !data['report_id'].empty? &&
        [true, false].include?(data['full_run']) &&
        data['selected_specs'].is_a?(Array) && data['selected_specs'].all?(String)
      raise Error, "Invalid selection report: #{path}" unless valid

      data
    rescue JSON::ParserError => e
      raise Error, "Invalid selection report: #{path}: #{e.message}"
    rescue SystemCallError, IOError => e
      raise Error, "Cannot read selection report #{path}: #{e.message}"
    end

    def initialize(type, directory)
      @type = type
      @directory = directory
      @timings = Hash.new(0.0)
      @id = SecureRandom.uuid
    end

    attr_reader :timings

    def measure(key)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      @timings[key] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      result
    end

    def merge_map(fragments, path)
      fragment_ids = []
      map = measure(:merge) do
        Map.merge_files(fragments) { |json| fragment_ids << Digest::SHA256.hexdigest(json) }
      end
      json = nil
      measure(:write_map) { map.dump(path) { |serialized| json = serialized } }
      write do
        counts = map.sources.to_h { |source| [source, map.specs_for(source).size] }
        {
          map_id: measure(:archive_map) { archive_map(json) }, map_commit_sha: map.commit_sha,
          generated_at: map.generated_at&.utc&.iso8601,
          fragment_ids: fragment_ids, fragment_count: fragments.size, spec_count: map.specs.size,
          source_count: counts.size, edge_count: counts.values.sum,
          top_sources: counts.sort_by { |source, count| [-count, source] }.first(10).to_h,
        }
      end
      map
    end

    def write
      path = File.join(@directory, "#{@type}-#{@id}.json")
      data = {
        schema_version: SCHEMA_VERSION, type: @type, report_id: @id, recorded_at: Time.now.utc.iso8601(6),
        rails_tia_version: VERSION, commit_sha: RailsTia.commit_sha,
        repository: ENV['GITHUB_REPOSITORY'] || ENV['CI_PROJECT_PATH'],
        run_id: ENV['GITHUB_RUN_ID'] || ENV['CI_PIPELINE_ID'], attempt: ENV['GITHUB_RUN_ATTEMPT'],
        job: ENV['GITHUB_JOB'] || ENV['CI_JOB_NAME'], job_id: ENV['CI_JOB_ID'],
        node: ENV['CI_NODE_INDEX'], worker: ENV['TEST_ENV_NUMBER'], pid: Process.pid,
      }.merge(yield)
      data[:timings_seconds] = @timings unless @timings.empty?
      publish(path) { |file| file.write(JSON.generate(data)) }
      path
    rescue SystemCallError, IOError, Zlib::Error, JSON::GeneratorError, EncodingError => e
      warn "[rails_tia] Cannot save run report #{path}: #{e.message}"
      nil
    end

    private

    def archive_map(json)
      id = Digest::SHA256.hexdigest(json)
      path = File.join(@directory, 'maps', "#{id}.json.gz")
      unless File.exist?(path)
        publish(path) do |file|
          gzip = Zlib::GzipWriter.new(file)
          gzip.mtime = 0
          gzip.write(json)
          gzip.finish
        end
      end
      id
    end

    def publish(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      Tempfile.create('.rails-tia-', dir) do |file|
        file.binmode
        yield file
        file.chmod(0o644 & ~File.umask)
        file.close
        File.rename(file.path, path)
      end
    end
  end
end
