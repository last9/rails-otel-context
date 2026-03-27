# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class PgAdapterTest < Minitest::Test
  include SpanHelpers

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
  end

  def test_patch_sets_code_location_attributes
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: Dir.pwd)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_thread_source('/app/models/checkout.rb', 88) do
      with_current_span do |span|
        host.exec('select 1')
        assert_equal 'app/models/checkout.rb', span.attributes['code.filepath']
        assert_equal 88, span.attributes['code.lineno']
      end
    end
  end

  def test_patch_skips_attributes_when_source_is_nil
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: '/unlikely/root')

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_current_span do |span|
      host.exec('select 1')
      refute span.attributes.key?('code.filepath')
      refute span.attributes.key?('code.lineno')
    end
  end

  def test_user_block_is_forwarded_to_result
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: Dir.pwd)

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
