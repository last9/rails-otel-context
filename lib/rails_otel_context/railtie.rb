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
      if RailsOtelContext.configuration.call_context_enabled
        processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
        OpenTelemetry.tracer_provider.add_span_processor(processor)
      end
    end
  end
end
