# frozen_string_literal: true

# config/initializers/rails_otel_context.rb
#
# Configuration example for rails-otel-context in a Rails application.
# This file should be placed in config/initializers/ directory.

RailsOtelContext.configure do |c|
  # ============================================================================
  # PostgreSQL Configuration
  # ============================================================================

  # Enable slow query tracking for PostgreSQL
  c.pg_slow_query_enabled = true

  # Set threshold for what's considered a "slow" query (in milliseconds)
  # Queries taking longer than this will get enriched with source location
  c.pg_slow_query_threshold_ms = 200.0

  # ============================================================================
  # MySQL Configuration
  # ============================================================================

  # Enable slow query tracking for MySQL2
  c.mysql2_slow_query_enabled = true

  # MySQL slow query threshold (in milliseconds)
  c.mysql2_slow_query_threshold_ms = 200.0

  # ============================================================================
  # Redis Configuration
  # ============================================================================

  # Redis source location tracking (disabled by default)
  # Enable this if you need to track where Redis calls originate
  # Warning: Can be noisy in high-throughput applications
  c.redis_source_enabled = false

  # ============================================================================
  # ClickHouse Configuration
  # ============================================================================

  # Enable ClickHouse instrumentation
  c.clickhouse_enabled = true

  # ClickHouse slow query threshold (in milliseconds)
  c.clickhouse_slow_query_threshold_ms = 200.0
end

# ============================================================================
# Environment-Specific Configuration Examples
# ============================================================================

# Example 1: Different thresholds per environment
if Rails.env.production?
  RailsOtelContext.configure do |c|
    # Stricter thresholds in production to catch real issues
    c.pg_slow_query_threshold_ms = 150.0
    c.mysql2_slow_query_threshold_ms = 150.0
    c.redis_source_enabled = false  # Too noisy in production
  end
elsif Rails.env.development?
  RailsOtelContext.configure do |c|
    # Lower thresholds in development to catch issues early
    c.pg_slow_query_threshold_ms = 50.0
    c.mysql2_slow_query_threshold_ms = 50.0
    c.redis_source_enabled = true  # Helpful for debugging
  end
elsif Rails.env.test?
  RailsOtelContext.configure do |c|
    # Disable in test to avoid test pollution
    c.pg_slow_query_enabled = false
    c.mysql2_slow_query_enabled = false
    c.redis_source_enabled = false
    c.clickhouse_enabled = false
  end
end

# Example 2: Using environment variables (recommended for container deployments)
# You can skip the Ruby configuration entirely and use ENV vars:
#
# RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED=true
# RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS=200.0
# RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_ENABLED=true
# RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS=200.0
# RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED=false
# RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED=true
# RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS=200.0
