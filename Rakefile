require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc 'Build the native allocation tracker for this checkout'
task :compile do
  next unless RUBY_ENGINE == 'ruby'

  require_relative 'lib/rails_tia/native_extension'
  source = File.expand_path('ext/rails_tia/extconf.rb', __dir__)
  build = File.join('tmp', 'native', RUBY_PLATFORM, RUBY_VERSION)
  mkdir_p build
  Dir.chdir(build) do
    ruby source
    sh RbConfig::CONFIG.fetch('MAKE', 'make')
  end
  destination = File.join('lib', File.dirname(RailsTia::ALLOCATION_EXTENSION))
  mkdir_p destination
  cp File.join(build, "allocated_classes.#{RbConfig::CONFIG.fetch('DLEXT')}"), destination
end

task spec: :compile
