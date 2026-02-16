# frozen_string_literal: true

# Add these gems to your Gemfile for a complete OpenTelemetry setup with otel-ruby-goodies

# Core OpenTelemetry gems
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp'

# OpenTelemetry instrumentations (install what you use)
gem 'opentelemetry-instrumentation-rails'
gem 'opentelemetry-instrumentation-pg'
gem 'opentelemetry-instrumentation-mysql2'
gem 'opentelemetry-instrumentation-redis'
gem 'opentelemetry-instrumentation-net_http'
gem 'opentelemetry-instrumentation-sidekiq'

# otel-ruby-goodies - Adds source location tracking and ClickHouse support
gem 'rails-otel-goodies'

# ClickHouse client (if using ClickHouse)
gem 'click_house', require: false  # or gem 'clickhouse'
