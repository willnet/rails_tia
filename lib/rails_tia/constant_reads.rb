require 'prism'
require 'rubydex'
require 'set'

module RailsTia
  class ConstantReads
    def initialize(config)
      root = File.join(config.root, '')
      real_root = File.join(File.realpath(config.root), '')
      included = lambda do |path|
        path.start_with?(root) && path.end_with?('.rb') && File.file?(path) && File.realpath(path).start_with?(real_root)
      end
      app_files = config.app_dirs.flat_map do |dir|
        absolute = File.absolute_path(dir, root)
        Dir.glob('**/*.rb', base: absolute).map { |file| File.join(absolute, file) }
      end.select(&included).to_set
      tests = Dir.glob(config.spec_glob, base: root).map { |file| File.absolute_path(file, root) }.select(&included)

      graph = Rubydex::Graph.new
      graph.index_all((app_files | tests).to_a)
      graph.resolve
      @dependencies = {}
      methods = {}
      graph.declarations.each do |declaration|
        next unless declaration.is_a?(Rubydex::Constant) || declaration.is_a?(Rubydex::ConstantAlias)

        index_references(declaration, app_files, root, methods)
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

    private

    def index_references(declaration, app_files, root, methods)
      definitions = declaration.definitions.filter_map do |definition|
        location = definition.location
        next unless location.uri.start_with?('file:')

        path = location.to_file_path
        path.delete_prefix(root) if app_files.include?(path)
      end.uniq
      return if definitions.empty?

      declaration.references.each do |reference|
        location = reference.location
        next unless location.uri.start_with?('file:')

        path = location.to_file_path
        file = path.delete_prefix(root)
        sources = definitions - [file]
        next if sources.empty?

        ranges = methods[path] ||= method_ranges(Prism.parse_file(path).value)
        line = location.start_line + 1
        body = ranges.find { |definition_range, _| definition_range.cover?(line) }&.last
        groups = (@dependencies[file] ||= {})
        (groups[body] ||= Set.new).merge(sources)
      end
    end

    def method_ranges(node, ranges = [])
      # Prefer the innermost method when Ruby definitions are nested.
      node.compact_child_nodes.each { |child| method_ranges(child, ranges) }
      if node.is_a?(Prism::DefNode)
        body = node.body || node
        ranges << [node.location.start_line..node.location.end_line, body.location.start_line..body.location.end_line]
      end
      ranges
    end
  end
end
