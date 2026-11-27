require_relative 'lib/rails_tia/version'

Gem::Specification.new do |spec|
  spec.name = 'rails_tia'
  spec.version = RailsTia::VERSION
  spec.authors = ['Shinichi Maeshima']
  spec.summary = 'Test Impact Analysis for Rails applications'
  spec.description = <<~DESC
    Build a dependency map from RSpec or Minitest coverage and select the test files
    affected by changed files.
  DESC
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.files = Dir['lib/**/*.rb', 'lib/rails_tia/templates/*.yml', 'ext/rails_tia/*.{rb,c}', 'exe/*',
                   'skills/rails-tia/SKILL.md', 'docs/configuration.md', 'docs/github-actions.md', 'README.md', 'LICENSE.txt']
  spec.extensions = ['ext/rails_tia/extconf.rb']
  spec.bindir = 'exe'
  spec.executables = %w(rails-tia)
  spec.require_paths = %w(lib)

  spec.add_dependency 'rubyzip', '~> 3.0'
  spec.add_dependency 'rexml', '~> 3.2'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
