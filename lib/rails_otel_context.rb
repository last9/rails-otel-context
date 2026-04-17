# frozen_string_literal: true

# rails-otel-context is a Rails-specific gem
# Skip Rails check in test environment to allow unit testing
unless defined?(Rails) || ENV['RAILS_OTEL_CONTEXT_TEST']
  raise LoadError, 'rails-otel-context requires Rails. This gem is designed for Rails applications only.'
end

require 'rails_otel_context/version'
require 'rails_otel_context/configuration'
require 'rails_otel_context/source_location'
require 'rails_otel_context/activerecord_context'
require 'rails_otel_context/adapters'
require 'rails_otel_context/request_context'
require 'rails_otel_context/frame_context'
require 'rails_otel_context/call_context_processor'
require 'rails_otel_context/body_capture'
require 'rails_otel_context/railtie' if defined?(Rails::Railtie)

module RailsOtelContext
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # Full installation: registers all Rails hooks (AR adapters, around_action,
    # around_perform) and the CallContextProcessor. Safe to call from a
    # config/initializers file when the gem is loaded with require: false:
    #
    #   # config/initializers/opentelemetry.rb
    #   return unless ENV['ENABLE_OTLP']
    #   require 'rails_otel_context'
    #   RailsOtelContext.configure { |c| ... }
    #   RailsOtelContext.install!
    #
    # The Railtie calls this automatically via after_initialize, so apps that
    # let Bundler auto-require the gem do not need to call it explicitly.
    # Safe to call multiple times — idempotent.
    def install!(app_root: nil)
      app_root ||= Rails.root if defined?(Rails)
      register_hooks!(app_root) unless @hooks_installed
      install_processor!
    end

    # Registers CallContextProcessor with the OTel tracer_provider.
    # Called automatically by install!. Safe to call multiple times — idempotent.
    #
    # When the app is still booting (Rails.application not yet initialized), the
    # actual registration is deferred to config.after_initialize so it runs after
    # all config/initializers — including the OTel SDK setup — have completed.
    # This keeps `require: false` + manual install-in-initializer working even
    # when the OTel SDK initializer sorts after the gem's initializer.
    def install_processor!
      return if @processor_installed
      return unless defined?(Rails) && Rails.root

      if defined?(Rails.application) && Rails.application && !Rails.application.initialized?
        Rails.application.config.after_initialize { do_install_processor! }
      else
        do_install_processor!
      end
    end

    def do_install_processor!
      return if @processor_installed
      return unless OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)

      @processor_installed = true
      processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
      OpenTelemetry.tracer_provider.add_span_processor(processor)
    end

    private

    def register_hooks!(app_root)
      @hooks_installed = true

      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: app_root, config: RailsOtelContext.configuration)
        RailsOtelContext::ActiveRecordContext.install!(app_root: app_root)
        RailsOtelContext::ActiveRecordContext.ar_table_model_map
      end

      around_action_hook = proc do
        around_action do |_controller, block|
          RailsOtelContext::RequestContext.set(
            controller: self.class.name,
            action: action_name
          )
          block.call
        ensure
          RailsOtelContext::RequestContext.clear!
        end
      end
      ActiveSupport.on_load(:action_controller, &around_action_hook)
      ActiveSupport.on_load(:action_controller_api, &around_action_hook)

      ActiveSupport.on_load(:active_job) do
        around_perform do |_job, block|
          RailsOtelContext::RequestContext.set_job(job_class: self.class.name)
          block.call
        ensure
          RailsOtelContext::RequestContext.clear_job!
        end
      end
    end

    public

    # Convenience delegates to FrameContext — see FrameContext for full docs.
    def with_frame(class_name:, method_name:, &block)
      FrameContext.with_frame(class_name: class_name, method_name: method_name, &block)
    end

    def push_frame(class_name:, method_name:)
      FrameContext.push(class_name: class_name, method_name: method_name)
    end

    def pop_frame
      FrameContext.pop
    end
  end
end
