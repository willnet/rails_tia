module RailsTia
  # Resolve class identities without invoking application-defined reflection methods.
  class DescribedClassSupport
    UNRESOLVED = Object.new.freeze
    MODULE_NAME = Module.instance_method(:name)
    ANCESTORS = Module.instance_method(:ancestors)
    AUTOLOAD = Module.instance_method(:autoload?)
    CONST_DEFINED = Module.instance_method(:const_defined?)
    CONST_GET = Module.instance_method(:const_get)
    SAME_OBJECT = BasicObject.instance_method(:equal?)
    SOURCE_LOCATION = Module.instance_method(:const_source_location)

    def initialize(root:, directories: nil)
      @root = "#{File.expand_path(root).delete_suffix('/')}/"
      @prefixes = directories ? directories.map { |dir| File.join(File.absolute_path(dir, @root), '') }.uniq : [@root]
      @files = {}.compare_by_identity
      @locations = {}.compare_by_identity
    end

    def files_for(target, include_anonymous: false)
      return @files[target] if @files.key?(target)
      return [] unless Module === target

      named = !MODULE_NAME.bind_call(target).to_s.empty?
      return [] unless named || include_anonymous

      complete = true
      files = ANCESTORS.bind_call(target).filter_map do |ancestor|
        next if MODULE_NAME.bind_call(ancestor).to_s.empty?

        location = @locations.fetch(ancestor) do
          resolved = definition_file(ancestor)
          @locations[ancestor] = resolved unless resolved.equal?(UNRESOLVED)
          resolved
        end
        if location.equal?(UNRESOLVED)
          complete = false
          next
        end
        location
      end.uniq.freeze
      @files[target] = files if named && complete
      files
    end

    private

    def definition_file(target)
      name = MODULE_NAME.bind_call(target)

      owner = Object
      parts = name.split('::')
      parts[0...-1].each do |part|
        # Never trigger autoload while resolving a stale or removed constant path.
        return UNRESOLVED unless Module === owner && CONST_DEFINED.bind_call(owner, part, false)
        return UNRESOLVED if AUTOLOAD.bind_call(owner, part, false)

        owner = CONST_GET.bind_call(owner, part, false)
      end
      leaf = parts.last
      return UNRESOLVED unless Module === owner && CONST_DEFINED.bind_call(owner, leaf, false)
      return UNRESOLVED if AUTOLOAD.bind_call(owner, leaf, false)
      return UNRESOLVED unless SAME_OBJECT.bind_call(target, CONST_GET.bind_call(owner, leaf, false))

      path = SOURCE_LOCATION.bind_call(owner, leaf, false)&.first
      return unless path

      path = File.expand_path(path)
      path.delete_prefix(@root) if path.start_with?(*@prefixes) && File.file?(path)
    rescue NameError, TypeError
      # Removed constants and unresolvable names do not prevent map generation.
      UNRESOLVED
    end
  end
end
