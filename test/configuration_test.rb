# frozen_string_literal: true

require_relative 'test_helper'

class ConfigurationTest < Minitest::Test
  def setup
    RailsOtelContext.reset_configuration!
  end

  def test_default_redis_source_enabled_is_false
    assert_equal false, RailsOtelContext.configuration.redis_source_enabled
  end

  def test_default_clickhouse_enabled_is_true
    assert_equal true, RailsOtelContext.configuration.clickhouse_enabled
  end

  def test_default_request_context_enabled_is_false
    assert_equal false, RailsOtelContext.configuration.request_context_enabled
  end

  def test_default_custom_span_attributes_is_nil
    assert_nil RailsOtelContext.configuration.custom_span_attributes
  end

  def test_custom_span_attributes_accepts_lambda
    fn = -> { { 'team' => 'payments' } }
    RailsOtelContext.configure { |c| c.custom_span_attributes = fn }
    assert_equal fn, RailsOtelContext.configuration.custom_span_attributes
  end

  def test_custom_span_attributes_accepts_proc
    fn = proc { { 'team' => 'payments' } }
    RailsOtelContext.configure { |c| c.custom_span_attributes = fn }
    assert_equal fn, RailsOtelContext.configuration.custom_span_attributes
  end

  def test_custom_span_attributes_accepts_nil
    RailsOtelContext.configure { |c| c.custom_span_attributes = nil }
    assert_nil RailsOtelContext.configuration.custom_span_attributes
  end

  def test_custom_span_attributes_rejects_non_callable
    assert_raises(ArgumentError) do
      RailsOtelContext.configure { |c| c.custom_span_attributes = 'not a callable' }
    end
  end

  def test_custom_span_attributes_rejects_hash
    assert_raises(ArgumentError) do
      RailsOtelContext.configure { |c| c.custom_span_attributes = { 'team' => 'x' } }
    end
  end
end
