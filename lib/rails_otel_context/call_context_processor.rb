# frozen_string_literal: true

module RailsOtelContext
  # SpanProcessor that enriches all spans with the calling Ruby class and method name,
  # and optionally with user-defined custom attributes.
  #
  # Sets span attributes (unless the call stack yields no app-code frame):
  #   - code.namespace  – the class name, e.g. "OrderService", "InvoiceJob"
  #   - code.function   – the method name, e.g. "create", "perform"
  #   - code.filepath   – app-relative source file
  #   - code.lineno     – source line number
  #
  # Three-tier call-context resolution (fastest to slowest):
  #   1. Pushed frame  — O(1) thread-local read. Set by Railtie around_action for
  #                      controllers, or manually via RailsOtelContext.with_frame.
  #   2. Stack walk    — O(stack depth). Falls back here when no frame is pushed.
  #                      DB adapters (Trilogy, PG, MySQL2) additionally overwrite
  #                      code.* attributes post-query from a shallower stack position,
  #                      giving the exact call site (e.g. UserRepository#find_active:23).
  #
  # Custom attributes (configured via +custom_span_attributes+) are applied to every span.
  # The callable must return a Hash (or nil) and must be fast — it runs in the hot path
  # of every span creation. Exceptions in the callable are silently rescued to avoid
  # disrupting application request processing.
  class CallContextProcessor
    include RailsOtelContext::SourceLocation

    SPAN_CONTROLLER_ATTR = 'request.controller'
    SPAN_ACTION_ATTR     = 'request.action'
    AR_MODEL_ATTR        = 'code.activerecord.model'
    AR_METHOD_ATTR       = 'code.activerecord.method'
    AR_SCOPE_ATTR        = 'code.activerecord.scope'
    AR_QUERY_COUNT_ATTR  = 'db.query_count'
    AR_ASYNC_ATTR        = 'db.async'
    ORIG_NAME_ATTR       = 'l9.orig.name'

    # Exposed so SourceLocation mixin can use it for the stack-walk path.
    attr_reader :app_root

    def initialize(app_root:, config: RailsOtelContext.configuration)
      @app_root = app_root.to_s
      @request_context_enabled = config.request_context_enabled
      @custom_span_attributes = config.custom_span_attributes
      @span_name_formatter = config.span_name_formatter
    end

    def on_start(span, _parent_context)
      apply_call_context(span)
      apply_request_context(span) if @request_context_enabled
      apply_db_context(span)
      apply_custom_attributes(span) if @custom_span_attributes
    end

    def on_finish(_span); end

    def force_flush(timeout: nil); end

    def shutdown(timeout: nil); end

    private

    def apply_call_context(span)
      # Fast path: caller pushed a frame explicitly — O(1), zero allocations.
      pushed = FrameContext.current
      if pushed
        span.set_attribute('code.namespace', pushed[:class_name])
        span.set_attribute('code.function', pushed[:method_name]) if pushed[:method_name]
        return
      end

      # Fallback: walk the call stack to find the first app-code frame.
      return unless Thread.respond_to?(:each_caller_location)

      site = call_site_for_app
      return unless site

      span.set_attribute('code.namespace', site[:class_name])
      span.set_attribute('code.function', site[:method_name]) if site[:method_name]
      return unless site[:lineno]

      span.set_attribute('code.filepath', site[:filepath])
      span.set_attribute('code.lineno', site[:lineno])
    end

    def apply_request_context(span)
      controller, action = RequestContext.fetch
      return unless controller

      span.set_attribute(SPAN_CONTROLLER_ATTR, controller)
      span.set_attribute(SPAN_ACTION_ATTR, action) if action
    end

    def apply_db_context(span)
      base_context = ActiveRecordContext.current
      return unless base_context

      # Shallow copy to avoid mutating the shared thread-local hash
      ar_context = base_context.dup
      enrich_ar_context(span, ar_context)
      set_ar_attributes(span, ar_context)
      apply_span_name_formatter(span, ar_context)
    rescue StandardError
      # Never let AR context or formatter errors break span processing
    end

    def enrich_ar_context(span, ar_context)
      return unless span.respond_to?(:attributes)

      ar_context[:code_namespace] = span.attributes['code.namespace']
      ar_context[:code_function] = span.attributes['code.function']
    end

    def set_ar_attributes(span, ar_context)
      span.set_attribute(AR_MODEL_ATTR, ar_context[:model_name]) if ar_context[:model_name]
      span.set_attribute(AR_METHOD_ATTR, ar_context[:method_name]) if ar_context[:method_name]
      span.set_attribute(AR_SCOPE_ATTR, ar_context[:scope_name]) if ar_context[:scope_name]
      span.set_attribute(AR_QUERY_COUNT_ATTR, ar_context[:query_count]) if ar_context[:query_count]
      span.set_attribute(AR_ASYNC_ATTR, true) if ar_context[:async]
    end

    def apply_span_name_formatter(span, ar_context)
      return unless @span_name_formatter

      original_name = span.name
      new_name = @span_name_formatter.call(original_name, ar_context)
      return unless new_name && new_name != original_name && span.respond_to?(:name=)

      span.set_attribute(ORIG_NAME_ATTR, original_name)
      span.name = new_name
    end

    def apply_custom_attributes(span)
      attrs = @custom_span_attributes.call
      return unless attrs.is_a?(Hash) && !attrs.empty?

      attrs.each do |key, value|
        span.set_attribute(key, value) unless value.nil?
      end
    rescue StandardError
      # Never let a user-supplied callback break span processing.
    end
  end
end
