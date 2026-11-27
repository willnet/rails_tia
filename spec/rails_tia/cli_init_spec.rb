require 'rails_tia/cli'

RSpec.describe 'init' do
  it 'creates a usable Rails configuration in the project root' do
    specs = %w[spec/models/admin/user_spec.rb spec/requests/admin/users_spec.rb]
    with_project(specs) do |root|
      Dir.chdir(root) do
        expect { expect(RailsTia::Cli.start(['init'])).to eq(0) }.to output(/Created/).to_stdout
      end

      config = RailsTia::Configuration.load(root: root)
      expect(config.all_specs).to match_array(specs)
      expect(config.full_run_path?('.rails_tia.yml')).to be(true)
      %w[Gemfile.lock config/initializers/auth.rb db/schema.rb app/views/shared/_menu.html.erb spec/support/login.rb].each do |path|
        expect(config.full_run_path?(path)).to be(true)
      end
      expect(config.full_run_path?('app/models/admin/user.rb')).to be(false)

      mapping = RailsTia::StaticMapping.new(config.static_mapping_rules, root: root)
      expect(mapping.specs_for('app/models/admin/user.rb')).to eq([specs.first])
      expect(mapping.specs_for('app/controllers/admin/users_controller.rb')).to eq([specs.last])
      expect(mapping.specs_for('app/views/admin/users/index.html.erb')).to eq([specs.last])
    end
  end

  it 'generates a Minitest preset from the test directory under --root' do
    model = 'test/models/admin/user_test.rb'
    controller = 'test/controllers/admin/users_controller_test.rb'
    integration = 'test/integration/admin/users_test.rb'
    browser = 'test/system/login_test.rb'
    tests = [model, controller, integration, browser]
    with_project(tests) do |root|
      expect { expect(RailsTia::Cli.start(['init', '--root', root])).to eq(0) }.to output(/Created/).to_stdout
      config = RailsTia::Configuration.load(root: root)
      expect(config.all_specs).to match_array(tests)
      expect(config.full_run_token).to eq('test/')
      %w[.rails_tia.yml test/test_helper.rb test/application_system_test_case.rb test/fixtures/users.yml
         test/support/login.rb].each { |path| expect(config.full_run_path?(path)).to be(true) }
      mapping = RailsTia::StaticMapping.new(config.static_mapping_rules, root: root)
      expect(mapping.specs_for('app/models/admin/user.rb')).to eq([model])
      expect(mapping.specs_for('app/controllers/admin/users_controller.rb')).to contain_exactly(controller, integration)
      expect(mapping.specs_for('app/views/admin/users/index.html.erb')).to contain_exactly(controller, integration)
      expect(mapping.specs_for('app/javascript/application.js')).to eq([browser])
    end
  end

  it 'defaults to RSpec in mixed projects and allows an explicit Minitest configuration alongside it' do
    with_project(%w[spec/models/user_spec.rb test/models/user_test.rb]) do |root|
      expect { RailsTia::Cli.start(['init', '--root', root]) }.to output(/Created/).to_stdout
      expect(RailsTia::Configuration.load(root: root).all_specs).to eq(['spec/models/user_spec.rb'])

      path = File.join(root, 'minitest.yml')
      options = ['init', '--runner', 'minitest', '--root', root, '--config', path]
      expect { expect(RailsTia::Cli.start(options)).to eq(0) }.to output(/Created/).to_stdout
      config = RailsTia::Configuration.load(path, root: root)
      expect(config.all_specs).to eq(['test/models/user_test.rb'])
      expect(config.full_run_path?('minitest.yml')).to be(true)
    end
  end

  it 'rejects an unknown runner before writing a configuration' do
    with_project([]) do |root|
      expect { expect(RailsTia::Cli.start(['init', '--runner', 'unknown', '--root', root])).to eq(1) }
        .to output(/invalid argument/).to_stderr
      expect(File.exist?(File.join(root, '.rails_tia.yml'))).to be(false)
    end
  end

  it 'preserves an existing configuration even when it cannot be parsed' do
    with_project([]) do |root|
      path = File.join(root, '.rails_tia.yml')
      File.write(path, 'unfinished: [')
      expect { expect(RailsTia::Cli.start(['init', '--root', root])).to eq(1) }.to output(/already exists/).to_stderr
      expect(File.read(path)).to eq('unfinished: [')
    end
  end

  it 'selects system and feature specs for frontend changes with the generated preset' do
    browser_specs = %w[spec/system/admin/login_spec.rb spec/features/search_spec.rb]
    model_spec = 'spec/models/user_spec.rb'
    with_project(browser_specs + [model_spec, 'spec/system/support.rb']) do |root|
      expect { RailsTia::Cli.start(['init', '--root', root]) }.to output(/Created/).to_stdout
      config = RailsTia::Configuration.load(root: root)
      map = RailsTia::Map.new(generated_at: Time.now).add(model_spec, ['app/models/user.rb'])
      predictor = RailsTia::Predictor.new(config: config, map: map)
      frontend = %w[app/javascript/controllers/search.js app/assets/stylesheets/search.css vendor/javascript/lib.js
                    package.json package-lock.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb]
      context = RailsTia::Context.new(changed_files: frontend, merge_request: true)
      result = predictor.call(context, trace: true)

      expect(result).not_to be_full_run
      expect(result.specs).to match_array(browser_specs)
      frontend.each { |path| expect(result.matches.fetch(path)[:static_specs]).to eq(2) }

      browser_specs.each { |spec| File.delete(File.join(root, spec)) }
      expect(predictor.call(context).specs).to be_empty
    end
  end

  it 'triggers a full run when the generated configuration changes under a custom name' do
    with_project(['app/spec/models/user_spec.rb', 'app/ci/.keep']) do |workspace|
      Dir.chdir(workspace) do
        relative = 'ci/tia [pr] #1.yml'
        path = File.join('app', relative)
        options = ['--root', 'app', '--config', path]
        expect { expect(RailsTia::Cli.start(['init', *options])).to eq(0) }.to output(/Created/).to_stdout
        config = RailsTia::Configuration.load(path, root: 'app')
        expect(config.full_run_path?('ci/tia p #1.yml')).to be(false)
        expect(config.full_run_path?('.rails_tia.yml')).to be(false)

        RailsTia::Map.new(generated_at: Time.now).add('spec/models/user_spec.rb', ['app/models/user.rb']).dump(config.map_path)
        File.write('changes.txt', relative)
        expect { expect(RailsTia::Cli.start(['select', *options, '--changed-files-from', 'changes.txt'])).to eq(0) }
          .to output("spec\n").to_stdout
      end
    end
  end

  it 'omits the configuration path when the file is outside the project' do
    with_project([]) do |root|
      path = File.join(root, 'custom.yml')
      expect { expect(RailsTia::Cli.start(['init', '--config', path])).to eq(0) }.to output(/Created/).to_stdout
      paths = RailsTia::Configuration.load(path).full_run_paths
      expect(paths).to include('Gemfile')
      expect(paths).not_to include('.rails_tia.yml', path)
    end
  end

  it 'registers the configuration at its tracked path when root or config uses a directory symlink' do
    with_project(%w[app/ci/.keep app-extra/.keep]) do |workspace|
      root = File.join(workspace, 'app')
      linked_root = File.join(workspace, 'linked-app')
      File.symlink(root, linked_root)
      [[root, linked_root, 'one.yml'], [linked_root, root, 'two.yml']].each do |project, directory, name|
        path = File.join(directory, 'ci', name)
        expect { expect(RailsTia::Cli.start(['init', '--root', project, '--config', path])).to eq(0) }.to output(/Created/).to_stdout
        expect(RailsTia::Configuration.load(path, root: project).full_run_path?("ci/#{name}")).to be(true)
      end

      File.symlink(File.join(workspace, 'app-extra'), File.join(root, 'external'))
      path = File.join(root, 'external', 'tia.yml')
      expect { expect(RailsTia::Cli.start(['init', '--root', root, '--config', path])).to eq(0) }.to output(/Created/).to_stdout
      expect(RailsTia::Configuration.load(path, root: root).full_run_path?('external/tia.yml')).to be(false)
    end
  end
end
