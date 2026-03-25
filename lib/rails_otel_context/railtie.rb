# frozen_string_literal: true

require 'rails_otel_context/adapters'
require 'rails_otel_context/call_context_processor'

module RailsOtelContext
  class Railtie < Rails::Railtie
    initializer 'rails_otel_context.configure' do
      RailsOtelContext.apply_env_configuration!
    end

    initializer 'rails_otel_context.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: Rails.root, config: RailsOtelContext.configuration)
      end
    end

    # Runs after config/initializers/ so the OTel SDK tracer_provider is already configured.
    config.after_initialize do
      otel_config = RailsOtelContext.configuration
      needs_processor = otel_config.call_context_enabled ||
                        otel_config.custom_span_attributes ||
                        otel_config.request_context_enabled

      if needs_processor
        processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
        OpenTelemetry.tracer_provider.add_span_processor(processor)
      end
    end

    # Install request context capture on ActionController when it loads.
    # Uses around_action with ensure for leak-proof cleanup on exceptions.
    initializer 'rails_otel_context.install_request_context' do
      ActiveSupport.on_load(:action_controller) do
        if RailsOtelContext.configuration.request_context_enabled
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
    end
  end
end
