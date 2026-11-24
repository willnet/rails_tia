require 'rails_tia/ci/base'
require 'rails_tia/ci/gitlab'
require 'rails_tia/ci/git'
require 'rails_tia/ci/github_actions'

module RailsTia
  module Ci
    ADAPTERS = {
      'gitlab' => Gitlab,
      'github_actions' => GithubActions,
      'git' => Git,
    }.freeze

    # In auto mode, prefer a CI-specific adapter and fall back to Git if none is available.
    AUTO_ORDER = %w(gitlab git).freeze

    class UnknownAdapterError < StandardError; end

    def self.build(config)
      name = config.ci_adapter
      return build_auto(config) if name == 'auto'

      klass = ADAPTERS[name]
      raise UnknownAdapterError, "Unknown CI adapter: #{name.inspect}" if klass.nil?

      klass.new(config)
    end

    def self.build_auto(config)
      name = AUTO_ORDER.find { |candidate| ADAPTERS.fetch(candidate).available? }
      raise UnknownAdapterError, 'No CI adapter is available' if name.nil?

      ADAPTERS.fetch(name).new(config)
    end
  end
end
