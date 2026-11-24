require 'rails_tia/version'
require 'rails_tia/configuration'
require 'rails_tia/context'
require 'rails_tia/map'
require 'rails_tia/static_mapping'
require 'rails_tia/fallback'
require 'rails_tia/predictor'

# Do not load these entry points here: the formatter requires rspec-core to be loaded,
# while boot must start Coverage as early as possible.
module RailsTia
  class Error < StandardError; end

  class << self
    attr_writer :config

    def config
      @config ||= Configuration.load(ENV['RAILS_TIA_CONFIG'])
    end

    # Record the commit used to generate the map for freshness checks
    # and for investigating missed predictions.
    def commit_sha
      ENV['CI_COMMIT_SHA'] || ENV['GITHUB_SHA']
    end
  end
end
