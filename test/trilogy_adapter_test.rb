# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class TrilogyAdapterTest < Minitest::Test
  include CallerLocationHelpers
  include SpanHelpers

  ValidContext = Struct.new(:valid?)

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Trilogy.instance_variable_set(:@patch_module, nil)
  end

  def test_query_pushes_frame_context_during_super
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    captured_frame = nil
    client_class = Class.new do
      define_method(:query) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        :ok_query
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment_service.rb', 33, label: 'PaymentService#charge') do
      result = client.query('SELECT 1')
      assert_equal :ok_query, result
      assert_equal 'PaymentService', captured_frame[:class_name]
      assert_equal 'charge',         captured_frame[:method_name]
      assert_equal 'app/services/payment_service.rb', captured_frame[:filepath]
      assert_equal 33, captured_frame[:lineno]
    end
  ensure
    RailsOtelContext::FrameContext.clear!
  end

  def test_query_clears_frame_context_after_super
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/models/user.rb', 10, label: 'User#save') do
      client.query('SELECT 1')
      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared after query returns'
    end
  end

  def test_query_clears_frame_context_on_exception
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = Class.new do
      def query(_sql)
        raise 'db error'
      end
    end
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/models/user.rb', 10, label: 'User#save') do
      assert_raises(RuntimeError) { client.query('SELECT 1') }
      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared even when query raises'
    end
  end

  def test_query_skips_frame_context_when_no_source_location
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    captured_frame = :not_called
    client_class = Class.new do
      define_method(:query) do |_sql|
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

  def test_install_skips_when_trilogy_not_defined
    refute defined?(::Trilogy), '::Trilogy should not be defined in test environment'
    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd)
  end

  # Reproduces the production bug: OTel's Trilogy instrumentation creates a
  # child span inside super(sql) and makes it current_span, then calls
  # on_start on the span processor. When that span finishes, current_span
  # reverts to the parent. The old code called apply_call_site_to_span
  # AFTER super — so code.* attributes landed on the parent span instead
  # of the DB child span.
  def test_query_sets_source_attributes_on_child_span_not_parent
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    processor = RailsOtelContext::CallContextProcessor.new(app_root: Dir.pwd)

    parent_span = FakeSpan.new
    parent_span.define_singleton_method(:context) { ValidContext.new(true) }
    child_span = FakeSpan.new
    child_span.define_singleton_method(:context) { ValidContext.new(true) }

    # Simulate OTel Trilogy: super(sql) creates child_span as current,
    # fires on_start, then finishes it (reverting to parent_span).
    current = parent_span
    client_class = Class.new do
      define_method(:query) do |_sql|
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

    with_thread_source('/app/services/payment_service.rb', 33, label: 'PaymentService#charge') do
      client.query('SELECT 1')

      assert_equal 'PaymentService', child_span.attributes['code.namespace'],
                   'code.namespace must be on the DB child span, not the parent'
      assert_equal 'charge', child_span.attributes['code.function']
      assert_equal 'app/services/payment_service.rb', child_span.attributes['code.filepath']
      assert_equal 33, child_span.attributes['code.lineno']
      refute parent_span.attributes.key?('code.namespace'),
             'parent span must NOT receive code.namespace — that belongs on the child'

      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared after query returns'
    end
  ensure
    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :current_span, :__rails_otel_context_original_current_span
      remove_method :__rails_otel_context_original_current_span
    end
    RailsOtelContext::FrameContext.clear!
  end

  def test_install_does_not_double_prepend
    stub_trilogy = Class.new do
      def query(_sql)
        :ok_query
      end
    end

    Object.const_set(:Trilogy, stub_trilogy)

    patch = RailsOtelContext::Adapters::Trilogy.patch_module_for
    patch.configure(app_root: Dir.pwd)

    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd)
    ancestors_after_first = stub_trilogy.ancestors.dup

    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd)
    ancestors_after_second = stub_trilogy.ancestors.dup

    assert_equal ancestors_after_first, ancestors_after_second
  ensure
    Object.send(:remove_const, :Trilogy)
    RailsOtelContext::Adapters::Trilogy.instance_variable_set(:@patch_module, nil)
  end

  private

  def new_client_class
    Class.new do
      def query(_sql)
        :ok_query
      end
    end
  end
end
