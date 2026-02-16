# frozen_string_literal: true

# config/initializers/opentelemetry.rb
#
# Complete OpenTelemetry setup for Rails with otel-ruby-goodies

require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'opentelemetry/instrumentation/all'

OpenTelemetry::SDK.configure do |c|
  # Service name - identifies your application
  c.service_name = ENV.fetch('OTEL_SERVICE_NAME', 'my-rails-app')

  # Service version (optional but recommended)
  c.service_version = ENV.fetch('APP_VERSION', '1.0.0')

  # Configure OTLP exporter (sends traces to your observability backend)
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: ENV.fetch('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://localhost:4318/v1/traces'),
        headers: { 'Authorization' => ENV['OTEL_EXPORTER_OTLP_HEADERS'] }.compact
      )
    )
  )

  # Install all available instrumentations
  c.use_all(
    # Configure specific instrumentations if needed
    'OpenTelemetry::Instrumentation::PG' => {
      enable_sql_obfuscation: true,  # Hide sensitive SQL parameters
      peer_service: 'postgres'
    },
    'OpenTelemetry::Instrumentation::Redis' => {
      peer_service: 'redis'
    }
  )
end

# Configure otel-ruby-goodies (this happens automatically via Railtie)
# But you can customize it here if needed:
RailsOtelGoodies.configure do |c|
  c.pg_slow_query_threshold_ms = ENV.fetch('SLOW_QUERY_THRESHOLD_MS', 200.0).to_f
  c.mysql2_slow_query_threshold_ms = ENV.fetch('SLOW_QUERY_THRESHOLD_MS', 200.0).to_f
  c.clickhouse_slow_query_threshold_ms = ENV.fetch('SLOW_QUERY_THRESHOLD_MS', 200.0).to_f

  # Redis tracking is opt-in
  c.redis_source_enabled = ENV.fetch('RAILS_OTEL_GOODIES_REDIS_SOURCE_ENABLED', 'false') == 'true'
end

# Note: otel-ruby-goodies adapters are automatically installed via the Railtie
# when ActiveRecord loads. No manual installation needed!
