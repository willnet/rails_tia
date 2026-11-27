require_relative '../support/rails_app_runner'

RSpec.describe 'Minitest map collection' do
  def with_app
    RailsAppRunner.with_app(mode: :eager) do |app|
      File.write(File.join(app.root, '.rails_tia.yml'), "spec_glob: 'test/**/*_test.rb'\nfull_run_token: 'test/'\n")
      yield app
    end
  end

  def run_tests(app, parallel: nil, paths: ['test/'], collect: true)
    env = {
      'BUNDLE_GEMFILE' => Bundler.default_gemfile.to_s,
      'RAILS_ENV' => 'test', 'FIXTURE_EAGER_LOAD' => 'true', 'FIXTURE_PARALLEL_WITH' => parallel,
      'RAILS_TIA_REPORT_DIR' => File.join(app.root, 'tmp', 'reports'),
      'PARALLEL_WORKERS' => nil, 'DATABASE_URL' => nil, 'RAILS_TIA_CONFIG' => nil,
      'RAILS_TIA_FRAGMENT_PATH' => File.join(app.root, 'tmp', 'fragment.json.gz'),
    }
    command = [RbConfig.ruby]
    command << '-rrails_tia/minitest' if collect
    command += ['bin/rails', 'test', *paths, '--seed', '19']
    app.capture(env, command)
  end

  def fragment(app)
    RailsTia::Map.load(File.join(app.root, 'tmp', 'fragment.json.gz'))
  end

  [nil, 'processes'].each do |parallel|
    it "selects runnable consumers and reproduces the full suite failures using #{parallel || 'serial execution'}" do
      with_app do |app|
        output, status = run_tests(app, parallel: parallel)
        expect(status).to be_success, output
        expect(output).to include('2 processes') if parallel
        report_path = Dir[File.join(app.root, 'tmp/reports/map_worker-*.json')].fetch(0)
        report = JSON.parse(File.read(report_path))
        expect(report).to include('spec_count' => 3, 'example_count' => 4, 'failed' => false)
        expect(report['timings_seconds']['coverage']).to be_positive
        map = fragment(app)
        expect(map.stale?(max_age_days: 1)).to be(false)
        consumers = %w[test/account_test.rb test/shared_test.rb]
        expect(map.specs.to_a.sort).to eq(consumers + ['test/unrelated_test.rb'])
        expect(map.specs_for('app/services/suite_after.rb')).to eq(map.specs)
        expect(map.specs_for('app/views/tracking/_boot.html.erb')).to be_empty
        %w[app/models/account.rb app/views/tracking/_shared.html.erb app/services/nested_before.rb
           app/services/nested_after.rb].each do |path|
          expect(map.specs_for(path)).to contain_exactly('test/account_test.rb')
        end
        expect(map.specs_for('test/support/shared_checks.rb').to_a.sort).to eq(consumers)

        source = 'app/services/shared_value.rb'
        selected = app.predict(map, [source]).specs
        expect(selected).to eq(consumers)
        app.mutate!('source' => source, 'before' => "'shared value'", 'after' => "'broken'")
        [selected, ['test/']].each do |paths|
          log, exit_status = run_tests(app, paths: paths, parallel: parallel, collect: paths == ['test/'])
          expect(exit_status.exitstatus).to eq(1), log
          expect(log.scan(/^(\w+Test)#test_shared /).flatten.sort).to eq(%w[AccountTest SharedTest]), log
        end
        expect(app.predict(fragment(app), [source])).to be_full_run
      end
    end
  end

  it 'invalidates the previous fragment before loading a suite that fails to boot' do
    with_app do |app|
      output, status = run_tests(app)
      expect(status).to be_success, output
      File.open(File.join(app.root, 'test/test_helper.rb'), 'a') { |f| f.puts "raise 'boot error'" }
      output, status = run_tests(app)
      expect(status).not_to be_success
      expect(output).to include('boot error')
      expect(fragment(app).stale?(max_age_days: 1)).to be(true)
    end
  end

  it 'rejects thread-parallel collection and leaves a stale fragment' do
    with_app do |app|
      output, status = run_tests(app, parallel: 'threads')
      expect(status).not_to be_success
      expect(output).to include('does not support thread-parallel tests')
      expect(fragment(app).stale?(max_age_days: 1)).to be(true)
    end
  end

  it 'selects both files when a reopened class includes a shared test' do
    with_app do |app|
      File.write(File.join(app.root, 'test/a_test.rb'), <<~RUBY)
        require_relative 'test_helper'
        class ReopenedTest < ActiveSupport::TestCase
        end
      RUBY
      File.write(File.join(app.root, 'test/b_test.rb'), <<~RUBY)
        require_relative 'test_helper'
        require_relative 'support/shared_checks'
        class ReopenedTest < ActiveSupport::TestCase
          include SharedChecks
        end
      RUBY
      File.write(File.join(app.root, 'test/child_test.rb'), <<~RUBY)
        require_relative 'a_test'
        class ChildTest < ReopenedTest
        end
      RUBY
      output, status = run_tests(app)
      expect(status).to be_success, output
      source = 'app/services/shared_value.rb'
      selected = app.predict(fragment(app), [source]).specs
      expect(selected).to include('test/a_test.rb', 'test/b_test.rb')
      expect(app.predict(fragment(app), ['test/b_test.rb']).specs).to include('test/a_test.rb', 'test/child_test.rb')
      app.mutate!('source' => source, 'before' => "'shared value'", 'after' => "'broken'")
      output, status = run_tests(app, paths: selected, collect: false)
      expect(status.exitstatus).to eq(1), output
      expect(output).to include('ReopenedTest#test_shared', 'ChildTest#test_shared')
    end
  end

  { 'after_run' => nil, 'parallelize_teardown' => 'processes' }.each do |hook, parallel|
    it "finishes with a diagnostic and falls back when #{hook} stops coverage" do
      with_app do |app|
        receiver = parallel ? 'ActiveSupport::TestCase' : 'Minitest'
        File.open(File.join(app.root, 'test/test_helper.rb'), 'a') do |file|
          file.puts "#{receiver}.#{hook} { Coverage.result }"
        end
        output, status = run_tests(app, parallel: parallel)
        expect(status).not_to be_success
        expect(output).to include('Coverage stopped before Minitest map collection finished'), output
        expect(output).to include('expected 2 worker maps, received 0') if parallel
        expect(app.predict(fragment(app), ['app/models/account.rb'])).to be_full_run
      end
    end
  end

  it 'rejects test bodies that Rails runs in an isolated child process' do
    with_app do |app|
      File.write(File.join(app.root, 'test/isolated_test.rb'), <<~RUBY)
        require_relative 'test_helper'
        require 'active_support/testing/isolation'
        class IsolatedTest < ActiveSupport::TestCase
          include ActiveSupport::Testing::Isolation
          def test_value
            assert_equal 'shared value', SharedValue.call
          end
        end
      RUBY
      output, status = run_tests(app, parallel: 'processes')
      expect(status).not_to be_success
      expect(output).to include('ActiveSupport::Testing::Isolation'), output
      expect(app.predict(fragment(app), ['app/services/shared_value.rb'])).to be_full_run
    end
  end

  it 'fails collection when a Rails worker completes without delivering its map' do
    with_app do |app|
      File.open(File.join(app.root, 'test/test_helper.rb'), 'a') do |file|
        file.puts <<~'HOOK'
          ActiveSupport::TestCase.parallelize_setup do |worker|
            if worker.zero?
              RailsTia::MinitestCollector.current.define_singleton_method(:write_worker) { }
            end
          end
        HOOK
      end
      output, status = run_tests(app, parallel: 'processes')
      expect(status).not_to be_success
      expect(output).to include('expected 2 worker maps, received 1'), output
      expect(fragment(app).stale?(max_age_days: 1)).to be(true)
    end
  end
end
