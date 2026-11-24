require 'open3'
require 'rspec_tia/cli'

RSpec.describe RspecTia::Ci::GithubActions do
  let(:cli) { RspecTia::Cli }
  let(:http) { instance_double(RspecTia::Http) }
  let(:actions_path) { '/repos/example/app/actions' }
  let(:artifact) { { 'id' => 202, 'name' => 'rspec-tia-map', 'expired' => false } }

  around do |example|
    values = {
      'GITHUB_EVENT_NAME' => 'pull_request',
      'GITHUB_REF' => 'refs/pull/1/merge',
      'GITHUB_BASE_REF' => 'main',
      'GITHUB_REPOSITORY' => 'example/app',
      'GITHUB_API_URL' => 'https://api.github.example',
      'GITHUB_TOKEN' => 'test-token',
    }
    original = ENV.to_h.slice(*values.keys, 'GITHUB_EVENT_PATH', 'GITHUB_SHA')
    ENV.update(values)
    with_project(%w(spec/source_spec.rb spec/base_spec.rb lib/source.rb lib/base.rb)) do |root|
      @root = root
      build_repository
      write_config
      example.run
    end
  ensure
    (values.keys + %w(GITHUB_EVENT_PATH GITHUB_SHA)).each { |key| ENV[key] = original[key] }
  end

  def git(*args, root: @root)
    output, status = Open3.capture2e('git', '-c', 'commit.gpgsign=false', '-c', 'user.name=Test',
                                    '-c', 'user.email=test@example.com', *args, chdir: root)
    raise output unless status.success?

    output.strip
  end

  def build_repository
    git('init', '-qb', 'main')
    git('add', '.')
    git('commit', '-qm', 'Initial tree')
    @ancestor = git('rev-parse', 'HEAD')
    git('switch', '-qc', 'topic')
    git('mv', 'lib/source.rb', 'lib/renamed.rb')
    git('commit', '-qm', 'Rename source')
    @head = git('rev-parse', 'HEAD')
    git('switch', '-q', 'main')
    File.write(File.join(@root, 'lib/base.rb'), '# changed on main')
    git('commit', '-qam', 'Advance main')
    @base = git('rev-parse', 'HEAD')
    git('merge', '--no-ff', '-qm', 'GitHub merge commit', 'topic')
    ENV['GITHUB_SHA'] = git('rev-parse', 'HEAD')
    ENV['GITHUB_EVENT_PATH'] = File.join(@root, 'event.json')
    write_event
  end

  def write_event(labels: [])
    File.write(ENV.fetch('GITHUB_EVENT_PATH'), JSON.generate(pull_request: {
      head: { sha: @head }, base: { sha: @base }, labels: labels.map { |name| { name: name } },
    }))
  end

  def write_config(event: 'push', workflow: 'rspec.yml', commit_message_tokens: [])
    File.write(File.join(@root, '.rspec_tia.yml'), <<~YAML)
      ci:
        adapter: github_actions
        github_actions:
          map_workflow: #{workflow.to_json}
          map_event: #{event.to_json}
      full_run:
        labels: [run-all]
        commit_message_tokens: #{commit_message_tokens.to_json}
    YAML
  end

  def config
    RspecTia::Configuration.load(root: @root)
  end

  def allow_runs(runs, sha: @base, event: 'push')
    allow(RspecTia::Http).to receive(:new).with(
      base_url: 'https://api.github.example',
      headers: { 'Accept' => 'application/vnd.github+json', 'Authorization' => 'Bearer test-token' },
    ).and_return(http)
    expect(http).to receive(:get_json)
      .with("#{actions_path}/workflows/rspec.yml/runs?branch=main&event=#{event}&status=success&head_sha=#{sha}&per_page=1")
      .and_return('workflow_runs' => runs)
  end

  def allow_artifacts(*lists)
    lists = [[artifact]] if lists.empty?
    expect(http).to receive(:get_json).with("#{actions_path}/runs/101/artifacts?name=rspec-tia-map&per_page=2")
      .exactly(lists.size).times.and_return(*lists.map { |artifacts| { 'artifacts' => artifacts } })
  end

  def archive(sha: @base, time: Time.now)
    map = RspecTia::Map.new(generated_at: time, commit_sha: sha)
    map.add('spec/source_spec.rb', ['lib/source.rb'])
    map.add('spec/base_spec.rb', ['lib/base.rb'])
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry('map.json.gz')
      zip.write(Zlib.gzip(JSON.generate(map.to_h)))
    end.string
  end

  def fetch(*args)
    cli.start(['map', 'fetch', '--root', @root, *args])
  end

  def select
    cli.start(['select', '--root', @root])
  end

  it 'uses the merge checkout first parent and the head commit message in a shallow clone' do
    Dir.mktmpdir do |clone|
      git('clone', '-q', '--depth=2', "file://#{@root}", clone)
      write_event(labels: ['run-all'])
      adapter = described_class.new(RspecTia::Configuration.new({}, root: clone))
      context = adapter.context
      expect(context.changed_files).to contain_exactly('lib/source.rb', 'lib/renamed.rb')
      expect(context.labels).to eq(['run-all'])
      expect(context.commit_message).to eq("Rename source\n\n")
    end
  end

  it 'downloads the merged map from the matching push and selects only the PR-dependent spec' do
    allow_runs([{ 'id' => 101, 'head_sha' => @base }])
    allow_artifacts
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip").and_return(archive)

    expect(fetch).to eq(0)
    expect(RspecTia::Map.load(config.map_path).commit_sha).to eq(@base)
    expect { expect(select).to eq(0) }.to output("spec/source_spec.rb\n").to_stdout
  end

  it 'uses the common ancestor for an explicit head checkout' do
    git('switch', '-q', 'topic')
    allow_runs([{ 'id' => 101, 'head_sha' => @ancestor }], sha: @ancestor)
    allow_artifacts
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip").and_return(archive(sha: @ancestor))

    expect(fetch).to eq(0)
    expect(RspecTia::Map.load(config.map_path).commit_sha).to eq(@ancestor)
    expect { expect(select).to eq(0) }.to output("spec/source_spec.rb\n").to_stdout
  end

  it 'keeps a downloaded map out of subsequent local map generation in the same workspace' do
    allow_runs([{ 'id' => 101, 'head_sha' => @base }])
    allow_artifacts
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip").and_return(archive)
    expect(fetch).to eq(0)
    expect(File.file?(File.join(config.map_fragment_dir, 'github-actions', 'github-actions-202.json.gz'))).to be(true)

    fragment = RspecTia::Map.new(generated_at: Time.now, commit_sha: @head)
    fragment.add('spec/base_spec.rb', ['lib/base.rb']).dump(File.join(config.map_fragment_dir, 'map-1.json.gz'))
    expect(cli.start(['map', 'merge', '--root', @root])).to eq(0)
    map = RspecTia::Map.load(config.map_path)
    expect(map.commit_sha).to eq(@head)
    expect(map.specs).to contain_exactly('spec/base_spec.rb')
  end

  it 'looks for a scheduled run at the same base commit' do
    write_config(event: 'schedule')
    allow_runs([{ 'id' => 101, 'head_sha' => @base }], event: 'schedule')
    allow_artifacts
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip").and_return(archive)

    expect(fetch).to eq(0)
    expect { expect(select).to eq(0) }.to output("spec/source_spec.rb\n").to_stdout
  end

  it 'rejects an invalid workflow or event before contacting GitHub' do
    expect(RspecTia::Http).not_to receive(:new)

    write_config(workflow: '.github/workflows/rspec.yml')
    expect { expect(fetch).to eq(1) }.to output(/map_workflow/).to_stderr

    write_config(event: 'pull_request')
    expect { expect(fetch).to eq(1) }.to output(/map_event/).to_stderr
  end

  it 'uses the PR label and head commit message to force the full suite with a fresh map' do
    RspecTia::Map.new(generated_at: Time.now, commit_sha: @base).add('spec/source_spec.rb', ['lib/source.rb']).dump(config.map_path)
    write_event(labels: ['run-all'])
    expect { expect(select).to eq(0) }.to output("spec\n").to_stdout

    write_event
    expect { expect(select).to eq(0) }.to output("spec/source_spec.rb\n").to_stdout

    write_config(commit_message_tokens: ['Rename source'])
    expect { expect(select).to eq(0) }.to output("spec\n").to_stdout
  end

  it 'keeps the Git adapter available for users who have not opted into GitHub Actions' do
    allow(RspecTia::Ci::Gitlab).to receive(:available?).and_return(false)
    expect(RspecTia::Ci.build(RspecTia::Configuration.new({})).class).to eq(RspecTia::Ci::Git)
  end

  it 'runs the full suite outside pull requests' do
    ENV['GITHUB_EVENT_NAME'] = 'push'
    expect(RspecTia::Http).not_to receive(:new)
    expect(fetch).to eq(0)
    expect { expect(select).to eq(0) }.to output("spec\n").to_stdout
  end

  it 'explains the depth required to check out the PR merge commit' do
    Dir.mktmpdir do |clone|
      git('clone', '-q', '--depth=1', "file://#{@root}", clone)
      adapter = described_class.new(RspecTia::Configuration.new({}, root: clone))
      expect { adapter.context }.to raise_error(described_class::Error, /fetch-depth: 2/)
    end
  end

  it 'reports an unexpected checkout as a failure without printing a selection' do
    git('checkout', '-q', '--detach', @base)
    expect do
      expect { expect(select).to eq(1) }.to output('').to_stdout
    end.to output(/Check out the GitHub pull request/).to_stderr
  end

  %i(no_run no_artifact expired stale gone removed_during_download).each do |condition|
    it "clears the existing map and runs the full suite when the map is #{condition}" do
      RspecTia::Map.new(generated_at: Time.now).add('spec/source_spec.rb', ['lib/source.rb']).dump(config.map_path)
      allow_runs(condition == :no_run ? [] : [{ 'id' => 101, 'head_sha' => @base }])
      artifact_path = "#{actions_path}/artifacts/202/zip"

      case condition
      when :no_artifact
        allow_artifacts([])
      when :expired
        allow_artifacts([artifact.merge('expired' => true)])
      when :stale
        allow_artifacts
        expect(http).to receive(:get).with(artifact_path).and_return(archive(time: Time.at(0)))
      when :gone
        allow_artifacts
        expect(http).to receive(:get).with(artifact_path).and_raise(RspecTia::Http::Gone, 'artifact returned 410')
      when :removed_during_download
        allow_artifacts([artifact], [])
        expect(http).to receive(:get).with(artifact_path).and_raise(RspecTia::Http::NotFound, 'artifact returned 404')
      end

      expect(fetch).to eq(0)
      expect(File.exist?(config.map_path)).to be(false)
      expect { expect(select).to eq(0) }.to output("spec\n").to_stdout
    end
  end

  it 'preserves the existing map when the downloaded map names a different source commit' do
    RspecTia::Map.new(generated_at: Time.now, commit_sha: @base).add('spec/base_spec.rb', ['lib/base.rb']).dump(config.map_path)
    original_map = File.binread(config.map_path)
    allow_runs([{ 'id' => 101, 'head_sha' => @base }])
    allow_artifacts
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip").and_return(archive(sha: @head))

    expect { expect(fetch).to eq(1) }.to output(/unexpected source commit/).to_stderr
    expect(File.binread(config.map_path)).to eq(original_map)
  end

  it 'preserves the map when a download returns 404 and the artifact is still listed' do
    RspecTia::Map.new(generated_at: Time.now).add('spec/base_spec.rb', ['lib/base.rb']).dump(config.map_path)
    allow_runs([{ 'id' => 101, 'head_sha' => @base }])
    allow_artifacts([artifact], [artifact])
    expect(http).to receive(:get).with("#{actions_path}/artifacts/202/zip")
      .and_raise(RspecTia::Http::NotFound, 'artifact returned 404')

    expect { expect(fetch).to eq(1) }.to output(/404/).to_stderr
    expect(File.exist?(config.map_path)).to be(true)
  end

  it 'rejects duplicate map artifacts while preserving the existing map' do
    RspecTia::Map.new(generated_at: Time.now).add('spec/base_spec.rb', ['lib/base.rb']).dump(config.map_path)
    allow_runs([{ 'id' => 101, 'head_sha' => @base }])
    allow_artifacts([artifact, artifact.merge('id' => 203)])

    expect { expect(fetch).to eq(1) }.to output(/Expected one .* map artifact/).to_stderr
    expect(File.exist?(config.map_path)).to be(true)
  end
end
