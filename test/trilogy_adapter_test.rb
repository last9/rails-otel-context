# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class TrilogyAdapterTest < Minitest::Test
  include SpanHelpers

  ValidContext = Struct.new(:valid?)

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Trilogy.instance_variable_set(:@patch_module, nil)
  end

  def test_query_sets_source_attributes
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment_service.rb', 33, label: 'PaymentService#charge') do
      with_current_span_with_valid_context do |span|
        result = client.query('SELECT 1')
        assert_equal :ok_query, result
        assert_equal 'PaymentService', span.attributes['code.namespace']
        assert_equal 'charge',         span.attributes['code.function']
        assert_equal 'app/services/payment_service.rb', span.attributes['code.filepath']
        assert_equal 33, span.attributes['code.lineno']
      end
    end
  end

  def test_query_skips_when_span_context_invalid
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/models/user.rb', 10) do
      with_current_span_with_invalid_context do |span|
        result = client.query('SELECT 1')
        assert_equal :ok_query, result
        assert_empty span.attributes
      end
    end
  end

  def test_query_skips_source_attributes_when_no_source_location
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    patch.define_singleton_method(:call_site_for_app) { nil }

    with_current_span_with_valid_context do |span|
      client.query('SELECT 1')
      refute span.attributes.key?('code.filepath')
      refute span.attributes.key?('code.lineno')
      refute span.attributes.key?('code.namespace')
    end
  end

  def test_install_skips_when_trilogy_not_defined
    refute defined?(::Trilogy), '::Trilogy should not be defined in test environment'
    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd)
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

  def with_thread_source(path, lineno, label: nil)
    thread_singleton = Thread.singleton_class
    location = OpenStruct.new(absolute_path: File.join(Dir.pwd, path), path: nil,
                              lineno: lineno, label: label)
    had_original = Thread.respond_to?(:each_caller_location)

    if had_original
      thread_singleton.class_eval do
        alias_method :__rails_otel_context_original_each_caller_location, :each_caller_location
      end
    end
    thread_singleton.define_method(:each_caller_location) { |&block| block.call(location) }

    yield
  ensure
    if had_original
      thread_singleton.class_eval do
        alias_method :each_caller_location, :__rails_otel_context_original_each_caller_location
        remove_method :__rails_otel_context_original_each_caller_location
      end
    else
      thread_singleton.class_eval { remove_method :each_caller_location }
    end
  end

  def with_current_span_with_valid_context
    fake_span = FakeSpan.new
    fake_span.define_singleton_method(:context) { ValidContext.new(true) }

    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__rails_otel_context_original_current_span, :current_span
      define_method(:current_span) { fake_span }
    end

    yield fake_span
  ensure
    singleton.class_eval do
      alias_method :current_span, :__rails_otel_context_original_current_span
      remove_method :__rails_otel_context_original_current_span
    end
  end

  def with_current_span_with_invalid_context
    fake_span = FakeSpan.new
    fake_span.define_singleton_method(:context) { ValidContext.new(false) }

    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__rails_otel_context_original_current_span, :current_span
      define_method(:current_span) { fake_span }
    end

    yield fake_span
  ensure
    singleton.class_eval do
      alias_method :current_span, :__rails_otel_context_original_current_span
      remove_method :__rails_otel_context_original_current_span
    end
  end
end
