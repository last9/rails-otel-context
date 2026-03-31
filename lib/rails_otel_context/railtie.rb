# frozen_string_literal: true

require 'rails_otel_context/adapters'
require 'rails_otel_context/call_context_processor'

module RailsOtelContext
  class Railtie < Rails::Railtie
    # Registers CallContextProcessor with the OTel tracer_provider.
    # Called automatically from after_initialize. Can also be called manually
    # from inside an OpenTelemetry::SDK.configure block (or after_initialize in
    # the user's app) when SDK setup runs after the Railtie's after_initialize.
    #
    # Safe to call multiple times — idempotent via @processor_installed.
    def self.install_processor!
      return if @processor_installed
      return unless OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)

      @processor_installed = true
      processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
      OpenTelemetry.tracer_provider.add_span_processor(processor)
    end
    initializer 'rails_otel_context.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: Rails.root, config: RailsOtelContext.configuration)
        RailsOtelContext::ActiveRecordContext.install!(app_root: Rails.root)
      end
    end

    # Runs after config/initializers/ so the OTel SDK tracer_provider is already configured.
    config.after_initialize do
      RailsOtelContext::Railtie.install_processor!

      # Warm the table→model map once at boot (after eager_load! in production so
      # all descendants are available). Without this, the first SQL-named span on a
      # cold boot hits an empty map and falls through without model context.
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::ActiveRecordContext.ar_table_model_map
      end
    end

    # Reset the table→model map after every code reload in development.
    # In development, classes are lazy-loaded so the map built on first access
    # may be empty or stale. to_prepare runs after each reload when all currently
    # referenced models are loaded, guaranteeing a fresh index.
    config.to_prepare do
      RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
    end

    # Capture controller + action for every request and propagate them to all
    # child spans via RequestContext. Also resets the N+1 query counter at both
    # the start and end of every request to prevent bleed across Puma thread reuse.
    # Always-on — no config gate.
    initializer 'rails_otel_context.install_request_context' do
      ActiveSupport.on_load(:action_controller) do
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
    end

    # Capture job class name for every ActiveJob execution and propagate it to all
    # child spans via RequestContext so rails.job appears on every span in the job.
    initializer 'rails_otel_context.install_job_context' do
      ActiveSupport.on_load(:active_job) do
        around_perform do |_job, block|
          RailsOtelContext::RequestContext.set_job(job_class: self.class.name)
          block.call
        ensure
          RailsOtelContext::RequestContext.clear_job!
        end
      end
    end
  end
end
