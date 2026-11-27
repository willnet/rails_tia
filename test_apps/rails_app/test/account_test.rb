require_relative 'test_helper'
require_relative 'support/shared_checks'

class AccountTest < ActiveSupport::TestCase
  include SharedChecks
  setup { NestedBefore.call }
  teardown { NestedAfter.call }

  test 'loads accounts and renders the shared partial' do
    assert_equal [], Account.all.to_a
    assert_includes AccountsController.render(partial: 'tracking/shared'), 'shared'
  end
end
