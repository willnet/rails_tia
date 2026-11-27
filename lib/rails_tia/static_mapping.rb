module RailsTia
  # Map source files to specs using naming conventions.
  #
  # Supplement coverage dependencies in three cases:
  #   - Newly added files absent from the map.
  #   - Files without executable method bodies, including those missed by ActiveRecord notifications.
  #   - Templates such as HAML that do not appear in coverage.
  #
  # Rules map a source regex to path templates or fixed globs. Captures replace %s in templates.
  # Discard nonexistent targets, naturally excluding mismatches caused by typos or singular/plural naming.
  class StaticMapping
    class InvalidGlob < StandardError; end

    Rule = Struct.new(:pattern, :templates, :globs, keyword_init: true)

    def initialize(rules, root: Dir.pwd)
      @root = root
      @rules = Array(rules).map do |rule|
        raise KeyError, 'static_mapping requires test or test_glob' unless rule.key?('test') || rule.key?('test_glob')

        globs = Array(rule['test_glob'])
        globs.each { |glob| validate_relative_glob!(glob) }
        Rule.new(
          pattern: Regexp.new("\\A(?:#{Array(rule.fetch('source')).join('|')})\\z"),
          templates: Array(rule['test']),
          globs: globs,
        )
      end
    end

    def call(paths)
      glob_cache = {}
      candidates = paths.flat_map { |path| candidates_for(path, glob_cache: glob_cache) }
      candidates.uniq.select { |spec| File.exist?(File.join(@root, spec)) }
    end

    def specs_for(path)
      call([path])
    end

    def candidates_for(path, glob_cache: {})
      @rules.flat_map do |rule|
        match = rule.pattern.match(path)
        next [] if match.nil?

        paths = rule.templates.filter_map { |template| format_template(template, match.captures) }
        rule.globs.each do |glob|
          glob_cache[glob] ||= glob_specs(glob)
          paths.concat(glob_cache[glob])
        end
        paths
      end.uniq
    end

    private

    def validate_relative_glob!(glob)
      return if glob.is_a?(String) && !File.absolute_path?(glob) && !glob.split('/').include?('..')

      raise InvalidGlob, "test_glob must be relative to the project root without '..' components: #{glob.inspect}"
    end

    def glob_specs(glob)
      root = File.realpath(@root)
      prefix = File.join(root, '')
      Dir.glob(glob, base: root).select do |spec|
        # Brace alternatives can expand into parent or absolute paths.
        validate_relative_glob!(spec)
        path = File.join(root, spec)
        File.file?(path) && File.realpath(path).start_with?(prefix)
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end
    end

    # Ignore a rule if its number of %s placeholders does not match the capture count.
    # A typo in one rule should not prevent the rest of the prediction from completing.
    def format_template(template, captures)
      format(template, *captures)
    rescue ArgumentError, TypeError
      warn "[rails_tia] static_mapping template placeholders do not match capture groups: #{template.inspect} <- #{captures.inspect}"
      nil
    end
  end
end
