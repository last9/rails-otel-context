# frozen_string_literal: true

module RailsOtelContext
  class Configuration
    attr_accessor :pg_slow_query_enabled,
                  :pg_slow_query_threshold_ms,
                  :mysql2_slow_query_enabled,
                  :mysql2_slow_query_threshold_ms,
                  :trilogy_slow_query_enabled,
                  :trilogy_slow_query_threshold_ms,
                  :redis_source_enabled,
                  :clickhouse_enabled,
                  :clickhouse_slow_query_threshold_ms,
                  :span_name_formatter,
                  :call_context_enabled,
                  :custom_span_attributes_enabled,
                  :request_context_enabled

    attr_reader :custom_span_attributes

    def initialize
      @pg_slow_query_enabled = true
      @pg_slow_query_threshold_ms = 200.0
      @mysql2_slow_query_enabled = true
      @mysql2_slow_query_threshold_ms = 200.0
      @trilogy_slow_query_enabled = true
      @trilogy_slow_query_threshold_ms = 200.0
      @redis_source_enabled = false
      @clickhouse_enabled = true
      @clickhouse_slow_query_threshold_ms = 200.0
      @span_name_formatter = nil
      @call_context_enabled = true
      @custom_span_attributes = nil
      @custom_span_attributes_enabled = true
      @request_context_enabled = false
    end

    # Accepts a callable (lambda/proc) that returns a Hash of string keys to string values.
    # The callable is invoked on every span start, so it must be fast.
    # Returning nil or an empty hash is a no-op.
    #
    # Example:
    #   config.custom_span_attributes = -> {
    #     { "team" => Current.team } if Current.team.present?
    #   }
    def custom_span_attributes=(callable)
      unless callable.nil? || callable.respond_to?(:call)
        raise ArgumentError, 'custom_span_attributes must be a callable (lambda/proc) or nil'
      end

      @custom_span_attributes = callable
    end
  end
end
