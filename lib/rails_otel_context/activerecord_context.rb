# frozen_string_literal: true

module RailsOtelContext
  # Extracts ActiveRecord model name, method, and scope from sql.active_record
  # notifications and scope instrumentation.
  #
  # Two mechanisms work together:
  # 1. sql.active_record subscriber — captures model name + AR operation type
  #    (e.g., "Transaction Load") at query time via payload[:name].
  # 2. Scope tracking — wraps scope-generated methods to store the scope name
  #    on the Relation object, then captures it at materialization time via
  #    Relation#exec_queries. This handles lazy scopes like
  #    Transaction.recent_completed.to_a where the scope method returns before
  #    SQL fires.
  module ActiveRecordContext
    THREAD_KEY       = :_rails_otel_ctx_ar
    SCOPE_THREAD_KEY = :_rails_otel_ctx_scope
    private_constant :THREAD_KEY, :SCOPE_THREAD_KEY

    # Tracks class methods (def self.name) that return an AR::Relation so their
    # name is captured as code.activerecord.scope, complementing ScopeNameTracking
    # which only handles the scope macro. Uses singleton_method_added to intercept
    # methods after definition and source_location to skip Rails/gem internals.
    module ClassMethodScopeTracking
      def singleton_method_added(name)
        super

        @_otel_wrapped_class_methods ||= {}
        return if @_otel_wrapped_class_methods[name]

        app_root = RailsOtelContext::ActiveRecordContext.app_root
        return unless app_root

        begin
          loc = method(name).source_location
        rescue NameError
          return
        end
        loc_path = File.expand_path(loc[0])
        return unless loc_path.start_with?(app_root)
        return if loc_path.include?('/gems/')

        # Mark before define_singleton_method to prevent re-entrancy for this name
        @_otel_wrapped_class_methods[name] = true
        name_str = name.to_s.freeze
        original = method(name)

        define_singleton_method(name) do |*args, **kwargs, &blk|
          result = original.call(*args, **kwargs, &blk)
          if defined?(::ActiveRecord::Relation) && result.is_a?(::ActiveRecord::Relation)
            result.instance_variable_set(:@_otel_scope_name, name_str)
          end
          result
        end
      rescue StandardError
        nil
      end
    end

    # Subscriber for sql.active_record notifications.
    class Subscriber
      def start(_name, _id, payload)
        ar_name = payload[:name]
        return unless ar_name
        return if ar_name == 'SCHEMA' || ar_name.start_with?('CACHE') || ar_name == 'SQL'

        ctx = ActiveRecordContext.parse_ar_name(ar_name)
        return unless ctx

        # Include scope name if one was captured by RelationScopeCapture
        scope = Thread.current[SCOPE_THREAD_KEY]
        ctx[:scope_name] = scope if scope
        Thread.current[THREAD_KEY] = ctx

        # Enrich the current span directly. When OTel instruments via driver-level
        # prepend (Trilogy, PG, Mysql2), the span is created BEFORE this notification
        # fires, so CallContextProcessor#on_start sees nil AR context. Applying here
        # fixes those spans after the fact.
        return unless defined?(OpenTelemetry::Trace)

        ActiveRecordContext.apply_to_span(OpenTelemetry::Trace.current_span, ctx)
      end

      def finish(_name, _id, _payload)
        Thread.current[THREAD_KEY] = nil
      end
    end

    # Wraps scope-generated class methods to store the scope name on the Relation.
    module ScopeNameTracking
      def scope(name, body, &)
        super

        # Guard against double-wrapping on class reload in development
        @_otel_wrapped_scopes ||= {}
        return if @_otel_wrapped_scopes[name]

        name_str = name.to_s.freeze
        original = method(name)
        define_singleton_method(name) do |*args|
          relation = original.call(*args)
          if relation.is_a?(::ActiveRecord::Relation)
            relation.instance_variable_set(:@_otel_scope_name, name_str)
          end
          relation
        end
        @_otel_wrapped_scopes[name] = true
      end
    end

    # Captures scope name from Relation at SQL materialization time.
    module RelationScopeCapture
      def exec_queries(&)
        scope_name = instance_variable_get(:@_otel_scope_name)
        Thread.current[SCOPE_THREAD_KEY] = scope_name if scope_name
        super
      ensure
        Thread.current[SCOPE_THREAD_KEY] = nil
      end
    end

    module_function

    def install!(app_root: nil)
      @app_root = File.expand_path(app_root.to_s) if app_root

      return unless defined?(::ActiveSupport::Notifications)
      return unless defined?(::ActiveRecord::Base)

      ActiveSupport::Notifications.subscribe('sql.active_record', Subscriber.new)
      ::ActiveRecord::Base.extend(ScopeNameTracking)
      ::ActiveRecord::Base.extend(ClassMethodScopeTracking)
      ::ActiveRecord::Relation.prepend(RelationScopeCapture)
    end

    def app_root
      @app_root
    end

    def current
      Thread.current[THREAD_KEY]
    end

    def clear!
      Thread.current[THREAD_KEY] = nil
      Thread.current[SCOPE_THREAD_KEY] = nil
    end

    # Test helpers: set AR context directly for unit tests.
    def stub_context(context)
      Thread.current[THREAD_KEY] = context
    end

    def stub_scope(scope_name)
      Thread.current[SCOPE_THREAD_KEY] = scope_name
    end

    # Applies AR context directly to a span. Used by Subscriber#start to enrich spans
    # created by driver-level OTel instrumentation (Trilogy, PG) before our notification
    # subscriber runs. Also reads code.namespace/code.function already set by
    # CallContextProcessor#on_start so the span_name_formatter has full context.
    def apply_to_span(span, ctx)
      return unless span.context.valid?

      span.set_attribute('code.activerecord.model', ctx[:model_name]) if ctx[:model_name]
      span.set_attribute('code.activerecord.method', ctx[:method_name]) if ctx[:method_name]
      span.set_attribute('code.activerecord.scope', ctx[:scope_name]) if ctx[:scope_name]

      formatter = RailsOtelContext.configuration.span_name_formatter
      return unless formatter

      # Dup deferred to here: set_attribute calls above need only the original ctx keys.
      # The formatter may inspect code.namespace/code.function already on the span.
      ar_ctx = ctx.dup
      if span.respond_to?(:attributes)
        ar_ctx[:code_namespace] = span.attributes['code.namespace']
        ar_ctx[:code_function]  = span.attributes['code.function']
      end

      original_name = span.name
      new_name = formatter.call(original_name, ar_ctx)
      return unless new_name && new_name != original_name && span.respond_to?(:name=)

      span.set_attribute('l9.orig.name', original_name)
      span.name = new_name
    rescue StandardError
      nil
    end

    # Parses "Transaction Load" → { model_name: "Transaction", method_name: "Load" }
    def parse_ar_name(name)
      return nil unless name

      parts = name.split(' ', 2)
      return nil unless parts.size == 2

      model_name = parts[0]
      method_name = parts[1]

      return nil if model_name == 'ActiveRecord'

      { model_name: model_name, method_name: method_name }
    end
  end
end
