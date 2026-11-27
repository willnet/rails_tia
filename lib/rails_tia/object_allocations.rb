require 'rails_tia/described_class_support'
require 'rails_tia/native_extension'

module RailsTia
  class ObjectAllocations
    def initialize(root, directories:)
      require ALLOCATION_EXTENSION
      @tracker = AllocatedClasses.new
      @resolver = DescribedClassSupport.new(root: root, directories: directories)
    end

    def start
      @tracker.drain
      @tracker.start
    end

    def stop = @tracker.stop

    def flush
      @tracker.drain.flat_map { |klass| @resolver.files_for(klass, include_anonymous: true) }.uniq
    end
  end
end
