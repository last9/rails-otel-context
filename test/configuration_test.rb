# frozen_string_literal: true

require_relative 'test_helper'

class ConfigurationTest < Minitest::Test
  include EnvHelpers

  def setup
    RailsOtelContext.reset_configuration!
  end

  def test_apply_env_configuration
    with_env(
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED' => 'false',
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS' => '450.5',
      'RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_ENABLED' => 'true',
      'RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS' => '600',
      'RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED' => 'true',
      'RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED' => 'false',
      'RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS' => '700'
    ) do
      config = RailsOtelContext.apply_env_configuration!

      assert_equal false, config.pg_slow_query_enabled
      assert_equal 450.5, config.pg_slow_query_threshold_ms
      assert_equal true, config.mysql2_slow_query_enabled
      assert_equal 600.0, config.mysql2_slow_query_threshold_ms
      assert_equal true, config.redis_source_enabled
      assert_equal false, config.clickhouse_enabled
      assert_equal 700.0, config.clickhouse_slow_query_threshold_ms
    end
  end

  def test_legacy_slow_query_env_is_supported_for_pg
    with_env(
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS' => nil,
      'OTEL_SLOW_QUERY_MS' => '275'
    ) do
      config = RailsOtelContext.apply_env_configuration!
      assert_equal 275.0, config.pg_slow_query_threshold_ms
    end
  end

  def test_invalid_values_fall_back_to_defaults
    with_env(
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED' => 'invalid',
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS' => 'bad-number'
    ) do
      config = RailsOtelContext.apply_env_configuration!
      assert_equal true, config.pg_slow_query_enabled
      assert_equal 200.0, config.pg_slow_query_threshold_ms
      assert_equal true, config.mysql2_slow_query_enabled
      assert_equal true, config.clickhouse_enabled
    end
  end

  def test_default_call_context_enabled_is_true
    assert_equal true, RailsOtelContext.configuration.call_context_enabled
  end

  def test_call_context_enabled_env_var
    with_env('RAILS_OTEL_CONTEXT_CALL_CONTEXT_ENABLED' => 'false') do
      config = RailsOtelContext.apply_env_configuration!
      assert_equal false, config.call_context_enabled
    end
  end

  def test_call_context_enabled_env_var_truthy_values
    %w[1 true yes on].each do |val|
      with_env('RAILS_OTEL_CONTEXT_CALL_CONTEXT_ENABLED' => val) do
        config = RailsOtelContext.apply_env_configuration!
        assert_equal true, config.call_context_enabled, "Expected true for ENV value '#{val}'"
      end
    end
  end
end
