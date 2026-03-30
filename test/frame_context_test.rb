# frozen_string_literal: true

require_relative 'test_helper'

class FrameContextTest < Minitest::Test
  def teardown
    RailsOtelContext::FrameContext.clear!
  end

  # ---------------------------------------------------------------------------
  # with_frame — block API
  # ---------------------------------------------------------------------------

  def test_with_frame_sets_current_during_block
    RailsOtelContext::FrameContext.with_frame(class_name: 'OrderService', method_name: 'call') do
      frame = RailsOtelContext::FrameContext.current
      assert_equal 'OrderService', frame[:class_name]
      assert_equal 'call', frame[:method_name]
    end
  end

  def test_with_frame_clears_after_block
    RailsOtelContext::FrameContext.with_frame(class_name: 'OrderService', method_name: 'call') {}
    assert_nil RailsOtelContext::FrameContext.current
  end

  def test_with_frame_restores_previous_frame_when_nested
    RailsOtelContext::FrameContext.with_frame(class_name: 'Outer', method_name: 'run') do
      RailsOtelContext::FrameContext.with_frame(class_name: 'Inner', method_name: 'exec') do
        assert_equal 'Inner', RailsOtelContext::FrameContext.current[:class_name]
      end
      assert_equal 'Outer', RailsOtelContext::FrameContext.current[:class_name]
    end
    assert_nil RailsOtelContext::FrameContext.current
  end

  def test_with_frame_restores_even_on_exception
    assert_raises(RuntimeError) do
      RailsOtelContext::FrameContext.with_frame(class_name: 'Foo', method_name: 'bar') do
        raise 'boom'
      end
    end
    assert_nil RailsOtelContext::FrameContext.current
  end

  # ---------------------------------------------------------------------------
  # push / pop — manual API
  # ---------------------------------------------------------------------------

  def test_push_sets_current
    RailsOtelContext::FrameContext.push(class_name: 'InvoiceJob', method_name: 'perform')
    frame = RailsOtelContext::FrameContext.current
    assert_equal 'InvoiceJob', frame[:class_name]
    assert_equal 'perform', frame[:method_name]
  end

  def test_pop_clears_current
    RailsOtelContext::FrameContext.push(class_name: 'InvoiceJob', method_name: 'perform')
    RailsOtelContext::FrameContext.pop
    assert_nil RailsOtelContext::FrameContext.current
  end

  # ---------------------------------------------------------------------------
  # Module-level delegates on RailsOtelContext
  # ---------------------------------------------------------------------------

  def test_module_with_frame_delegate
    RailsOtelContext.with_frame(class_name: 'PaymentsController', method_name: 'create') do
      assert_equal 'PaymentsController', RailsOtelContext::FrameContext.current[:class_name]
    end
  end

  def test_module_push_pop_delegates
    RailsOtelContext.push_frame(class_name: 'Worker', method_name: 'perform')
    assert_equal 'Worker', RailsOtelContext::FrameContext.current[:class_name]
    RailsOtelContext.pop_frame
    assert_nil RailsOtelContext::FrameContext.current
  end

  # ---------------------------------------------------------------------------
  # Frameable mixin
  # ---------------------------------------------------------------------------

  def test_frameable_with_otel_frame_pushes_class_and_method
    service = Class.new do
      include RailsOtelContext::Frameable

      def call
        with_otel_frame { Thread.current[:_rails_otel_ctx_frame] }
      end
    end

    frame = service.new.call
    assert_equal 'call', frame[:method_name]
  end

  def test_frameable_explicit_method_name
    service = Class.new do
      include RailsOtelContext::Frameable

      def run
        with_otel_frame('run') { Thread.current[:_rails_otel_ctx_frame] }
      end
    end

    frame = service.new.run
    assert_equal 'run', frame[:method_name]
  end
end
