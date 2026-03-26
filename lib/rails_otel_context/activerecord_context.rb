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

    def install!
      return unless defined?(::ActiveSupport::Notifications)
      return unless defined?(::ActiveRecord::Base)

      ActiveSupport::Notifications.subscribe('sql.active_record', Subscriber.new)
      ::ActiveRecord::Base.extend(ScopeNameTracking)
      ::ActiveRecord::Relation.prepend(RelationScopeCapture)
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
    private :stub_scope

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

    # Legacy method for adapter tests.
    def extract(app_root: nil) # rubocop:disable Lint/UnusedMethodArgument
      current
    end
  end
end
