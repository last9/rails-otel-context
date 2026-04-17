# frozen_string_literal: true

require_relative 'test_helper'
require 'rails'
require 'rails/application'
require 'fileutils'
require 'tmpdir'

# Reproduces the `require: false` + manual `install!` failure mode.
#
# When the gem is loaded with `require: false` in Gemfile and installed from
# an initializer, `install_processor!` may run BEFORE the OTel SDK initializer
# has configured `OpenTelemetry.tracer_provider`. In that case the provider is
# a ProxyTracerProvider (no `add_span_processor`), and the processor is
# silently skipped — leaving spans without code.* attributes and span renames.
#
# The fix: when Rails is still booting, defer the actual registration to
# Rails.application.config.after_initialize, so it runs after all initializers
# (including OTel SDK setup) have finished.
class InstallProcessorDeferredTest < Minitest::Test
  def setup
    RailsOtelContext.instance_variable_set(:@processor_installed, nil)
    @original_tracer_provider = OpenTelemetry.method(:tracer_provider)
  end

  def teardown
    OpenTelemetry.define_singleton_method(:tracer_provider, @original_tracer_provider)
    RailsOtelContext.instance_variable_set(:@processor_installed, nil)
  end

  def test_defers_processor_install_until_after_initialize_when_sdk_not_ready
    proxy_provider = Object.new # no add_span_processor — simulates ProxyTracerProvider
    registered = []
    real_provider = Object.new
    real_provider.define_singleton_method(:add_span_processor) { |p| registered << p }

    deferred_blocks = []
    fake_config = Object.new
    fake_config.define_singleton_method(:after_initialize) { |&blk| deferred_blocks << blk }

    fake_app = Object.new
    fake_app.define_singleton_method(:initialized?) { false }
    fake_app.define_singleton_method(:config) { fake_config }

    with_rails_application(fake_app) do
      OpenTelemetry.define_singleton_method(:tracer_provider) { proxy_provider }

      RailsOtelContext.install_processor!

      # BUG: currently registers nothing AND schedules nothing. After fix:
      # should have scheduled a deferred block.
      assert_equal 1, deferred_blocks.size,
                   'install_processor! must defer to after_initialize when SDK not ready'
      assert_empty registered, 'must not register on proxy provider'

      # Simulate OTel SDK being configured between initializer and after_initialize.
      OpenTelemetry.define_singleton_method(:tracer_provider) { real_provider }

      deferred_blocks.first.call

      assert_equal 1, registered.size, 'processor must be registered after deferred block runs'
      assert_instance_of RailsOtelContext::CallContextProcessor, registered.first
    end
  end

  # End-to-end: boot a real Rails application with `require: false` semantics.
  # An initializer runs install! BEFORE the OTel SDK is configured — simulating
  # alphabetical ordering putting the gem's initializer before otel setup.
  # Then the OTel SDK gets "configured" during a later initializer. The app's
  # after_initialize phase must then register the processor on the real provider.
  def test_end_to_end_require_false_with_real_rails_boot
    require 'rails'
    require 'rails/application'
    require 'fileutils'
    require 'tmpdir'

    app_root = Dir.mktmpdir('rails_otel_ctx_e2e')
    FileUtils.mkdir_p(File.join(app_root, 'config'))

    registered = []
    proxy_provider = Object.new
    real_provider = Object.new
    real_provider.define_singleton_method(:add_span_processor) { |p| registered << p }

    # Start with the proxy; installer must NOT register against this.
    OpenTelemetry.define_singleton_method(:tracer_provider) { proxy_provider }

    app_class = Class.new(Rails::Application) do
      config.eager_load = false
      config.hosts.clear
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = 'x' * 64
    end
    app_class.config.root = app_root

    # Simulate the customer's initializer: runs during :load_config_initializers,
    # well before after_initialize hooks. SDK provider is still the proxy here.
    app_class.initializer('rails_otel_context.user_initializer',
                          after: :load_config_initializers) do
      RailsOtelContext.install_processor!
      # Immediately after, "OTel SDK" finishes configuring itself.
      OpenTelemetry.define_singleton_method(:tracer_provider) { real_provider }
    end

    app_class.instance.initialize!

    assert_equal 1, registered.size,
                 'CallContextProcessor must land on the real provider via after_initialize'
    assert_instance_of RailsOtelContext::CallContextProcessor, registered.first
  ensure
    FileUtils.remove_entry(app_root) if app_root && File.exist?(app_root)
  end

  def test_installs_immediately_when_sdk_already_configured
    registered = []
    real_provider = Object.new
    real_provider.define_singleton_method(:add_span_processor) { |p| registered << p }

    fake_app = Object.new
    fake_app.define_singleton_method(:initialized?) { true }

    with_rails_application(fake_app) do
      OpenTelemetry.define_singleton_method(:tracer_provider) { real_provider }

      RailsOtelContext.install_processor!

      assert_equal 1, registered.size, 'processor must be registered immediately'
    end
  end

  private

  def with_rails_application(app)
    original_application_method = Rails.method(:application)
    original_root_method        = Rails.method(:root)

    Rails.define_singleton_method(:application) { app }
    # Force Rails.root to a tmpdir regardless of the fake_app's config shape —
    # install_processor!'s guard calls Rails.root, which normally delegates
    # through Rails.application.config.root and would raise on our mocks.
    tmp_root = Pathname.new(Dir.tmpdir)
    Rails.define_singleton_method(:root) { tmp_root }

    yield
  ensure
    Rails.define_singleton_method(:application, original_application_method) if original_application_method
    Rails.define_singleton_method(:root, original_root_method) if original_root_method
  end
end
