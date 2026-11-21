# Start Coverage before the test framework or application when generating a map.
#
#   bundle exec ruby -rrspec_tia/boot -S rspec ...
#
# Load this entry point early for two reasons:
#
#   1. Coverage must start before application code loads, or its files cannot be tracked.
#   2. SimpleCov integrations often check Coverage.running? to avoid starting twice,
#      using code such as SimpleCov.start unless Coverage.running?. Starting first
#      can avoid conflicts without changing the application.
#
# Do not use oneshot_lines: clearing does not allow previously recorded lines to be recorded again.
# Only the first spec to execute each line would receive its dependency, corrupting the map (observed in practice).
require 'coverage'

# Bootsnap's instruction sequence cache cannot compile while coverage is active on Ruby 3.4.
ENV['DISABLE_BOOTSNAP_COMPILE_CACHE'] = '1'

Coverage.start(lines: true) unless Coverage.running?
