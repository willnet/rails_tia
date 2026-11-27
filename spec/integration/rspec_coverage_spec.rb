require 'open3'
require 'rbconfig'

RSpec.describe 'RSpec map collection with existing coverage' do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, 'spec'))
      File.write(File.join(@root, 'value.rb'), <<~RUBY)
        def value(flag)
          flag ? :yes : :no
        end
      RUBY
      { 'a' => true, 'b' => false }.each do |name, flag|
        File.write(File.join(@root, 'spec', "#{name}_spec.rb"), <<~RUBY)
          require_relative '../value'
          RSpec.describe('#{name}') { it { expect(value(#{flag})).to eq(:#{flag ? 'yes' : 'no'}) } }
        RUBY
      end
      File.write(File.join(@root, 'spec/other_spec.rb'), "RSpec.describe('other') { it { expect(1).to eq(1) } }")
      example.run
    end
  end

  def run_specs(setup, mapping: true)
    File.write(File.join(@root, 'setup.rb'), setup)
    lib = File.expand_path('../../lib', __dir__)
    command = [RbConfig.ruby, '-I', lib, '-r./setup']
    command << '-rrails_tia/boot' if mapping
    command += ['-S', 'rspec', '--order', 'defined']
    command += ['--require', 'rails_tia/formatter', '--format', 'RailsTia::Formatter'] if mapping
    env = {
      'RAILS_TIA_CONFIG' => nil, 'RAILS_TIA_REPORT_DIR' => nil,
      'RAILS_TIA_FRAGMENT_PATH' => File.join(@root, 'map.json.gz'),
    }
    Open3.capture2e(env, *command, chdir: @root)
  end

  def value_specs
    RailsTia::Map.load(File.join(@root, 'map.json.gz')).specs_for('value.rb')
  end

  it 'falls back to the full suite when the default allocation tracker is unavailable', if: RUBY_ENGINE == 'ruby' do
    require 'rails_tia/native_extension'
    unavailable = File.join(@root, "#{RailsTia::ALLOCATION_EXTENSION}.rb")
    FileUtils.mkdir_p(File.dirname(unavailable))
    File.write(unavailable, "raise LoadError, 'allocation extension missing'")
    setup = "$LOAD_PATH.unshift(__dir__)\nmodule Rails; end"
    map_path = File.join(@root, 'map.json.gz')

    output, status = run_specs(setup)
    expect(status).to be_success, output
    expect(output).to include('allocation extension missing', 'full run')
    expect(RailsTia::Map.load(map_path).stale?(max_age_days: 1)).to be(true)

    File.write(File.join(@root, '.rails_tia.yml'), "rails:\n  object_allocations: 'true'\n")
    output, status = run_specs(setup)
    expect(status).not_to be_success
    expect(output).to include('Cannot load object allocation tracking')
  end

  it 'preserves the SimpleCov line and branch counts, including hits before the suite starts' do
    results = [false, true].map do |mapping|
      dir = mapping ? 'combined' : 'simplecov'
      output, status = run_specs(<<~RUBY, mapping: mapping)
        require 'simplecov'
        SimpleCov.start do
          command_name 'RSpec'
          coverage_dir '#{dir}'
          enable_coverage :branch
        end
      RUBY
      expect(status).to be_success, output
      report = JSON.parse(File.read(File.join(@root, dir, '.resultset.json')))
      report.fetch('RSpec').fetch('coverage').fetch(File.join(@root, 'value.rb'))
    end
    expect(results.last.fetch('lines').first(2)).to eq([1, 2])
    expect(results.last.fetch('branches').values.flat_map(&:values)).to contain_exactly(1, 1)
    expect(results.last).to eq(results.first)
    expect(value_specs).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb')
  end

  it 'can reuse default line coverage without SimpleCov' do
    output, status = run_specs("require 'coverage'\nCoverage.start")
    expect(status).to be_success, output
    expect(value_specs).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb')
  end

  it 'maps a file first loaded in an example only if it executes a line' do
    File.write(File.join(@root, 'late.rb'), "LATE_VALUE = 42\n")
    File.write(File.join(@root, 'empty.rb'), "# No executable lines.\n")
    File.write(File.join(@root, 'spec/lazy_spec.rb'), <<~RUBY)
      RSpec.describe('lazy loading') do
        it do
          require_relative '../late'
          require_relative '../empty'
          expect(LATE_VALUE).to eq(42)
        end
      end
    RUBY
    output, status = run_specs('')
    expect(status).to be_success, output
    map = RailsTia::Map.load(File.join(@root, 'map.json.gz'))
    expect(map.specs_for('late.rb')).to contain_exactly('spec/lazy_spec.rb')
    expect(map.specs_for('empty.rb')).to be_empty
  end

  %w[branches oneshot_lines].each do |mode|
    it "rejects #{mode} without cumulative line counts" do
      output, status = run_specs("require 'coverage'\nCoverage.start(#{mode}: true)")
      expect(status).not_to be_success
      expect(output).to include('RSpec mapping requires cumulative line coverage')
      expect(File.exist?(File.join(@root, 'map.json.gz'))).to be(false)
    end
  end
end
