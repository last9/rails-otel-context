# frozen_string_literal: true

module RailsOtelContext
  # Shared call-site extraction for DB adapters and CallContextProcessor.
  #
  # Every adapter (Trilogy, PG, MySQL2) includes this on class << self and
  # calls call_site_for_app after (or around) the query. Because the adapter
  # is closer to user code in the call stack than CallContextProcessor#on_start
  # is, the walk reaches the app frame in fewer iterations — and returns
  # class + method + filepath + lineno in one shot.
  #
  # CallContextProcessor includes this too so it can share the same logic in
  # its stack-walk fallback path.
  module SourceLocation
    # Regex constants — compiled once, shared by all includers.
    CLASS_LABEL_RE  = /^([A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*)[.#]/
    BLOCK_LABEL_RE  = /^(?:block|rescue|ensure) in /
    METHOD_SPLIT_RE = /[.#]/
    private_constant :CLASS_LABEL_RE, :BLOCK_LABEL_RE, :METHOD_SPLIT_RE

    # Returns the first app-code frame as a Hash:
    #   { class_name:, method_name:, filepath:, lineno: }
    # Returns nil when no app frame is found or the feature is unavailable.
    # Requires +app_root+ to be defined on the including object.
    def call_site_for_app
      return unless Thread.respond_to?(:each_caller_location)

      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(app_root)
        next if path.include?('/gems/')

        return build_call_site(location, path)
      end

      nil
    end

    # Applies all four call-site attributes to +span+ in one go.
    def apply_call_site_to_span(span, site)
      return unless site && span.context.valid?

      span.set_attribute('code.namespace', site[:class_name])
      span.set_attribute('code.function',  site[:method_name]) if site[:method_name]
      span.set_attribute('code.filepath',  site[:filepath])
      span.set_attribute('code.lineno',    site[:lineno]) if site[:lineno]
    end

    # Legacy helper kept for callers that only need filepath + lineno.
    def source_location_for_app
      return unless Thread.respond_to?(:each_caller_location)

      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(app_root)
        next if path.include?('/gems/')

        return [path.delete_prefix("#{app_root}/"), location.lineno]
      end

      nil
    end

    # Legacy helper — use apply_call_site_to_span for new code.
    def apply_source_to_span(span, source)
      return unless source

      span.set_attribute('code.filepath', source[0])
      span.set_attribute('code.lineno',   source[1])
    end

    private

    def build_call_site(location, path)
      label    = location.label || ''
      lineno   = location.lineno
      filepath = path.delete_prefix("#{app_root}/")

      if label =~ CLASS_LABEL_RE
        class_name  = Regexp.last_match(1)
        method_name = label.split(METHOD_SPLIT_RE, 2).last
                           &.sub(BLOCK_LABEL_RE, '')
        return { class_name: class_name, method_name: method_name,
                 lineno: lineno, filepath: filepath }
      end

      class_name  = File.basename(path, '.rb').split('_').map(&:capitalize).join
      method_name = label.sub(BLOCK_LABEL_RE, '')
      { class_name: class_name,
        method_name: method_name.empty? ? nil : method_name,
        lineno: lineno, filepath: filepath }
    end
  end
end
