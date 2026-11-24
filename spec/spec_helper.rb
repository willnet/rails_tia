require 'rails_tia'
# Load these dependencies only for the CLI; lib/rails_tia.rb omits them
# to avoid introducing unnecessary dependencies into the formatter.
require 'rails_tia/audit'
require 'rails_tia/ci'
require 'rails_tia/junit_report'
require 'rails_tia/metrics'

require 'fileutils'
require 'tmpdir'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

module SpecSupport
  # Create real files in a temporary directory for code that checks file existence,
  # such as static mappings and prediction.
  def with_project(files)
    Dir.mktmpdir('rails_tia') do |root|
      files.each do |path|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "# #{path}\n")
      end
      yield root
    end
  end
end

RSpec.configure { |config| config.include SpecSupport }
