# frozen_string_literal: true

require 'rails_otel_context/adapters'
require 'rails_otel_context/call_context_processor'

module RailsOtelContext
  class Railtie < Rails::Railtie
    # Runs after config/initializers/ so the OTel SDK tracer_provider is already
    # configured. install! is idempotent — if the app already called
    # RailsOtelContext.install! from an initializer this is a no-op for hooks,
    # but install_processor! still runs (it self-guards with @processor_installed).
    config.after_initialize do
      RailsOtelContext.install!
    end

    # Reset the table→model map after every code reload in development.
    # In development, classes are lazy-loaded so the map built on first access
    # may be empty or stale. to_prepare runs after each reload when all currently
    # referenced models are loaded, guaranteeing a fresh index.
    config.to_prepare do
      RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
    end
  end
end
