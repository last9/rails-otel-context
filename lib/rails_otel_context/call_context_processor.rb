# frozen_string_literal: true

module RailsOtelContext
  # SpanProcessor that enriches all spans with the calling Ruby class and method name,
  # and optionally with user-defined custom attributes.
  #
  # Sets two attributes on every span (unless the call stack yields no app-code frame):
  #   - code.namespace  – the class name, e.g. "OrderService", "InvoiceJob"
  #   - code.function   – the method name, e.g. "create", "perform"
  #
  # Class names are extracted from the frame label when available (e.g. "User.find"),
  # and inferred from the file-path basename otherwise (e.g. order_service.rb → OrderService).
  #
  # Frames inside gems or outside app_root are always skipped.
  #
  # Custom attributes (configured via +custom_span_attributes+) are applied to every span.
  # The callable must return a Hash (or nil) and must be fast — it runs in the hot path
  # of every span creation. Exceptions in the callable are silently rescued to avoid
  # disrupting application request processing.
  class CallContextProcessor
    SPAN_CONTROLLER_ATTR = 'request.controller'
    SPAN_ACTION_ATTR     = 'request.action'

    def initialize(app_root:, config: RailsOtelContext.configuration)
      @app_root = app_root.to_s
      @call_context_enabled = config.call_context_enabled
      @request_context_enabled = config.request_context_enabled
      @custom_span_attributes = config.custom_span_attributes
      @custom_span_attributes_enabled = config.custom_span_attributes_enabled
      @has_each_caller_location = Thread.respond_to?(:each_caller_location)
    end

    def on_start(span, _parent_context)
      apply_call_context(span) if @call_context_enabled
      apply_request_context(span) if @request_context_enabled
      apply_custom_attributes(span) if @custom_span_attributes
    end

    def on_finish(_span); end

    def force_flush(timeout: nil); end

    def shutdown(timeout: nil); end

    private

    def apply_call_context(span)
      return unless @has_each_caller_location

      context = extract_caller_context
      return unless context

      span.set_attribute('code.namespace', context[:class_name])
      span.set_attribute('code.function', context[:method_name]) if context[:method_name]
      return unless context[:lineno]

      span.set_attribute('code.filepath', context[:filepath])
      span.set_attribute('code.lineno', context[:lineno])
    end

    def apply_request_context(span)
      controller, action = RequestContext.fetch
      return unless controller

      span.set_attribute(SPAN_CONTROLLER_ATTR, controller)
      span.set_attribute(SPAN_ACTION_ATTR, action) if action
    end

    def apply_custom_attributes(span)
      return unless @custom_span_attributes_enabled

      attrs = @custom_span_attributes.call
      return unless attrs.is_a?(Hash) && !attrs.empty?

      attrs.each do |key, value|
        span.set_attribute(key, value) unless value.nil?
      end
    rescue StandardError
      # Never let a user-supplied callback break span processing.
    end

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
