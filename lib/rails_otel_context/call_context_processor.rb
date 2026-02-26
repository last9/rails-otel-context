# frozen_string_literal: true

module RailsOtelContext
  # SpanProcessor that enriches all spans with the calling Ruby class and method name.
  #
  # Sets two attributes on every span (unless the call stack yields no app-code frame):
  #   - code.namespace  – the class name, e.g. "OrderService", "InvoiceJob"
  #   - code.function   – the method name, e.g. "create", "perform"
  #
  # Class names are extracted from the frame label when available (e.g. "User.find"),
  # and inferred from the file-path basename otherwise (e.g. order_service.rb → OrderService).
  #
  # Frames inside gems or outside app_root are always skipped.
  class CallContextProcessor
    def initialize(app_root:)
      @app_root = app_root.to_s
    end

    def on_start(span, _parent_context)
      return unless RailsOtelContext.configuration.call_context_enabled
      return unless Thread.respond_to?(:each_caller_location)

      context = extract_caller_context
      return unless context

      span.set_attribute('code.namespace', context[:class_name])
      span.set_attribute('code.function', context[:method_name]) if context[:method_name]
      return unless context[:lineno]

      span.set_attribute('code.filepath', context[:filepath])
      span.set_attribute('code.lineno', context[:lineno])
    end

    def on_finish(_span); end

    def force_flush(timeout: nil); end

    def shutdown(timeout: nil); end

    private

    def extract_caller_context
      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(@app_root)
        next if path.include?('/gems/')

        label    = location.label || ''
        lineno   = location.lineno
        filepath = path.delete_prefix("#{@app_root}/")

        # Try label first: "ClassName.method" or "ClassName#method"
        if label =~ /^([A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*)(\.|\#)/
          class_name  = Regexp.last_match(1)
          method_name = label.split(/[.\#]/, 2).last
                             &.sub(/^(?:block|rescue|ensure) in /, '')
          return { class_name: class_name, method_name: method_name, lineno: lineno, filepath: filepath }
        end

        # Fallback: infer class from file-path basename (snake_case → CamelCase)
        class_name  = File.basename(path, '.rb').split('_').map(&:capitalize).join
        method_name = label.sub(/^(?:block|rescue|ensure) in /, '')
        return { class_name: class_name, method_name: method_name.empty? ? nil : method_name,
                 lineno: lineno, filepath: filepath }
      end

      nil
    end
  end
end
