# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class PgAdapterTest < Minitest::Test
  include SpanHelpers

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
  end

  def test_patch_sets_code_location_attributes_for_slow_queries
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    RailsOtelContext.configure { |c| c.pg_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 0.0)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_thread_source('/app/models/checkout.rb', 88) do
      with_current_span do |span|
        host.exec('select 1')
        assert_equal 'app/models/checkout.rb', span.attributes['code.filepath']
        assert_equal 88, span.attributes['code.lineno']
        assert span.attributes.key?('db.query.duration_ms')
        assert_equal 0.0, span.attributes['db.query.slow_threshold_ms']
      end
    end
  end

  def test_patch_skips_attributes_for_fast_queries
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    RailsOtelContext.configure { |c| c.pg_slow_query_threshold_ms = 999_999.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 999_999.0)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_thread_source('/app/models/checkout.rb', 44) do
      with_current_span do |span|
        host.exec('select 1')
        refute span.attributes.key?('code.filepath')
        refute span.attributes.key?('code.lineno')
      end
    end
  end

  def test_patch_skips_all_attributes_when_source_is_nil
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    RailsOtelContext.configure { |c| c.pg_slow_query_threshold_ms = 0.0 }
    patch.configure(app_root: '/unlikely/root', threshold_ms: 0.0)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_current_span do |span|
      host.exec('select 1')
      refute span.attributes.key?('code.filepath')
      refute span.attributes.key?('code.lineno')
      refute span.attributes.key?('db.query.duration_ms')
    end
  end

  def test_user_block_is_forwarded_to_result
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    RailsOtelContext.configure { |c| c.pg_slow_query_threshold_ms = 999_999.0 }
    patch.configure(app_root: Dir.pwd, threshold_ms: 999_999.0)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    yielded = nil
    with_current_span do
      host.exec('select 1') { |r| yielded = r }
    end
    assert_equal :ok, yielded
  end

  private

  def new_host_class
    Class.new do
      def exec(_sql)
        result = :ok
        block_given? ? yield(result) : result
      end
    end
  end

  # Stubs ActiveRecordContext.extract to return a canned value for the duration of the block.
  def with_ar_context(context)
    mod = RailsOtelContext::ActiveRecordContext
    mod.singleton_class.class_eval { alias_method :__ar_ctx_orig_extract, :extract }
    mod.define_singleton_method(:extract) { |**| context }
    yield
  ensure
    mod.singleton_class.class_eval do
      alias_method :extract, :__ar_ctx_orig_extract
      remove_method :__ar_ctx_orig_extract
    end
  end

  # Stubs OpenTelemetry::Trace.current_span with a span that also supports #name / #update_name.
  def with_named_span(initial_name)
    fake_span = FakeSpan.new
    fake_span.instance_variable_set(:@name, initial_name)
    fake_span.define_singleton_method(:name) { @name }
    fake_span.define_singleton_method(:name=) { |n| @name = n }

    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__pg_test_original_current_span, :current_span
      define_method(:current_span) { fake_span }
    end

    yield fake_span
  ensure
    singleton.class_eval do
      alias_method :current_span, :__pg_test_original_current_span
      remove_method :__pg_test_original_current_span
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
end
