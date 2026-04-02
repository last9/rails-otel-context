# frozen_string_literal: true

require 'rails_otel_context/adapters'
require 'rails_otel_context/call_context_processor'

module RailsOtelContext
  class Railtie < Rails::Railtie
    initializer 'rails_otel_context.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: Rails.root, config: RailsOtelContext.configuration)
        RailsOtelContext::ActiveRecordContext.install!(app_root: Rails.root)
      end
    end

    # Runs after config/initializers/ so the OTel SDK tracer_provider is already configured.
    config.after_initialize do
      RailsOtelContext.install_processor!

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
    #
    # Both hooks are required: ActionController::Base fires :action_controller,
    # ActionController::API (Rails API-only apps) fires :action_controller_api.
    # In Rails 8 API-only apps :action_controller never fires, so without the
    # second hook rails.controller / rails.action would be absent from every span.
    initializer 'rails_otel_context.install_request_context' do
      around_action_hook = proc do
        around_action do |_controller, block|
          RailsOtelContext::RequestContext.set(
            controller: self.class.name,
            action: action_name
          )
          block.call
        rescue StandardError => e
          RailsOtelContext::Railtie.record_exception_on_current_span(e)
          raise
        ensure
          RailsOtelContext::RequestContext.clear!
        end
      end
      ActiveSupport.on_load(:action_controller, &around_action_hook)
      ActiveSupport.on_load(:action_controller_api, &around_action_hook)
    end

    # Records an exception on the current OTel span using the standard
    # OTel event convention (exception.type, exception.message, exception.stacktrace).
    # Called from around_action rescue and around_perform rescue.
    def self.record_exception_on_current_span(exception)
      return unless defined?(OpenTelemetry::Trace)

      span = OpenTelemetry::Trace.current_span
      return unless span.context.valid?

      span.record_exception(exception)
      span.status = OpenTelemetry::Trace::Status.error(exception.message)
    rescue StandardError
      nil
    end

    # Capture job class name for every ActiveJob execution and propagate it to all
    # child spans via RequestContext so rails.job appears on every span in the job.
    initializer 'rails_otel_context.install_job_context' do
      ActiveSupport.on_load(:active_job) do
        around_perform do |_job, block|
          RailsOtelContext::RequestContext.set_job(job_class: self.class.name)
          block.call
        rescue StandardError => e
          RailsOtelContext::Railtie.record_exception_on_current_span(e)
          raise
        ensure
          RailsOtelContext::RequestContext.clear_job!
        end
      end
    end
  end
end
