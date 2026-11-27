require 'rails_tia/constant_reads'

RSpec.describe RailsTia::ConstantReads do
  it 'resolves a bare inherited constant used by a method in another file' do
    Dir.mktmpdir do |root|
      app = File.join(root, 'app')
      Dir.mkdir(app)
      File.write(File.join(app, 'base.rb'), 'class Base; LIMIT = 10; end')
      File.write(File.join(app, 'child.rb'), "class Child < Base\n def limit\n LIMIT\n end\nend")
      index = described_class.new(RailsTia::Configuration.new({}, root: root))
      expect(index.sources('app/child.rb', [nil, nil, 1, nil, nil], nil)).to eq(['app/base.rb'])
    end
  end

  it 'uses configured definition directories and distinguishes absolute and relative names in runnable tests' do
    Dir.mktmpdir do |root|
      sources = {
        'app/config.rb' => 'module Config; LIMIT = 1; end',
        'components/other.rb' => 'module Other; module Config; end; Config::LIMIT = 2; end',
        'vendor/bundle/config.rb' => 'Config::LIMIT = 3',
        'spec/read_spec.rb' => "def absolute\n ::Config::LIMIT\nend\nmodule Other; def relative\n Config::LIMIT\nend; end",
      }
      sources.each do |file, code|
        path = File.join(root, file)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, code)
      end
      config = RailsTia::Configuration.new({ 'rails' => { 'app_dirs' => ['components'] } }, root: root)
      index = described_class.new(config)
      absolute = [nil, 1, nil, nil, 0, nil]
      both = [nil, 1, nil, nil, 1, nil]
      expect(index.sources('spec/read_spec.rb', absolute, nil)).to eq(['app/config.rb'])
      expect(index.sources('spec/read_spec.rb', both, absolute)).to contain_exactly('components/other.rb')
    end
  end
end
