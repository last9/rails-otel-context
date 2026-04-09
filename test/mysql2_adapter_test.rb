# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class Mysql2AdapterTest < Minitest::Test
  include CallerLocationHelpers
  include SpanHelpers

  ValidContext = Struct.new(:valid?)

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
  end

  def test_query_pushes_frame_context_during_super
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    captured_frame = nil
    client_class = Class.new do
      define_method(:query) do |_sql, _options = {}|
        captured_frame = RailsOtelContext::FrameContext.current
        :ok_query
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 33, label: 'Payment#charge') do
      result = client.query('SELECT 1')
      assert_equal :ok_query, result
      assert_equal 'Payment', captured_frame[:class_name]
      assert_equal 'charge',  captured_frame[:method_name]
      assert_equal 'app/services/payment.rb', captured_frame[:filepath]
      assert_equal 33, captured_frame[:lineno]
    end
  ensure
    RailsOtelContext::FrameContext.clear!
  end

  def test_prepare_pushes_frame_context_during_super
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    captured_frame = nil
    client_class = Class.new do
      define_method(:prepare) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        :ok_prepare
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 44, label: 'Payment#prepare_stmt') do
      result = client.prepare('SELECT ?')
      assert_equal :ok_prepare, result
      assert_equal 'app/services/payment.rb', captured_frame[:filepath]
      assert_equal 44, captured_frame[:lineno]
    end
  ensure
    RailsOtelContext::FrameContext.clear!
  end

  def test_query_clears_frame_context_after_super
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 10, label: 'Payment#charge') do
      client.query('SELECT 1')
      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared after query returns'
    end
  end

  def test_query_clears_frame_context_on_exception
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = Class.new do
      def query(_sql, _options = {})
        raise 'db error'
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 10, label: 'Payment#charge') do
      assert_raises(RuntimeError) { client.query('SELECT 1') }
      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared even when query raises'
    end
  end

  def test_query_skips_frame_context_when_no_source_location
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    captured_frame = :not_called
    client_class = Class.new do
      define_method(:query) do |_sql, _options = {}|
        captured_frame = RailsOtelContext::FrameContext.current
        :ok_query
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    patch.define_singleton_method(:call_site_for_app) { nil }

    client.query('SELECT 1')
    assert_nil captured_frame, 'FrameContext must not be set when no source location found'
  end

  # End-to-end: verifies the full pipeline with CallContextProcessor
  def test_query_sets_source_attributes_on_child_span_not_parent
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    processor = RailsOtelContext::CallContextProcessor.new(app_root: Dir.pwd)

    parent_span = FakeSpan.new
    parent_span.define_singleton_method(:context) { ValidContext.new(true) }
    child_span = FakeSpan.new
    child_span.define_singleton_method(:context) { ValidContext.new(true) }

    current = parent_span
    client_class = Class.new do
      define_method(:query) do |_sql, _options = {}|
        current = child_span
        processor.on_start(child_span, nil)
        :ok_query
      ensure
        current = parent_span
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__rails_otel_context_original_current_span, :current_span
    end
    singleton.define_method(:current_span) { current }

    with_thread_source('/app/services/payment.rb', 33, label: 'Payment#charge') do
      client.query('SELECT 1')

      assert_equal 'Payment', child_span.attributes['code.namespace']
      assert_equal 'charge',  child_span.attributes['code.function']
      refute parent_span.attributes.key?('code.namespace'),
             'parent span must NOT receive code.namespace'
    end
  ensure
    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :current_span, :__rails_otel_context_original_current_span
      remove_method :__rails_otel_context_original_current_span
    end
    RailsOtelContext::FrameContext.clear!
  end

  def new_client_class
    Class.new do
      def query(_sql, _options = {})
        :ok_query
      end

      def prepare(_sql)
        :ok_prepare
      end
    end
  end
end
