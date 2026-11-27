RSpec.describe RailsTia::Configuration do
  it 'validates app_dirs when loading configuration even if allocation tracking is disabled' do
    ['components', ['/outside'], ['components/../other'], ["invalid\0path"]].each do |dirs|
      config = { 'rails' => { 'app_dirs' => dirs, 'object_allocations' => false } }
      expect { described_class.new(config) }.to raise_error(RailsTia::Error, /rails.app_dirs/)
    end
  end
end
