require_relative '../support/rails_app_runner'

RSpec.describe 'Form dependencies from allocations', if: RUBY_ENGINE == 'ruby' do
  it 'selects the request that creates a preloaded form when its validation changes' do
    RailsAppRunner.with_app(mode: :eager) do |app|
      source = 'app/poros/registration_form.rb'
      FileUtils.mkdir_p(File.dirname(File.join(app.root, source)))
      gem_source = 'vendor/bundle/gems/example/lib/example.rb'
      FileUtils.mkdir_p(File.dirname(File.join(app.root, gem_source)))
      File.write(File.join(app.root, gem_source), "class GemForm; end\n")
      definitions = {
        'lib/form_support.rb' => 'module FormSupport; end',
        'components/registration.rb' => 'module Registration; end',
        'components_extra/other.rb' => 'module Other; end',
      }
      definitions.each do |path, code|
        FileUtils.mkdir_p(File.dirname(File.join(app.root, path)))
        File.write(File.join(app.root, path), code)
      end
      File.write(File.join(app.root, source), <<~RUBY)
        require_relative '../../#{gem_source}'
        #{definitions.keys.map { |path| "require_relative '../../#{path}'" }.join("\n")}
        class RegistrationForm < GemForm
          include FormSupport, Registration, Other
          include ActiveModel::Model
          attr_accessor :name
          validates :name, presence: true
        end
      RUBY
      service = 'app/services/registration_service.rb'
      File.write(File.join(app.root, service), "class RegistrationService < RegistrationForm; end\n")
      File.write(File.join(app.root, 'app/controllers/registrations_controller.rb'), <<~RUBY)
        class RegistrationsController < ActionController::Base
          def check
            head(Class.new(RegistrationService).new.valid? ? :ok : :unprocessable_entity)
          end
        end
      RUBY
      routes = File.join(app.root, 'config/routes.rb')
      File.write(routes, File.read(routes).sub('routes.draw do', "routes.draw do\n  get '/register', to: 'registrations#check'"))
      spec = 'spec/requests/registration_spec.rb'
      File.write(File.join(app.root, spec), <<~RUBY)
        RSpec.describe 'registration' do
          it { expect(Rack::MockRequest.new(Rails.application).get('/register').status).to eq(422) }
        end
      RUBY
      File.write(File.join(app.root, 'spec/requests/reused_spec.rb'), <<~RUBY)
        prebuilt = RegistrationForm.new(name: 'Ada')
        RSpec.describe('a form created during boot') { it { expect(prebuilt.valid?).to be(true) } }
      RUBY
      baseline = app.run.map
      expect(baseline.specs_for('lib/form_support.rb')).to contain_exactly(spec)
      expect(baseline.sources & [gem_source, 'components/registration.rb', 'components_extra/other.rb']).to be_empty
      expect(baseline.specs_for(service)).to contain_exactly(spec)
      selected = app.predict(baseline, [source]).specs
      expect(selected).to eq([spec])
      config_path = File.join(app.root, '.rails_tia.yml')
      config = YAML.safe_load_file(config_path)
      config['rails'] ||= {}
      config['rails']['app_dirs'] = ['components/']
      File.write(config_path, YAML.dump(config))
      expanded = app.run.map
      [source, service, 'lib/form_support.rb', 'components/registration.rb'].each do |path|
        expect(expanded.specs_for(path)).to contain_exactly(spec)
      end
      expect(expanded.sources & [gem_source, 'components_extra/other.rb']).to be_empty

      config['rails']['object_allocations'] = 'false'
      File.write(config_path, YAML.dump(config))
      disabled = app.run.map
      expect(disabled.specs_for(source)).to be_empty
      expect(disabled.specs_for(service)).to be_empty

      app.mutate!('source' => source, 'before' => 'presence: true', 'after' => 'presence: true, allow_nil: true')
      [app.all_specs, selected].each do |paths|
        expect(app.assertion_failures!(app.run(mapping: false, specs: paths))).to eq([spec])
      end
    end
  end
end
