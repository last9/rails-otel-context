# frozen_string_literal: true

# rails-otel-goodies is a Rails-specific gem
# Skip Rails check in test environment to allow unit testing
unless defined?(Rails) || ENV['RAILS_OTEL_GOODIES_TEST']
  raise LoadError, 'rails-otel-goodies requires Rails. This gem is designed for Rails applications only.'
end

require 'rails_otel_goodies/version'
require 'rails_otel_goodies/configuration'
require 'rails_otel_goodies/activerecord_context'
require 'rails_otel_goodies/adapters'
require 'rails_otel_goodies/railtie' if defined?(Rails::Railtie)

module RailsOtelGoodies
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def apply_env_configuration!(config = configuration)
      config.pg_slow_query_enabled =
        bool_env('RAILS_OTEL_GOODIES_PG_SLOW_QUERY_ENABLED', config.pg_slow_query_enabled)
      config.pg_slow_query_threshold_ms =
        float_env('RAILS_OTEL_GOODIES_PG_SLOW_QUERY_MS',
                  float_env('OTEL_SLOW_QUERY_MS', config.pg_slow_query_threshold_ms))

      config.mysql2_slow_query_enabled =
        bool_env('RAILS_OTEL_GOODIES_MYSQL2_SLOW_QUERY_ENABLED', config.mysql2_slow_query_enabled)
      config.mysql2_slow_query_threshold_ms =
        float_env('RAILS_OTEL_GOODIES_MYSQL2_SLOW_QUERY_MS', config.mysql2_slow_query_threshold_ms)

      config.redis_source_enabled =
        bool_env('RAILS_OTEL_GOODIES_REDIS_SOURCE_ENABLED', config.redis_source_enabled)
      config.clickhouse_enabled =
        bool_env('RAILS_OTEL_GOODIES_CLICKHOUSE_ENABLED', config.clickhouse_enabled)
      config.clickhouse_slow_query_threshold_ms =
        float_env('RAILS_OTEL_GOODIES_CLICKHOUSE_SLOW_QUERY_MS', config.clickhouse_slow_query_threshold_ms)

      config
    end

    def float_env(key, default)
      value = ENV.fetch(key, nil)
      return default if value.nil? || value.strip.empty?

      Float(value)
    rescue ArgumentError, TypeError
      default
    end

    def bool_env(key, default)
      value = ENV.fetch(key, nil)
      return default if value.nil? || value.strip.empty?

      return true if %w[1 true yes on].include?(value.strip.downcase)
      return false if %w[0 false no off].include?(value.strip.downcase)

      default
    end
  end
end
