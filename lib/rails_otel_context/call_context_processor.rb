# frozen_string_literal: true

module RailsOtelContext
  # SpanProcessor that enriches ALL spans with:
  #   - code.namespace / code.function / code.filepath / code.lineno
  #     (nearest app-code frame from the call stack — automatic, no manual setup)
  #   - rails.controller / rails.action   (when inside a controller action)
  #   - rails.job                         (when inside a job)
  #
  # Call-context resolution:
  #   1. Explicit override — O(1). If app code calls FrameContext.with_frame (or
  #      includes Frameable), that frame wins. Use this to intentionally override
  #      the automatic nearest-frame (e.g., to expose a service boundary rather
  #      than the inner repo it delegates to).
  #   2. Stack walk — O(stack depth). Default path when no override is active.
  #      DB adapters (Trilogy, PG, MySQL2, Redis, ClickHouse) additionally overwrite
  #      code.* post-query from a shallower position, giving exact call-site precision.
  #
  # rails.* attributes come from RequestContext (thread-local set by Railtie hooks)
  # and are applied unconditionally — no config gate.
  #
  # Custom attributes (configured via +custom_span_attributes+) are also applied.
  # The callable must return a Hash (or nil) and must be fast — hot path per span.
  class CallContextProcessor
    include RailsOtelContext::SourceLocation

    SPAN_CONTROLLER_ATTR        = 'rails.controller'
    SPAN_ACTION_ATTR            = 'rails.action'
    SPAN_JOB_ATTR               = 'rails.job'
    SPAN_JOB_QUEUE_LATENCY_ATTR = 'rails.job.queue_latency_ms'
    AR_MODEL_ATTR        = 'code.activerecord.model'
    AR_METHOD_ATTR       = 'code.activerecord.method'
    AR_SCOPE_ATTR        = 'code.activerecord.scope'
    AR_QUERY_COUNT_ATTR  = 'db.query_count'
    AR_ASYNC_ATTR        = 'db.async'
    ORIG_NAME_ATTR       = 'l9.orig.name'

    # Exposed so SourceLocation mixin can use it for the stack-walk path.
    attr_reader :app_root

    def initialize(app_root:, config: RailsOtelContext.configuration)
      @app_root                = app_root.to_s
      @custom_span_attributes  = config.custom_span_attributes
      @span_name_formatter     = config.span_name_formatter
      @slow_query_threshold_ms = config.slow_query_threshold_ms
    end

    def on_start(span, _parent_context)
      apply_call_context(span)
      apply_request_context(span)
      apply_db_context(span)
      apply_custom_attributes(span) if @custom_span_attributes
    end

    def on_finish(span)
      return unless @slow_query_threshold_ms
      return unless span.respond_to?(:attributes) && span.attributes&.key?('db.system')

      start_ns = span.start_timestamp
      end_ns   = span.end_timestamp
      return unless start_ns && end_ns

      duration_ms = (end_ns - start_ns) / 1_000_000.0
      return unless duration_ms >= @slow_query_threshold_ms

      # span.recording? is false here — the span has finished and current_span
      # has reverted to the HTTP parent. Write directly to the backing attributes
      # hash so db.slow lands on the actual DB span, not the HTTP parent.
      attrs = span.instance_variable_get(:@attributes)
      attrs.store(ActiveRecordContext::DB_SLOW_ATTR, true) if attrs.respond_to?(:store)
    rescue StandardError
      nil
    end

    def force_flush(timeout: nil); end

    def shutdown(timeout: nil); end

    private

    def apply_call_context(span)
      # Explicit override: app code called FrameContext.with_frame (or Frameable).
      # O(1) — no stack walk. Takes priority over automatic detection.
      pushed = FrameContext.current
      if pushed
        span.set_attribute('code.namespace', pushed[:class_name])
        span.set_attribute('code.function',  pushed[:method_name]) if pushed[:method_name]
        return
      end

      # Default: walk the call stack to find the nearest app-code frame.
      return unless Thread.respond_to?(:each_caller_location)

      site = call_site_for_app
      return unless site

      span.set_attribute('code.namespace', site[:class_name])
      span.set_attribute('code.function',  site[:method_name]) if site[:method_name]
      return unless site[:lineno]

      span.set_attribute('code.filepath', site[:filepath])
      span.set_attribute('code.lineno',   site[:lineno])
    end

    def apply_request_context(span)
      controller, action = RequestContext.fetch
      if controller
        span.set_attribute(SPAN_CONTROLLER_ATTR, controller)
        span.set_attribute(SPAN_ACTION_ATTR, action) if action
        return
      end

      job = RequestContext.job
      return unless job

      span.set_attribute(SPAN_JOB_ATTR, job)
      latency = RequestContext.queue_latency_ms
      span.set_attribute(SPAN_JOB_QUEUE_LATENCY_ATTR, latency) if latency
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
      return unless span.respond_to?(:attributes) && span.attributes&.key?('db.system')

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
