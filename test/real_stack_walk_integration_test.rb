# frozen_string_literal: true

require_relative 'test_helper'

# Integration tests that exercise the REAL Ruby call stack — no
# Thread.each_caller_location stubs. Verifies that call_site_for_app
# finds the correct app-code frame when called from inside
# with_call_site_frame (the new adapter code path).
#
# The test app code lives in test/fixtures/app/services/order_service.rb.
# The adapter is configured with app_root pointing at test/fixtures so
# that file is treated as "app code" by the stack-walk filter.
class RealStackWalkIntegrationTest < Minitest::Test
  include SpanHelpers

  ValidContext = Struct.new(:valid?)

  APP_ROOT = File.expand_path('fixtures', __dir__)

  def setup
    skip 'Requires Ruby >= 3.2' unless Thread.respond_to?(:each_caller_location)
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Trilogy.instance_variable_set(:@patch_module, nil)
    require_relative 'fixtures/app/services/order_service'
  end

  def teardown
    RailsOtelContext::FrameContext.clear!
  end

  # Verifies that with_call_site_frame finds the correct app frame
  # through the real Ruby call stack (no stubs). The call chain is:
  #
  #   test method (test/ dir — not under APP_ROOT, skipped)
  #     → OrderService#create (fixtures/app/ — under APP_ROOT, found!)
  #       → patched query → with_call_site_frame → call_site_for_app
  #         → Thread.each_caller_location (real stack walk)
  #
  def test_real_stack_walk_finds_app_frame_through_with_call_site_frame
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: APP_ROOT)

    captured_frame = nil
    client_class = Class.new do
      define_method(:query) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        :ok
      end
    end
    client_class.prepend(patch)

    service = OrderService.new(client_class.new)
    service.create

    refute_nil captured_frame, 'FrameContext must be set during query'
    assert_equal 'OrderService', captured_frame[:class_name],
                 'call_site_for_app must find OrderService through the real stack'
    assert_equal 'create', captured_frame[:method_name]
    assert_equal 'app/services/order_service.rb', captured_frame[:filepath]
    assert_equal 13, captured_frame[:lineno]
  end

  # End-to-end: real stack walk + processor reading FrameContext + child span.
  # Simulates the full OTel lifecycle without any stack-walk stubs.
  def test_real_stack_walk_child_span_gets_correct_attributes
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: APP_ROOT)

    processor = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)

    parent_span = FakeSpan.new
    parent_span.define_singleton_method(:context) { ValidContext.new(true) }
    child_span = FakeSpan.new
    child_span.define_singleton_method(:context) { ValidContext.new(true) }

    current = parent_span
    client_class = Class.new do
      define_method(:query) do |_sql|
        current = child_span
        processor.on_start(child_span, nil)
        :ok
      ensure
        current = parent_span
      end
    end
    client_class.prepend(patch)

    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__real_stack_test_orig, :current_span
    end
    singleton.define_method(:current_span) { current }

    service = OrderService.new(client_class.new)
    service.create

    assert_equal 'OrderService', child_span.attributes['code.namespace']
    assert_equal 'create', child_span.attributes['code.function']
    assert_equal 'app/services/order_service.rb', child_span.attributes['code.filepath']
    assert_equal 13, child_span.attributes['code.lineno']

    refute parent_span.attributes.key?('code.namespace'),
           'parent span must NOT get code.namespace from the adapter'
  ensure
    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :current_span, :__real_stack_test_orig
      remove_method :__real_stack_test_orig
    end
  end

  # Verifies nesting: controller-level with_frame is preserved after
  # the adapter's with_call_site_frame completes.
  def test_real_stack_walk_preserves_outer_frame_context
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: APP_ROOT)

    client_class = Class.new do
      def query(_sql)
        :ok
      end
    end
    client_class.prepend(patch)

    outer_frame = nil
    RailsOtelContext::FrameContext.with_frame(
      class_name: 'OrdersController', method_name: 'create'
    ) do
      service = OrderService.new(client_class.new)
      service.create

      outer_frame = RailsOtelContext::FrameContext.current
    end

    assert_equal 'OrdersController', outer_frame[:class_name],
                 'outer frame must be restored after adapter query completes'
    assert_equal 'create', outer_frame[:method_name]
    assert_nil RailsOtelContext::FrameContext.current,
               'frame must be nil after with_frame block exits'
  end
end
