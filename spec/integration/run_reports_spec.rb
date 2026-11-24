require 'open3'
require 'rbconfig'
require 'rspec_tia/cli'

RSpec.describe 'CI run reports' do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @reports = File.join(root, 'history')
      example.run
    end
  end

  let(:env) do
    {
      'RSPEC_TIA_REPORT_DIR' => 'history', 'RSPEC_TIA_CONFIG' => nil, 'RSPEC_TIA_FRAGMENT_PATH' => nil,
      'GITHUB_SHA' => 'tested-sha', 'CI_COMMIT_SHA' => nil, 'GITHUB_RUN_ID' => '42',
      'GITHUB_RUN_ATTEMPT' => '2', 'CI_NODE_INDEX' => '3', 'TEST_ENV_NUMBER' => '2',
    }
  end

  def run_ruby(args, overrides = {})
    Open3.capture3(env.merge(overrides), RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__),
                   *args, chdir: @root)
  end

  def cli(*args, overrides: {})
    run_ruby([File.expand_path('../../exe/rspec-tia', __dir__), *args], overrides)
  end

  def records(type)
    Dir.glob(File.join(@reports, "#{type}-*.json")).to_h { |path| [path, JSON.parse(File.read(path))] }
  end

  def run_formatter(*args)
    run_ruby(%w(-rrspec_tia/boot -S rspec --require rspec_tia/formatter --format RspecTia::Formatter) + args)
  end

  it 'links measured worker output, a replayable map, a selection and a full-suite audit' do
    FileUtils.mkdir_p(File.join(@root, 'spec'))
    File.write(File.join(@root, 'answer.rb'), "def answer\n  6 * 7\nend\n")
    File.write(File.join(@root, 'spec/answer_spec.rb'), <<~SPEC)
      require_relative '../answer'
      RSpec.describe('answer') { it { expect(answer).to eq(42) } }
    SPEC
    File.write(File.join(@root, 'spec/other_spec.rb'), "RSpec.describe('other') { it { expect(true).to be true } }")

    _, err, status = run_formatter
    expect(status).to be_success, err
    worker = records('map_worker').values.fetch(0)
    expect(worker).to include('schema_version' => 1, 'spec_count' => 2, 'example_count' => 2, 'failed' => false,
                              'node' => '3', 'worker' => '2', 'run_id' => '42', 'attempt' => '2')
    expect(worker['coverage_calls']).to be >= 2
    expect(worker['timings_seconds'].values_at('coverage', 'scan', 'write_fragment')).to all(be >= 0)

    _, err, status = cli('map', 'merge')
    expect(status).to be_success, err
    merged = records('map_merge').values.fetch(0)
    expect(merged.fetch('fragment_ids')).to eq([worker.fetch('fragment_id')])
    id = merged.fetch('map_id')
    archive = File.join(@reports, 'maps', "#{id}.json.gz")
    expect(merged.fetch('timings_seconds').fetch('archive_map')).to be >= 0
    [archive, records('map_merge').keys.fetch(0)].each do |path|
      expect(File.stat(path).mode & 0o777).to eq(0o644 & ~File.umask)
    end
    archived = Zlib::GzipReader.open(archive, &:read)
    expect(Digest::SHA256.hexdigest(archived)).to eq(id)
    expect(JSON.parse(archived).fetch('specs')).to contain_exactly('spec/answer_spec.rb', 'spec/other_spec.rb')

    # Re-merging the same fragments also supports an uncompressed local map.
    _, err, status = cli('map', 'merge', '--output', 'plain.json')
    expect(status).to be_success, err
    expect(records('map_merge').values.map { |row| row.fetch('map_id') }.uniq).to eq([id])
    expect(File.read(File.join(@root, 'plain.json'))).to eq(archived)

    File.write(File.join(@root, 'changes'), "answer.rb\n")
    out, err, status = cli('select', '--changed-files-from', 'changes')
    expect(status).to be_success, err
    expect(out).to eq("spec/answer_spec.rb\n")
    path, selection = records('select').first
    expect(selection).to include('map_id' => id, 'changed_files' => ['answer.rb'], 'spec_ratio' => 0.5)
    expect(selection.fetch('matches').fetch('answer.rb')).to eq(
      'mapped_specs' => 1, 'static_specs' => 0, 'changed_spec' => false,
    )

    FileUtils.mkdir_p(File.join(@root, 'junit'))
    File.write(File.join(@root, 'junit/a.xml'), '<testsuite/>')
    args = ['audit', '--selection-report', path, '--junit', 'junit', '--expect-junit', 'a.xml', '--expect-junit', 'b.xml']
    expect(cli(*args).last.exitstatus).to eq(1)
    incomplete = records('audit').values.fetch(0)
    expect(incomplete).to include('valid' => false, 'junit_complete' => false, 'missed_specs' => nil,
                                  'missing_junit_files' => ['b.xml'])
    expect(incomplete.fetch('validation_errors').join).to include('b.xml')

    File.write(File.join(@root, 'junit/b.xml'), '<testsuite><testcase file="spec/other_spec.rb"><failure/></testcase></testsuite>')
    expect(cli(*args).last.exitstatus).to eq(1)
    complete = records('audit').values.find { |audit| audit['junit_complete'] }
    expect(complete).to include('prediction_id' => selection.fetch('report_id'), 'map_id' => id, 'valid' => true,
                                'failed_specs' => ['spec/other_spec.rb'], 'missed_specs' => ['spec/other_spec.rb'])
  end

  it 'distinguishes successful empty selections, full runs, failed input, and disabled reporting' do
    args = %w(select --changed-files-from changes)
    File.write(File.join(@root, 'changes'), "unused.rb\n")
    expect(cli(*args, overrides: { 'RSPEC_TIA_REPORT_DIR' => '' }).first).to eq("spec\n")
    expect(File.exist?(@reports)).to be(false)

    expect(cli(*args).first).to eq("spec\n")
    expect(records('select').values.first).to include('full_run' => true, 'reason_code' => 'missing_map',
                                                      'map_id' => nil, 'matches' => nil)
    RspecTia::Map.new(generated_at: Time.now).add('spec/sample_spec.rb', ['other.rb'])
      .dump(File.join(@root, 'tmp/rspec_tia/map.json.gz'))
    expect(cli(*args).first).to be_empty
    expect(records('select').values).to include(a_hash_including('full_run' => false, 'selected_specs' => []))
    stdout, _, status = cli('select', '--changed-files-from', 'absent')
    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    expect(records('select').size).to eq(2)
  end

  it 'audits full-run selection reports and rejects corrupt or mismatched predictions' do
    File.write(File.join(@root, 'changes'), "source.rb\n")
    expect(cli('select', '--changed-files-from', 'changes').last).to be_success
    selection_path = records('select').keys.fetch(0)
    File.write(File.join(@root, 'shard.xml'), '<testsuite><testcase file="spec/a_spec.rb"><error/></testcase></testsuite>')
    args = ['audit', '--junit', '.', '--selection-report', selection_path]
    expect(cli(*args).last).to be_success
    expect(records('audit').values.first).to include('full_run' => true, 'missed_specs' => [], 'junit_complete' => nil)
    expect(cli(*args, overrides: { 'GITHUB_SHA' => 'other' }).last.exitstatus).to eq(1)
    File.write(selection_path, '{}')
    expect(cli(*args).last.exitstatus).to eq(1)
    _, err, status = cli('audit', '--junit', '.', '--selection-report', @root)
    expect(status.exitstatus).to eq(1)
    expect(err).to start_with('[rspec_tia] Cannot read selection report')
    expect(records('audit').size).to eq(1)
  end

  it 'finishes RSpec output, merges the map and returns the actual selection when history cannot be written' do
    File.write(@reports, 'occupied')
    FileUtils.mkdir_p(File.join(@root, 'spec'))
    File.write(File.join(@root, 'spec/a_spec.rb'), "RSpec.describe('a') { it { expect(true).to be true } }")
    _, err, status = run_formatter('--format', 'json', '--out', 'suite.json')
    expect(err).to include('Cannot save run report')
    expect(status).to be_success, err
    expect(JSON.parse(File.read(File.join(@root, 'suite.json'))).fetch('summary'))
      .to include('example_count' => 1, 'failure_count' => 0)

    _, err, status = cli('map', 'merge')
    expect(err).to include('Cannot save run report', 'Merged 1 fragments')
    expect(status).to be_success, err
    config = RspecTia::Configuration.load(root: @root)
    expect(RspecTia::Map.load(config.map_path).specs).to contain_exactly('spec/a_spec.rb')

    File.write(File.join(@root, 'changes'), "spec/a_spec.rb\n")
    out, err, status = cli('select', '--changed-files-from', 'changes')
    expect(err).to include('Cannot save run report')
    expect(out).to eq("spec/a_spec.rb\n")
    expect(status).to be_success, err
  end

  it 'preserves audit diagnostics and exit status when the history directory is unwritable' do
    File.write(@reports, 'occupied')
    predicted = File.join(@root, 'predicted.txt')
    File.write(predicted, '')
    File.write(File.join(@root, 'shard.xml'), '<testsuite><testcase file="spec/a_spec.rb"><failure/></testcase></testsuite>')
    args = %w(audit --predicted predicted.txt --junit . --expect-junit shard.xml)
    _, err, status = cli(*args)
    expect(status.exitstatus).to eq(1)
    expect(err).to include('Cannot save run report', 'Prediction missed 1 failing specs')

    File.write(predicted, "spec/a_spec.rb\n")
    _, err, status = cli(*args)
    expect(status).to be_success, err
    expect(err).to include('Cannot save run report', 'No missed failures')
  end

  it 'warns if a history field cannot be encoded and publishes no partial report' do
    report = RspecTia::RunReport.new('select', @reports)
    expect { report.write { { job: "\xff".b.force_encoding('UTF-8') } } }
      .to output(/Cannot save run report/).to_stderr
    expect(Dir.children(@reports)).to be_empty
  end

  it 'distinguishes an unreadable shard from a readable one with an unidentified failing spec' do
    File.write(File.join(@root, 'predicted.txt'), '')
    FileUtils.mkdir_p(File.join(@root, 'junit/nodes'))
    file = File.join(@root, 'junit/nodes/1.xml')
    args = %w(audit --predicted predicted.txt --junit junit --expect-junit ./nodes//1.xml)
    File.write(file, '<testsuite>')
    expect(cli(*args).last.exitstatus).to eq(1)
    expect(records('audit').values.first).to include('junit_complete' => false, 'missing_junit_files' => [],
                                                     'valid' => false, 'prediction_id' => nil)
    File.write(file, '<testsuite><testcase><failure/></testcase></testsuite>')
    expect(cli(*args).last.exitstatus).to eq(1)
    complete = records('audit').values.find { |row| row['junit_complete'] }
    expect(complete).to include('missing_junit_files' => [], 'valid' => false, 'missed_specs' => nil)
    expect(complete.fetch('validation_errors').join).to include('no file attribute')
  end

  it 'keeps the worker measurements from failed tests and marks their map stale' do
    FileUtils.mkdir_p(File.join(@root, 'spec'))
    File.write(File.join(@root, 'spec/failing_spec.rb'), "RSpec.describe('failure') { it { expect(false).to be true } }")
    expect(run_formatter.last.exitstatus).to eq(1)
    expect(records('map_worker').values.first).to include('failed' => true, 'example_count' => 1)
    map = RspecTia::Map.load(Dir.glob(File.join(@root, 'tmp/rspec_tia/fragments/*')).fetch(0))
    expect(map).to be_stale(max_age_days: 3)
  end
end
