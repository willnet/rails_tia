# Start Coverage before the test framework or application when generating a map.
#
#   bundle exec ruby -rrails_tia/boot -S rspec ...
#
# For a combined RSpec run, start SimpleCov first so it can choose the coverage modes.
# One-shot line coverage cannot identify later specs that execute the same line.
require 'coverage'

# Bootsnap's instruction sequence cache cannot compile while coverage is active on Ruby 3.4.
ENV['DISABLE_BOOTSNAP_COMPILE_CACHE'] = '1'

Coverage.start(lines: true) unless Coverage.running?
