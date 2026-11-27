require 'set'

module RailsTia
  # Select spec files affected by a list of changed files.
  #
  # Take the union of three sources:
  #   1. Reverse lookup in the coverage map (primary).
  #   2. Static mappings for new files, templates, and missed classes without executable bodies.
  #   3. Changed spec files themselves.
  class Predictor
    Result = Struct.new(:full_run, :reason, :reason_code, :matches, :specs, :sources, keyword_init: true) do
      def full_run? = !!full_run
    end

    def initialize(config:, map:)
      @config = config
      @map = map
      @static_mapping = StaticMapping.new(config.static_mapping_rules, root: config.root)
      @fallback = Fallback.new(config: config, map: map)
    end

    def call(context, trace: false)
      reason_code, reason = @fallback.decision(context)
      if reason
        return Result.new(full_run: true, reason: reason, reason_code: reason_code,
                          specs: @config.all_specs, sources: context.changed_files)
      end

      specs = Set.new
      glob_cache = {}
      static_by_source = {} if trace
      context.changed_files.each do |path|
        static = @static_mapping.candidates_for(path, glob_cache: glob_cache)
        specs.merge(@map.specs_for(path)).merge(static)
        specs << path if spec_file?(path)
        static_by_source[path] = static if trace
      end

      specs.keep_if { |spec| File.exist?(File.join(@config.root, spec)) }
      matches = match_counts(static_by_source, specs) if trace
      Result.new(full_run: false, matches: matches, specs: specs.sort, sources: context.changed_files)
    end

    private

    def spec_file?(path)
      File.fnmatch?(@config.spec_glob, path, Configuration::FNMATCH_FLAGS)
    end

    def match_counts(static_by_source, selected)
      static_by_source.to_h do |source, static|
        counts = {
          mapped_specs: @map.specs_for(source).count { |spec| selected.include?(spec) },
          static_specs: static.count { |spec| selected.include?(spec) },
          changed_spec: spec_file?(source) && selected.include?(source),
        }
        [source, counts]
      end
    end
  end
end
