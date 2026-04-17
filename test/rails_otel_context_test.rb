# frozen_string_literal: true

require_relative 'test_helper'

# Tests for the top-level RailsOtelContext module: delegates, install_processor! idempotency.
class RailsOtelContextTest < Minitest::Test
  def teardown
    RailsOtelContext.reset_configuration!
    RailsOtelContext::FrameContext.clear!
    RailsOtelContext.instance_variable_set(:@processor_installed, nil)
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
  # Guards @processor_installed so calling twice doesn't add the processor twice.

  def test_install_processor_is_idempotent
    return skip 'Rails not defined' unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

    add_calls = 0
    fake_provider = Object.new
    fake_provider.define_singleton_method(:respond_to?) { |m| m == :add_span_processor || super }
    fake_provider.define_singleton_method(:add_span_processor) { |_| add_calls += 1 }

    original = OpenTelemetry.tracer_provider
    OpenTelemetry.tracer_provider = fake_provider

    RailsOtelContext.install_processor!
    RailsOtelContext.install_processor!

    assert_equal 1, add_calls, 'add_span_processor must be called exactly once regardless of call count'
  ensure
    OpenTelemetry.tracer_provider = original
    RailsOtelContext.instance_variable_set(:@processor_installed, nil)
  end

  def test_install_processor_skips_when_provider_lacks_add_span_processor
    return skip 'Rails not defined' unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

    fake_provider = Object.new # no add_span_processor method

    original = OpenTelemetry.tracer_provider
    OpenTelemetry.tracer_provider = fake_provider

    assert_silent { RailsOtelContext.install_processor! }
    refute RailsOtelContext.instance_variable_get(:@processor_installed),
           '@processor_installed must stay false when provider is not SDK-capable'
  ensure
    OpenTelemetry.tracer_provider = original
    RailsOtelContext.instance_variable_set(:@processor_installed, nil)
  end
end
