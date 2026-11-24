require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'zip'
require 'rspec_tia/ci/git'
require 'rspec_tia/http'

module RspecTia
  module Ci
    class GithubActions < Git
      class Error < StandardError; end

      def merge_request?
        ENV['GITHUB_EVENT_NAME'] == 'pull_request'
      end

      def changed_files
        return [] unless merge_request?

        changed_paths("#{base_commit}..HEAD")
      end

      def labels
        return [] unless merge_request?

        labels = pull_request.fetch('labels', [])
        unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(Hash) && label['name'].is_a?(String) }
          raise Error, 'Invalid labels in the GitHub pull_request event'
        end

        labels.map { |label| label.fetch('name') }
      end

      def commit_message
        return unless merge_request?

        capture('git', 'log', '-1', '--pretty=%B', merge_checkout? ? 'HEAD^2' : 'HEAD')
      end

      def map_download_dir = File.join(@config.map_fragment_dir, 'github-actions')

      def fetch_map_fragments(dest_dir)
        return [] unless merge_request?

        run = map_run
        return [] unless run

        artifact = map_artifact(run)
        return [] if artifact.nil? || artifact.fetch('expired')

        archive = download_artifact(run, artifact.fetch('id'))
        return [] unless archive

        stage_map(archive, artifact.fetch('id'), dest_dir)
      end

      private

      def base_commit
        # Derive the baseline from the checked-out merge commit so a moving base branch
        # cannot make the Git diff and downloaded map describe different commits.
        @base_commit ||= merge_checkout? ? merge_checkout_base : head_merge_base
      end

      def merge_checkout_base
        capture('git', 'rev-parse', '--verify', 'HEAD^1').strip
      rescue CommandError => e
        raise Error, "Cannot read the PR merge commit's base parent. Set actions/checkout fetch-depth: 2. #{e.message}"
      end

      def head_merge_base
        unless checkout_sha == pull_request.dig('head', 'sha')
          raise Error, 'Check out the GitHub pull request merge commit or pull request head'
        end

        base_sha = pull_request.dig('base', 'sha')
        unless base_sha.is_a?(String) && base_sha.match?(/\A[0-9a-f]{40}\z/)
          raise Error, 'Missing or invalid base SHA in the GitHub pull_request event'
        end

        capture('git', 'merge-base', base_sha, 'HEAD').strip
      rescue TypeError
        raise Error, 'Invalid head or base data in the GitHub pull_request event'
      end

      def checkout_sha
        @checkout_sha ||= capture('git', 'rev-parse', 'HEAD').strip
      end

      def merge_checkout?
        ENV['GITHUB_REF'].to_s.match?(%r{\Arefs/pull/\d+/merge\z}) && checkout_sha == ENV['GITHUB_SHA']
      end

      def pull_request
        @pull_request ||= begin
          event = JSON.parse(File.read(environment('GITHUB_EVENT_PATH')))
          pr = event['pull_request'] if event.is_a?(Hash)
          raise Error, 'Missing pull_request data in the GitHub event' unless pr.is_a?(Hash)

          pr
        end
      rescue JSON::ParserError, SystemCallError => e
        raise Error, "Cannot read the GitHub pull_request event: #{e.message}"
      end

      def map_run
        workflow = option('map_workflow')
        unless workflow.match?(/\A(\d+|[\w.-]+\.ya?ml)\z/)
          raise Error, 'ci.github_actions.map_workflow must be a workflow filename or numeric ID'
        end

        event = option('map_event')
        unless %w(push schedule).include?(event)
          raise Error, 'ci.github_actions.map_event must be push or schedule'
        end

        query = URI.encode_www_form(branch: environment('GITHUB_BASE_REF'), event: event,
                                    status: 'success', head_sha: base_commit, per_page: 1)
        run = response_items("#{actions_path}/workflows/#{workflow}/runs?#{query}", 'workflow_runs').first
        if run && (run['head_sha'] != base_commit || !valid_id?(run['id']))
          raise Error, 'Invalid GitHub map workflow run or unexpected source commit'
        end

        run
      end

      def map_artifact(run)
        name = option('map_artifact_name')
        query = URI.encode_www_form(name: name, per_page: 2)
        artifacts = response_items("#{actions_path}/runs/#{run.fetch('id')}/artifacts?#{query}", 'artifacts')
        if artifacts.empty?
          warn "[rspec_tia] No #{name.inspect} map artifact in GitHub workflow run #{run.fetch('id')}"
          return
        end

        artifact = artifacts.first
        unless artifacts.size == 1 && artifact['name'] == name && valid_id?(artifact['id']) &&
               [true, false].include?(artifact['expired'])
          raise Error, "Expected one #{name.inspect} map artifact in GitHub workflow run #{run.fetch('id')}"
        end

        artifact
      end

      def download_artifact(run, artifact_id)
        http.get("#{actions_path}/artifacts/#{artifact_id}/zip")
      rescue Http::Gone
        nil
      rescue Http::NotFound
        # A 404 alone can also mean the token cannot access the resource.
        artifact = map_artifact(run)
        raise if artifact && artifact.fetch('id') == artifact_id && !artifact.fetch('expired')

        nil
      end

      def stage_map(archive, artifact_id, dest_dir)
        FileUtils.mkdir_p(dest_dir)
        Dir.mktmpdir('fetch-', dest_dir) do |staging|
          path = extract_map(archive, artifact_id, staging)
          map = Map.load(path)
          if map.empty? || map.commit_sha != base_commit || map.generated_at.nil?
            raise Map::FormatError, "Invalid map or unexpected source commit in GitHub artifact #{artifact_id}"
          end
          return [] if map.stale?(max_age_days: @config.map_max_age_days)

          output = File.join(dest_dir, File.basename(path))
          File.rename(path, output)
          [output]
        end
      rescue Zip::Error => e
        raise Map::FormatError, "Invalid ZIP for GitHub map artifact #{artifact_id}: #{e.message}"
      end

      def extract_map(archive, artifact_id, staging)
        path = nil
        Zip::File.open_buffer(StringIO.new(archive)) do |zip|
          entries = zip.entries.reject(&:directory?).select { |entry| entry.name.end_with?('.json', '.json.gz') }
          unless entries.size == 1
            raise Map::FormatError, 'Expected exactly one merged map (.json or .json.gz) in the GitHub artifact'
          end

          entry = entries.first
          extension = entry.name.end_with?('.gz') ? '.json.gz' : '.json'
          path = File.join(staging, "github-actions-#{artifact_id}#{extension}")
          File.binwrite(path, zip.get_input_stream(entry).read)
        end
        path
      end

      def response_items(path, key)
        payload = http.get_json(path)
        items = payload[key] if payload.is_a?(Hash)
        return items if items.is_a?(Array) && items.all?(Hash)

        raise Error, "Invalid GitHub API response for #{path}: expected #{key} array"
      rescue JSON::ParserError
        raise Error, "Invalid JSON in GitHub API response for #{path}"
      end

      def valid_id?(id) = id.is_a?(Integer) && id.positive?

      def option(name)
        value = @config.github_actions_options[name].to_s
        raise Error, "Set ci.github_actions.#{name} to fetch maps from GitHub Actions" if value.empty?

        value
      end

      def actions_path
        repository = environment('GITHUB_REPOSITORY')
        unless repository.match?(%r{\A[\w-]+/[\w.-]+\z})
          raise Error, 'Invalid GITHUB_REPOSITORY; expected owner/repository'
        end

        "/repos/#{repository}/actions"
      end

      def http
        @http ||= Http.new(
          base_url: environment('GITHUB_API_URL'),
          headers: {
            'Accept' => 'application/vnd.github+json',
            'Authorization' => "Bearer #{environment('GITHUB_TOKEN')}",
          },
        )
      end

      def environment(name)
        value = ENV[name].to_s
        raise Error, "Set #{name} to use the github_actions adapter" if value.empty?

        value
      end
    end
  end
end
