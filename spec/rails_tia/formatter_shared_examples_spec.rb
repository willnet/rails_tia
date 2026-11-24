require 'open3'
require 'rbconfig'

RSpec.describe 'shared examplesの依存マップ' do
  it '各利用元へ依存を記録し、予測したパスから実際のexampleを実行できる' do
    Dir.mktmpdir do |root|
      files = {
        'lib/value.rb' => <<~RUBY,
          module Value
            def self.call
              42
            end
          end
        RUBY
        'spec/support/shared.rb' => <<~RUBY,
          RSpec.shared_examples('value') do
            it('shared value') { expect(Value.call).to eq(42) }
          end
        RUBY
        'spec/a_spec.rb' => <<~RUBY,
          require_relative '../lib/value'
          require_relative 'support/shared'
          RSpec.describe('A') do
            context('nested') { it_behaves_like 'value' }
            it('ordinary value') { expect(Value.call).to eq(42) }
          end
        RUBY
        'spec/b_spec.rb' => <<~RUBY,
          require_relative '../lib/value'
          require_relative 'support/shared'
          RSpec.describe('B') do
            context('nested') { include_examples 'value' }
          end
        RUBY
      }
      files.each do |path, body|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      lib = File.expand_path('../../lib', __dir__)
      env = { 'RAILS_TIA_CONFIG' => nil, 'RAILS_TIA_FRAGMENT_PATH' => nil }
      command = [RbConfig.ruby, '-I', lib, '-rrails_tia/boot', '-S', 'rspec']
      output, status = Open3.capture2e(env, *command, '--require', 'rails_tia/formatter',
                                     '--format', 'RailsTia::Formatter', '--order', 'defined', chdir: root)
      expect(status.success?).to be(true), output
      map = RailsTia::Map.merge_files(Dir.glob(File.join(root, 'tmp/rails_tia/fragments/*.json.gz')))
      expect(map.specs).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb')
      expect(map.specs_for('lib/value.rb')).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb')

      result = RailsTia::Predictor.new(config: RailsTia::Configuration.new({}, root: root), map: map)
                                .call(RailsTia::Context.new(changed_files: ['lib/value.rb'], merge_request: true))
      expect(result).not_to be_full_run
      expect(result.specs).to eq(['spec/a_spec.rb', 'spec/b_spec.rb'])
      output, status = Open3.capture2e(RbConfig.ruby, '-S', 'rspec', *result.specs, chdir: root)
      expect(status.success?).to be(true), output
      expect(output).to include('3 examples, 0 failures')
    end
  end
end
