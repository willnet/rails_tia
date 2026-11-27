require_relative 'test_helper'
require_relative 'support/shared_checks'

class SharedTest < ActiveSupport::TestCase
  include SharedChecks
end
