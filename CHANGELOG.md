# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of rails-otel-context gem
- Source code location tracking for database queries
- ActiveRecord model and method context extraction
- PostgreSQL adapter enhancements (pg gem)
- MySQL2 adapter enhancements
- Redis source location tracking (opt-in)
- ClickHouse instrumentation (creates spans where none exist)
- Configurable slow query thresholds per adapter
- Environment variable configuration support
- Zero-config Rails integration via Railtie
- Comprehensive documentation with examples
- Full test suite with 20 tests

### Features

#### Source Location Tracking
- Captures exact file path and line number where slow queries originate
- Filters to show only application code (excludes gem internals)
- Relative paths from Rails.root for cleaner output

#### ActiveRecord Context
- Extracts ActiveRecord model name from call stack
- Identifies method name that triggered the query
- Helps pinpoint exact AR calls causing slow queries

#### Span Attributes
- `code.filepath` - Application file path (relative to Rails.root)
- `code.lineno` - Line number where query originated
- `code.activerecord.model` - ActiveRecord model name (e.g., "User")
- `code.activerecord.method` - Method that triggered query (e.g., "find")
- `db.query.duration_ms` - Precise query duration in milliseconds
- `db.query.slow_threshold_ms` - Configured threshold value

#### Adapters

**PostgreSQL (pg)**
- Enhances official `opentelemetry-instrumentation-pg`
- Patches all exec-family methods
- Default threshold: 200ms

**MySQL2**
- Patches `query` and `prepare` methods
- Validates span context before setting attributes
- Default threshold: 200ms

**Redis**
- Patches `RedisClient::Middlewares`
- Supports both single and pipelined commands
- Disabled by default (opt-in via configuration)

**ClickHouse**
- Creates spans where no official instrumentation exists
- Supports multiple client gem variants
- Patches: query, select, insert, execute, command
- Default threshold: 200ms

### Configuration

#### Environment Variables
- `RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED` (default: true)
- `RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS` (default: 200.0)
- `RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_ENABLED` (default: true)
- `RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS` (default: 200.0)
- `RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED` (default: false)
- `RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED` (default: true)
- `RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS` (default: 200.0)

#### Ruby Configuration API
```ruby
RailsOtelContext.configure do |c|
  c.pg_slow_query_enabled = true
  c.pg_slow_query_threshold_ms = 200.0
  # ... etc
end
```

### Requirements
- Ruby >= 3.1.0 (for `Thread.each_caller_location`)
- Rails >= 7.0
- OpenTelemetry SDK and instrumentations

### Dependencies
- `opentelemetry-api` >= 1.0
- `railties` >= 7.0
- `activerecord` >= 7.0

## [0.1.0] - TBD

Initial release (unreleased)
