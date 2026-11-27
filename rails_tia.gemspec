require_relative 'lib/rails_tia/version'

Gem::Specification.new do |spec|
  spec.name = 'rails_tia'
  spec.version = RailsTia::VERSION
  spec.authors = ['Shinichi Maeshima']
  spec.summary = 'Test Impact Analysis for Rails applications'
  spec.description = <<~DESC
    Build a dependency map from RSpec coverage and select the spec files
    affected by changed files.
  DESC
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE.txt']
  spec.bindir = 'exe'
  spec.executables = %w(rails-tia)
  spec.require_paths = %w(lib)

  spec.add_dependency 'rubyzip', '~> 3.0'
  spec.add_dependency 'rexml', '~> 3.2'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
