# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class PgAdapterTest < Minitest::Test
  include CallerLocationHelpers
  include SpanHelpers

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
  end

  def test_exec_pushes_frame_context_during_super
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: Dir.pwd)

    captured_frame = nil
    host_class = Class.new do
      define_method(:exec) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        result = :ok
        block_given? ? yield(result) : result
      end
    end
    host_class.prepend(patch)
    host = host_class.new

    with_thread_source('/app/models/checkout.rb', 88, label: 'Checkout#process') do
      host.exec('select 1')
      assert_equal 'Checkout', captured_frame[:class_name]
      assert_equal 'process',  captured_frame[:method_name]
      assert_equal 'app/models/checkout.rb', captured_frame[:filepath]
      assert_equal 88, captured_frame[:lineno]
    end
  ensure
    RailsOtelContext::FrameContext.clear!
  end

  def test_exec_clears_frame_context_after_super
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: Dir.pwd)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    with_thread_source('/app/models/checkout.rb', 88, label: 'Checkout#process') do
      host.exec('select 1')
      assert_nil RailsOtelContext::FrameContext.current,
                 'FrameContext must be cleared after exec returns'
    end
  end

  def test_exec_skips_frame_context_when_no_source
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: '/unlikely/root')

    captured_frame = :not_called
    host_class = Class.new do
      define_method(:exec) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        result = :ok
        block_given? ? yield(result) : result
      end
    end
    host_class.prepend(patch)
    host = host_class.new

    host.exec('select 1')
    assert_nil captured_frame, 'FrameContext must not be set when no source location found'
  end

  def test_user_block_is_forwarded_to_result
    patch = RailsOtelContext::Adapters::PG.send(:build_patch_module, [:exec])
    patch.configure(app_root: Dir.pwd)

    host_class = new_host_class
    host_class.prepend(patch)
    host = host_class.new

    yielded = nil
    host.exec('select 1') { |r| yielded = r }
    assert_equal :ok, yielded
  ensure
    RailsOtelContext::FrameContext.clear!
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
end
