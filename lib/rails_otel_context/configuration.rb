# frozen_string_literal: true

module RailsOtelContext
  class Configuration
    attr_accessor :redis_source_enabled,
                  :clickhouse_enabled,
                  :connection_pool_tracing_enabled,
                  :span_name_formatter,
                  :slow_query_threshold_ms,
                  :n_plus_one_threshold # nil = disabled (default). Set to e.g. 3 to flag repeating queries.

    # Deprecated: rails.controller / rails.action / rails.job are now always set
    # on every span. This option is kept for backwards compatibility and has no effect.
    attr_accessor :request_context_enabled

    attr_reader :custom_span_attributes

    def initialize
      @redis_source_enabled = false
      @clickhouse_enabled = false
      @connection_pool_tracing_enabled = false
      @span_name_formatter = nil
      @custom_span_attributes = nil
      @request_context_enabled = false
      @slow_query_threshold_ms = nil
      @n_plus_one_threshold = nil
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
