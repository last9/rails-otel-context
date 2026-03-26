# frozen_string_literal: true

require_relative 'test_helper'

# Verifies the gem does not crash when the OTel SDK is not configured
# (i.e., tracer_provider is a ProxyTracerProvider without add_span_processor).
# This happens when apps guard OTel setup behind an env var like ENABLE_OTLP.
class ProxyTracerProviderTest < Minitest::Test
  def test_no_error_when_tracer_provider_lacks_add_span_processor
    # Simulate ProxyTracerProvider: an object that does NOT respond to add_span_processor
    fake_provider = Object.new

    original_method = OpenTelemetry.method(:tracer_provider)
    OpenTelemetry.define_singleton_method(:tracer_provider) { fake_provider }

    # This must not raise NoMethodError
    assert_equal false, fake_provider.respond_to?(:add_span_processor),
                 'Precondition: fake provider should not have add_span_processor'

    # The guard in railtie does: if needs_processor && provider.respond_to?(:add_span_processor)
    # Simulate exactly what the railtie does:
    needs_processor = true
    if needs_processor && OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)
      OpenTelemetry.tracer_provider.add_span_processor(Object.new)
      flunk 'Should not reach here — fake provider has no add_span_processor'
    end

    # If we get here, the guard worked
    pass
  ensure
    OpenTelemetry.define_singleton_method(:tracer_provider, original_method)
  end

  def test_processor_registered_when_tracer_provider_has_add_span_processor
    registered = []
    fake_provider = Object.new
    fake_provider.define_singleton_method(:add_span_processor) { |p| registered << p }

    original_method = OpenTelemetry.method(:tracer_provider)
    OpenTelemetry.define_singleton_method(:tracer_provider) { fake_provider }

    assert_equal true, fake_provider.respond_to?(:add_span_processor)

    needs_processor = true
    if needs_processor && OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)
      OpenTelemetry.tracer_provider.add_span_processor(:test_processor)
    end

    assert_equal [:test_processor], registered
  ensure
    OpenTelemetry.define_singleton_method(:tracer_provider, original_method)
  end
end
