require 'prism'
require 'set'

module RailsTia
  # Join literal qualified reads to assignments without evaluating application constants.
  class ConstantReads
    def initialize(config)
      definitions = Hash.new { |hash, key| hash[key] = Set.new }
      reads = Hash.new { |hash, key| hash[key] = [] }
      root = File.join(config.root, '')
      project_root = File.join(File.realpath(config.root), '')
      roots = config.app_dirs.map { |dir| File.absolute_path(dir, config.root) }.uniq
      app_files = roots.flat_map do |dir|
        Dir.glob('**/*.rb', base: dir).map { |file| File.join(dir, file) }
      end.to_set
      test_files = Dir.glob(config.spec_glob, base: config.root).map { |file| File.absolute_path(file, config.root) }
      (app_files | test_files).each do |path|
        next unless path.end_with?('.rb') && path.start_with?(root) && File.file?(path)
        next unless File.realpath(path).start_with?(project_root)

        parsed = Prism.parse_file(path)
        next unless parsed.success?

        file = path.delete_prefix(root)
        assignments = app_files.include?(path) ? definitions : nil
        Source.new(file, assignments, reads[file]).visit(parsed.value)
      end

      @dependencies = {}
      reads.each do |file, references|
        groups = {}
        references.uniq.each do |name, range|
          sources = definitions.fetch(name, []).reject { |source| source == file }
          (groups[range] ||= Set.new).merge(sources) unless sources.empty?
        end
        @dependencies[file] = groups unless groups.empty?
      end
    end

    def sources(file, lines, previous)
      groups = @dependencies[file]
      return [] unless groups

      groups.flat_map do |range, files|
        if range.nil? || range.any? { |line| lines[line - 1].to_i > (previous && previous[line - 1]).to_i }
          files.to_a
        else
          []
        end
      end
    end

    class Source
      def initialize(file, definitions, reads)
        @file = file
        @definitions = definitions
        @reads = reads
      end

      def visit(node, scope = '', range = nil)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = constant_name(node.constant_path)
          if node.is_a?(Prism::ClassNode) && node.superclass
            visit(node.superclass, scope, range)
          end
          if name && node.body
            nested = name.start_with?('::') ? name : "#{scope}::#{name}"
            visit(node.body, nested, nil)
          end
          return
        when Prism::DefNode
          body = node.body || node
          range = body.location.start_line..body.location.end_line
        when Prism::ConstantWriteNode
          record_definition(node.name.to_s, scope)
        when Prism::ConstantPathWriteNode
          record_definition(constant_name(node.target), scope)
          visit(node.value, scope, range)
          return
        when Prism::ConstantPathNode
          name = constant_name(node)
          @reads << [name, range] if name
        end
        node.compact_child_nodes.each { |child| visit(child, scope, range) }
      end

      private

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          return "::#{node.name}" unless node.parent

          parent = constant_name(node.parent)
          "#{parent}::#{node.name}" if parent
        end
      end

      def record_definition(name, scope)
        return unless @definitions && name

        full = name.start_with?('::') ? name : "#{scope}::#{name}"
        @definitions[full] << @file
        # A relative read can resolve in an enclosing namespace.
        parts = full.delete_prefix('::').split('::')
        parts.each_index do |index|
          @definitions[parts[index..].join('::')] << @file
        end
      end
    end
    private_constant :Source
  end
end
