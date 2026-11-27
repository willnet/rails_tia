require_relative '../config/environment'
require 'rails/test_help'
load Rails.root.join('db/schema.rb')
Account.columns
AccountsController.render(partial: 'tracking/boot')

if ENV['FIXTURE_PARALLEL_WITH']
  ActiveSupport::TestCase.parallelize(workers: 2, with: ENV.fetch('FIXTURE_PARALLEL_WITH').to_sym, threshold: 0)
end

Minitest.after_run { SuiteAfter.call }
