require 'rails_tia/cli'

RSpec.describe 'doctor' do
  around do |example|
    with_project(['spec/a_spec.rb', '.rails_tia.yml']) do |root|
      @root = root
      @config = RailsTia::Configuration.load(root: root)
      example.run
    end
  end

  before { allow(RailsTia::Ci).to receive(:build).and_return(RailsTia::Ci::Git.new(@config)) }

  def doctor
    original = $stdout
    $stdout = StringIO.new
    status = RailsTia::Cli.start(['doctor', '--root', @root])
    [status, $stdout.string]
  ensure
    $stdout = original
  end

  it '全項目が正常なら0で終了する' do
    RailsTia::Map.new(generated_at: Time.now).add('spec/a_spec.rb', ['lib/a.rb']).dump(@config.map_path)

    status, output = doctor
    expect(status).to eq(0)
    expect(output).to include('RailsTia::Ci::Git (MR: true)')
  end

  it '壊れたマップをNGとして報告し、他の項目の確認を続ける' do
    FileUtils.mkdir_p(File.dirname(@config.map_path))
    File.write(@config.map_path, 'broken JSON')

    status, output = doctor
    expect(status).to eq(1)
    expect(output).to match(/^NG\s+Coverage map\s+Invalid map file/)
    expect(output).to include('CI adapter', 'Static mappings')
  end
end
