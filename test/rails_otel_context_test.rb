# frozen_string_literal: true

require_relative 'test_helper'

# Tests for the top-level RailsOtelContext module: delegates, install_processor! idempotency.
class RailsOtelContextTest < Minitest::Test
  def teardown
    RailsOtelContext.reset_configuration!
    RailsOtelContext::FrameContext.clear!
    RailsOtelContext.instance_variable_set(:@processor_registered_on, nil)
    RailsOtelContext.instance_variable_set(:@hooks_installed, nil)
  end

  # ── FrameContext delegates ────────────────────────────────────────────────

  def test_with_frame_delegate_sets_context_during_block
    RailsOtelContext.with_frame(class_name: 'OrderService', method_name: 'call') do
      frame = RailsOtelContext::FrameContext.current
      assert_equal 'OrderService', frame[:class_name]
      assert_equal 'call',         frame[:method_name]
    end
    assert_nil RailsOtelContext::FrameContext.current
  end

  def test_push_and_pop_frame_delegates
    RailsOtelContext.push_frame(class_name: 'PaymentService', method_name: 'charge')
    frame = RailsOtelContext::FrameContext.current
    assert_equal 'PaymentService', frame[:class_name]

    RailsOtelContext.pop_frame
    assert_nil RailsOtelContext::FrameContext.current
  end

  # ── install_processor! idempotency ───────────────────────────────────────
  # Guards @processor_registered_on so calling twice against the same provider
  # does not add the processor twice.

  def test_install_processor_is_idempotent
    return skip 'Rails not defined' unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

    original  = OpenTelemetry.tracer_provider
    add_calls = 0
    fake_provider = Object.new
    fake_provider.define_singleton_method(:respond_to?) { |m| m == :add_span_processor || super }
    fake_provider.define_singleton_method(:add_span_processor) { |_| add_calls += 1 }

    OpenTelemetry.tracer_provider = fake_provider

    RailsOtelContext.install_processor!
    RailsOtelContext.install_processor!

    assert_equal 1, add_calls, 'add_span_processor must be called exactly once for the same provider'
  ensure
    OpenTelemetry.tracer_provider = original if original
    RailsOtelContext.instance_variable_set(:@processor_registered_on, nil)
  end

  def test_install_processor_reregisters_when_provider_replaced
    return skip 'Rails not defined' unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

    original  = OpenTelemetry.tracer_provider
    add_calls = 0
    make_provider = lambda do
      p = Object.new
      p.define_singleton_method(:respond_to?) { |m| m == :add_span_processor || super }
      p.define_singleton_method(:add_span_processor) { |_| add_calls += 1 }
      p
    end

    OpenTelemetry.tracer_provider = make_provider.call
    RailsOtelContext.install_processor!
    assert_equal 1, add_calls, 'should register on first provider'

    # Simulate OpenTelemetry::SDK.configure called again — replaces the provider
    OpenTelemetry.tracer_provider = make_provider.call
    RailsOtelContext.install_processor!
    assert_equal 2, add_calls, 'should re-register on new provider after SDK.configure replacement'

    # Same provider again — must not double-register
    RailsOtelContext.install_processor!
    assert_equal 2, add_calls, 'must not double-register on already-registered provider'
  ensure
    OpenTelemetry.tracer_provider = original if original
    RailsOtelContext.instance_variable_set(:@processor_registered_on, nil)
  end

  def test_install_processor_skips_when_provider_lacks_add_span_processor
    return skip 'Rails not defined' unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

    original      = OpenTelemetry.tracer_provider
    fake_provider = Object.new # no add_span_processor method

    OpenTelemetry.tracer_provider = fake_provider

    assert_silent { RailsOtelContext.install_processor! }
    assert_nil RailsOtelContext.instance_variable_get(:@processor_registered_on),
               '@processor_registered_on must stay nil when provider is not SDK-capable'
  ensure
    OpenTelemetry.tracer_provider = original if original
    RailsOtelContext.instance_variable_set(:@processor_registered_on, nil)
  end
end
