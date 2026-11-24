require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'rails_tia/boot' do
  it 'disables the Bootsnap compilation cache when starting map collection' do
    lib = File.expand_path('../../lib', __dir__)
    env = {
      'DISABLE_BOOTSNAP_COMPILE_CACHE' => nil,
      'DISABLE_BOOTSNAP' => nil,
      'DISABLE_BOOTSNAP_LOAD_PATH_CACHE' => nil,
    }
    probe = <<~RUBY
      abort 'coverage disabled' unless Coverage.running?
      if defined?(Bootsnap::CompileCache::ISeq) && Bootsnap::CompileCache::ISeq.cache_dir
        abort 'instruction sequence cache enabled'
      end
      abort 'YAML cache enabled' if defined?(Bootsnap::CompileCache::YAML)
      abort 'load path cache disabled' unless Bootsnap::LoadPathCache.enabled?
    RUBY

    Dir.mktmpdir do |cache_dir|
      env['BOOTSNAP_CACHE_DIR'] = cache_dir
      output, status = Open3.capture2e(env, RbConfig.ruby, '-I', lib, '-rrails_tia/boot', '-rbootsnap/setup', '-e', probe)

      expect(status).to be_success, output
    end
  end
end
