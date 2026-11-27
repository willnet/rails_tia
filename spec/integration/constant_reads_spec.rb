require_relative '../support/rails_app_runner'

RSpec.describe 'Dependencies on qualified constant reads' do
  [:normal, :eager].each do |mode|
    it "selects the failing readers and skips another method in the same file (#{mode})" do
      RailsAppRunner.with_app(mode: mode) do |app|
        definition = 'app/services/config.rb'
        File.write(File.join(app.root, definition), "module Config; LIMIT = 10; end\n")
        File.write(File.join(app.root, 'app/services/threshold_policy.rb'), <<~SOURCE)
          class ThresholdPolicy
            def self.accepts?(value)
              value <= Config::LIMIT
            end

            def self.label
              'threshold'
            end
          end
        SOURCE
        readers = %w[spec/requests/first_spec.rb spec/requests/second_spec.rb]
        readers.each do |file|
          File.write(File.join(app.root, file), "RSpec.describe('limit') { it { expect(ThresholdPolicy.accepts?(7)).to be(true) } }")
        end
        File.write(File.join(app.root, 'spec/requests/label_spec.rb'), <<~SOURCE)
          RSpec.describe('label') { it { expect(ThresholdPolicy.label).to eq('threshold') } }
        SOURCE

        if mode == :eager
          config_path = File.join(app.root, '.rails_tia.yml')
          config = YAML.safe_load_file(config_path)
          config['rails'] ||= {}
          config['rails']['constant_reads'] = false
          File.write(config_path, YAML.dump(config))
          expect(app.predict(app.run.map, [definition]).specs).to be_empty
          config['rails'].delete('constant_reads')
          File.write(config_path, YAML.dump(config))
        end

        selected = app.predict(app.run.map, [definition]).specs
        expect(selected).to eq(readers)
        app.mutate!('source' => definition, 'before' => '10', 'after' => '5')
        [selected, app.all_specs].each do |paths|
          expect(app.assertion_failures!(app.run(mapping: false, specs: paths))).to eq(readers)
        end
      end
    end
  end
end
