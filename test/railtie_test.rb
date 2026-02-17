# frozen_string_literal: true

require_relative 'test_helper'
require 'rails'
require 'rails/application'
require 'fileutils'
require 'tmpdir'
require 'rails_otel_context/railtie'

class RailtieTest < Minitest::Test
  include EnvHelpers

  def setup
    RailsOtelContext.reset_configuration!
  end

  def test_railtie_applies_env_and_installs_adapters_on_active_record_load
    app_root = Dir.mktmpdir('rails_otel_context_dummy_app')
    FileUtils.mkdir_p(File.join(app_root, 'config'))

    install_calls = []
    adapters_singleton = RailsOtelContext::Adapters.singleton_class
    adapters_singleton.class_eval do
      alias_method :__rails_otel_context_original_install, :install!
      define_method(:install!) do |app_root:, config:|
        install_calls << {
          app_root: app_root.to_s,
          pg_enabled: config.pg_slow_query_enabled,
          pg_threshold: config.pg_slow_query_threshold_ms
        }
      end
    end

    app_class = Class.new(Rails::Application) do
      config.root = app_root
      config.eager_load = false
      config.hosts.clear
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = 'x' * 64
    end

    with_env(
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED' => 'true',
      'RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS' => '321.0'
    ) do
      app = app_class.instance
      app.initialize!
      ActiveSupport.run_load_hooks(:active_record, Object.new)
    end

    assert_equal 1, install_calls.size
    assert_equal app_root, install_calls[0][:app_root]
    assert_equal true, install_calls[0][:pg_enabled]
    assert_equal 321.0, install_calls[0][:pg_threshold]
  ensure
    adapters_singleton.class_eval do
      alias_method :install!, :__rails_otel_context_original_install
      remove_method :__rails_otel_context_original_install
    end
    FileUtils.remove_entry(app_root) if app_root && Dir.exist?(app_root)
  end
end
