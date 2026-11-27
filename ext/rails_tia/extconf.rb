if RUBY_ENGINE == 'ruby'
  require 'mkmf'
  require_relative '../../lib/rails_tia/native_extension'
  create_makefile(RailsTia::ALLOCATION_EXTENSION)
else
  File.write('Makefile', "all install clean:\n\t@echo 'NEWOBJ tracking requires CRuby'\n")
end
