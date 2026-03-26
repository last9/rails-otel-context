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

  def test_query_sets_source_attributes_for_slow_queries
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 0.0 }
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 33) do
      with_current_span_with_valid_context do |span|
        result = client.query('SELECT 1')
        assert_equal :ok_query, result
        assert_equal 'app/services/payment.rb', span.attributes['code.filepath']
        assert_equal 33, span.attributes['code.lineno']
        assert span.attributes.key?('db.query.duration_ms')
        assert_equal 0.0, span.attributes['db.query.slow_threshold_ms']
      end
    end
  end

  def test_query_skips_attributes_for_fast_queries
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 999_999.0 }
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    patch.configure(app_root: Dir.pwd, threshold_ms: 999_999.0)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/services/payment.rb', 22) do
      with_current_span_with_valid_context do |span|
        client.query('SELECT 1')
        refute span.attributes.key?('code.filepath')
        refute span.attributes.key?('code.lineno')
      end
    end
  end

  def test_query_sets_activerecord_context
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    with_thread_source('/app/models/user.rb', 10) do
      with_current_span_with_valid_context do |span|
        with_activerecord_context(model_name: 'User', method_name: 'find_by') do
          client.query('SELECT * FROM users WHERE email = ?')
          assert_equal 'User', span.attributes['code.activerecord.model']
          assert_equal 'find_by', span.attributes['code.activerecord.method']
        end
      end
    end
  end

  def test_query_applies_span_name_formatter
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    RailsOtelContext.configuration.span_name_formatter = lambda { |_original, ar_context|
      "#{ar_context[:model_name]}.#{ar_context[:method_name]}"
    }

    with_thread_source('/app/models/user.rb', 10) do
      with_current_span_with_valid_context do |span|
        span.define_singleton_method(:name) { 'SELECT users' }
        span.define_singleton_method(:update_name) { |n| @updated_name = n }
        span.define_singleton_method(:updated_name) { @updated_name }

        with_activerecord_context(model_name: 'User', method_name: 'find') do
          client.query('SELECT * FROM users')
          assert_equal 'User.find', span.updated_name
        end
      end
    end
  ensure
    RailsOtelContext.configuration.span_name_formatter = nil
  end

  def test_query_skips_when_span_context_invalid
    patch = RailsOtelContext::Adapters::Trilogy.send(:build_patch_module)
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

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
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

    client_class = new_client_class
    client_class.prepend(patch)
    client = client_class.new

    # Stub source_location_for_app to return nil (no app source found)
    patch.define_singleton_method(:source_location_for_app) { nil }

    with_current_span_with_valid_context do |span|
      client.query('SELECT 1')
      refute span.attributes.key?('code.filepath')
      refute span.attributes.key?('code.lineno')
    end
  end

  def test_install_skips_when_trilogy_not_defined
    refute defined?(::Trilogy), '::Trilogy should not be defined in test environment'
    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd, threshold_ms: 200.0)
  end

  def test_install_does_not_double_prepend
    stub_trilogy = Class.new do
      def query(_sql)
        :ok_query
      end
    end

    Object.const_set(:Trilogy, stub_trilogy)

    patch = RailsOtelContext::Adapters::Trilogy.patch_module_for
    RailsOtelContext.configure { |c| c.trilogy_slow_query_threshold_ms = 200.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 200.0)

    # Install once
    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd, threshold_ms: 200.0)
    ancestors_after_first = stub_trilogy.ancestors.dup

    # Install again — should not prepend a second time
    RailsOtelContext::Adapters::Trilogy.install!(app_root: Dir.pwd, threshold_ms: 200.0)
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

  def with_activerecord_context(model_name:, method_name:)
    original = RailsOtelContext::ActiveRecordContext.method(:extract)
    RailsOtelContext::ActiveRecordContext.define_singleton_method(:extract) do |**_kwargs|
      { model_name: model_name, method_name: method_name }
    end

    yield
  ensure
    RailsOtelContext::ActiveRecordContext.define_singleton_method(:extract, original)
  end
end
