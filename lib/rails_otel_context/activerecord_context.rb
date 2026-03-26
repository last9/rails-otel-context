# frozen_string_literal: true

module RailsOtelContext
  # Extracts ActiveRecord model name and method from sql.active_record
  # notifications using a subscriber object with start/finish callbacks.
  #
  # The start callback fires BEFORE the query executes, setting the AR context
  # in a thread-local. The CallContextProcessor reads it when OTel creates
  # the DB CLIENT span (which happens during query execution, between start
  # and finish). The finish callback clears the context.
  #
  # This approach matches how Datadog, Scout APM, and OTel's own ActiveRecord
  # instrumentation extract model names — via payload[:name] which Rails sets
  # to strings like "Transaction Load", "User Count", "Order Create".
  module ActiveRecordContext
    THREAD_KEY = :_rails_otel_ctx_ar

    # Subscriber object with start/finish methods for ActiveSupport::Notifications.
    class Subscriber
      def start(_name, _id, payload)
        ar_name = payload[:name]
        return unless ar_name
        return if ar_name == 'SCHEMA' || ar_name.start_with?('CACHE') || ar_name == 'SQL'

        ctx = ActiveRecordContext.parse_ar_name(ar_name)
        Thread.current[THREAD_KEY] = ctx if ctx
      end

      def finish(_name, _id, _payload)
        Thread.current[THREAD_KEY] = nil
      end
    end

    module_function

    def install!
      return unless defined?(::ActiveSupport::Notifications)
      return unless defined?(::ActiveRecord::Base)

      ActiveSupport::Notifications.subscribe('sql.active_record', Subscriber.new)
    end

    # Returns the current AR context from thread-local.
    def current
      Thread.current[THREAD_KEY]
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

    # Legacy method for adapter tests.
    def extract(app_root:)
      current
    end
  end
end
