# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class Mysql2AdapterTest < Minitest::Test
  include SpanHelpers

  ValidContext = Struct.new(:valid?)

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
  end

  def test_query_sets_source_attributes
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 33) do
      with_current_span_with_valid_context do |span|
        result = client.query('SELECT 1')
        assert_equal :ok_query, result
        assert_equal 'app/services/payment.rb', span.attributes['code.filepath']
        assert_equal 33, span.attributes['code.lineno']
      end
    end
  end

  def test_prepare_sets_source_attributes
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 44) do
      with_current_span_with_valid_context do |span|
        result = client.prepare('SELECT ?')
        assert_equal :ok_prepare, result
        assert_equal 'app/services/payment.rb', span.attributes['code.filepath']
        assert_equal 44, span.attributes['code.lineno']
      end
    end
  end

  def test_query_skips_all_attributes_when_span_context_invalid
    patch = RailsOtelContext::Adapters::Mysql2.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 10) do
      fake_span = FakeSpan.new
      fake_span.define_singleton_method(:context) { ValidContext.new(false) }
      fake_span.define_singleton_method(:name) { 'SELECT payments' }

      singleton = OpenTelemetry::Trace.singleton_class
      singleton.class_eval do
        alias_method :__mysql2_test_orig_span, :current_span
        define_method(:current_span) { fake_span }
      end

      client.query('SELECT 1')
      refute fake_span.attributes.key?('code.filepath')
    ensure
      singleton.class_eval do
        alias_method :current_span, :__mysql2_test_orig_span
        remove_method :__mysql2_test_orig_span
      end
    end
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

  def with_thread_source(path, lineno)
    thread_singleton = Thread.singleton_class
    location = OpenStruct.new(absolute_path: File.join(Dir.pwd, path), path: nil, lineno: lineno)
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
end
