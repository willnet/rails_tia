module SharedChecks
  def test_shared
    assert_equal 'shared value', SharedValue.call
  end
end
