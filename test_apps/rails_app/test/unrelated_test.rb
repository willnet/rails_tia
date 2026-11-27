require_relative 'test_helper'

class UnrelatedTest < ActiveSupport::TestCase
  def test_value
    assert_equal 'unrelated', UnrelatedValue.call
  end
end
