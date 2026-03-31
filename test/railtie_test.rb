# frozen_string_literal: true

require_relative 'test_helper'
require 'rails'
require 'rails/application'
require 'fileutils'
require 'tmpdir'
require 'rails_otel_context/railtie'

# All railtie tests share a single minimal Rails app boot.
# Booting more than once causes Rails' global on_load(:action_controller) registry
# to accumulate duplicate hook registrations, making run_load_hooks fire each
# block twice and breaking size assertions.
module RailtieTestSharedBoot
  APP_ROOT = Dir.mktmpdir('rails_otel_ctx_railtie_test')

  APP = begin
    FileUtils.mkdir_p(File.join(APP_ROOT, 'config'))
    app_class = Class.new(Rails::Application) do
      config.eager_load = false
      config.hosts.clear
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = 'x' * 64
    end
    app_class.config.root = APP_ROOT
    app_class.instance.initialize!
    app_class.instance
  end
end

class RailtieTest < Minitest::Test
  def setup
    RailsOtelContext.reset_configuration!
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = nil
    RailsOtelContext::FrameContext.clear!
    RailsOtelContext::RequestContext.clear!
  end

  def teardown
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = nil
    RailsOtelContext::FrameContext.clear!
    RailsOtelContext::RequestContext.clear!
  end

  def test_railtie_installs_adapters_on_active_record_load
    install_calls = []
    adapters_singleton = RailsOtelContext::Adapters.singleton_class
    adapters_singleton.class_eval do
      alias_method :__rails_otel_context_original_install, :install!
      define_method(:install!) do |app_root:, **|
        install_calls << { app_root: app_root.to_s }
      end
    end

    ActiveSupport.run_load_hooks(:active_record, Object.new)

    assert_equal 1, install_calls.size
    assert_equal RailtieTestSharedBoot::APP_ROOT, install_calls[0][:app_root]
  ensure
    adapters_singleton.class_eval do
      alias_method :install!, :__rails_otel_context_original_install
      remove_method :__rails_otel_context_original_install
    end
  end

  def test_frame_context_around_action_resets_query_count_at_request_start
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 5 }
    count_at_start = :not_checked

    with_frame_context_action('OrdersController', 'create') do
      count_at_start = Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
    end

    assert_nil count_at_start, 'QUERY_COUNT_KEY must be nil at request start (N+1 bleed fix)'
  end

  def test_frame_context_around_action_resets_query_count_after_request
    with_frame_context_action('OrdersController', 'create') do
      Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 2 }
    end

    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY],
               'QUERY_COUNT_KEY must be nil after request to avoid thread-reuse bleed'
  end

  def test_frame_context_around_action_pushes_frame_during_action
    frame_during = nil

    with_frame_context_action('UsersController', 'index') do
      frame_during = RailsOtelContext::FrameContext.current
    end

    assert_equal 'UsersController', frame_during&.fetch(:class_name)
    assert_equal 'index',           frame_during&.fetch(:method_name)
  end

  def test_frame_context_around_action_clears_frame_after_action
    with_frame_context_action('UsersController', 'index') { }

    assert_nil RailsOtelContext::FrameContext.current
  end

  def test_request_context_sets_controller_and_action_when_enabled
    RailsOtelContext.configure { |c| c.request_context_enabled = true }
    controller_during = nil
    action_during     = nil

    with_request_context_action('ProductsController', 'show') do
      controller_during = RailsOtelContext::RequestContext.controller
      action_during     = RailsOtelContext::RequestContext.action
    end

    assert_equal 'ProductsController', controller_during
    assert_equal 'show',               action_during
  end

  def test_request_context_clears_after_action_when_enabled
    RailsOtelContext.configure { |c| c.request_context_enabled = true }

    with_request_context_action('ProductsController', 'show') { }

    assert_nil RailsOtelContext::RequestContext.controller
    assert_nil RailsOtelContext::RequestContext.action
  end

  def test_request_context_not_registered_when_disabled
    captured = []
    stub_class = build_stub_controller_class('UsersController', 'index', captured)
    ActiveSupport.run_load_hooks(:action_controller, stub_class)

    assert_equal 1, captured.size,
                 'only install_frame_context should register an around_action when request_context disabled'
  end

  def test_to_prepare_resets_ar_table_model_map
    RailsOtelContext::ActiveRecordContext.ar_table_model_map
    refute_nil RailsOtelContext::ActiveRecordContext.instance_variable_get(:@ar_table_model_map)

    RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!

    assert_nil RailsOtelContext::ActiveRecordContext.instance_variable_get(:@ar_table_model_map),
               'reset_ar_table_model_map! should clear the cached map'
    assert_kind_of Hash, RailsOtelContext::ActiveRecordContext.ar_table_model_map,
                   'map should rebuild lazily after reset'
  end

  def test_after_initialize_warms_ar_table_model_map
    assert_kind_of Hash, RailsOtelContext::ActiveRecordContext.ar_table_model_map
  end

  private

  def build_stub_controller_class(class_name, action_name, captured_blocks)
    stub = Class.new
    stub.define_singleton_method(:name)          { class_name }
    stub.define_singleton_method(:around_action) { |&blk| captured_blocks << blk }
    stub
  end

  def fire_around_action(stub_class, action_name, action_block, around_block)
    instance = stub_class.new
    instance.define_singleton_method(:action_name) { action_name }
    instance.define_singleton_method(:class)       { stub_class }
    instance.instance_exec(instance, action_block, &around_block)
  end

  def with_frame_context_action(class_name, action_name, &action)
    captured = []
    stub     = build_stub_controller_class(class_name, action_name, captured)
    ActiveSupport.run_load_hooks(:action_controller, stub)
    fire_around_action(stub, action_name, action, captured.first)
  end

  def with_request_context_action(class_name, action_name, &action)
    captured = []
    stub     = build_stub_controller_class(class_name, action_name, captured)
    ActiveSupport.run_load_hooks(:action_controller, stub)
    fire_around_action(stub, action_name, action, captured[1])
  end
end
