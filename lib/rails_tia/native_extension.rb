require 'rbconfig'

module RailsTia
  ALLOCATION_EXTENSION = File.join('rails_tia', RbConfig::CONFIG.fetch('arch'),
                                   RbConfig::CONFIG.fetch('ruby_version'), 'allocated_classes').freeze
end
