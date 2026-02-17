# rails-otel-context

[![CI](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml/badge.svg)](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/rails-otel-context.svg)](https://badge.fury.io/rb/rails-otel-context)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-ruby.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-red.svg)](https://rubyonrails.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Production-ready OpenTelemetry enhancements for Ruby on Rails applications, maintained by Last9.

## Overview

`rails-otel-context` extends the default Ruby OpenTelemetry SDK with production-grade observability features specifically designed for Rails applications. While the standard OpenTelemetry instrumentations provide basic database and cache operation tracing, they lack critical debugging context that Rails developers need when investigating slow queries and performance issues in production.

This gem adds intelligent span enrichment that captures **exactly where in your Rails application code** slow operations are called—down to the specific controller, model, or service method and line number—making it trivial to jump from a trace in your observability platform directly to the problematic code.

**⚠️ Rails-Only:** This gem is designed specifically for Rails applications (>= 7.0) and requires Rails to function.

## Key Improvements Over Default Ruby OpenTelemetry SDK

### 1. **Source Code Location Tracking**
The default OpenTelemetry instrumentations tell you *what* query was slow, but not *where* in your application it was called from. This gem adds:
- `code.filepath` - The relative path to your application file
- `code.lineno` - The exact line number where the call originated
- `code.activerecord.model` - The ActiveRecord model name (e.g., "User", "Product")
- `code.activerecord.method` - The method that triggered the query (e.g., "find", "create")

**Why this matters:** When investigating a slow query in production, you can immediately identify not just the file and line, but also the specific ActiveRecord model and method responsible—no grepping through your codebase required.

### 2. **Selective Slow Query Enrichment**
Instead of adding attributes to every single database span (which can increase trace size and costs), this gem intelligently adds context *only* for operations exceeding your configured thresholds:
- `db.query.duration_ms` - Precise query duration
- `db.query.slow_threshold_ms` - The threshold that triggered enrichment

**Why this matters:** Keeps your traces lean while ensuring slow queries have full debugging context. Fast queries (which are working fine) don't carry unnecessary metadata.

### 3. **ClickHouse Instrumentation**
The official OpenTelemetry Ruby ecosystem lacks native ClickHouse instrumentation. This gem provides:
- Automatic client span creation for query operations
- Full support for popular ClickHouse client gems (`click_house`, `clickhouse` variants)
- Semantic conventions following OpenTelemetry database patterns
- Optional slow query detection with source tracking

**Why this matters:** ClickHouse is increasingly popular for analytical workloads, but without instrumentation, these operations are invisible in your traces—creating blind spots in your observability.

### 4. **Smart Application Code Filtering**
All adapters intelligently filter stack traces to show only your application code:
- Automatically excludes gem/library internal calls
- Strips app root prefix for cleaner paths
- Uses `Thread.each_caller_location` for accurate, low-overhead location tracking

**Why this matters:** You see `app/models/checkout.rb:88` instead of deeply nested gem internals that don't help with debugging.

### 5. **Zero-Config Rails Integration**
Automatic setup via Railtie—just add the gem:
- Adapters install automatically when ActiveRecord loads
- Environment variable configuration support
- No manual initialization code required
- Integrates seamlessly with Rails boot process

## Included Adapters

### PostgreSQL (`pg`)
**Status:** ✅ Implemented

Enhances the official `opentelemetry-instrumentation-pg` gem:
- Patches all `exec`-family methods (`exec`, `exec_params`, `exec_prepared`, etc.)
- Adds source location attributes only for queries exceeding the threshold
- Works with streaming queries and async execution
- Captures both query duration and threshold for context

**Added Attributes:**
- `code.filepath` - Application file path (relative to Rails.root)
- `code.lineno` - Line number where query originated
- `code.activerecord.model` - ActiveRecord model name (e.g., "User")
- `code.activerecord.method` - Method that triggered the query (e.g., "find")
- `db.query.duration_ms` - Query execution time in milliseconds
- `db.query.slow_threshold_ms` - Configured threshold value

### MySQL (`mysql2`)
**Status:** ✅ Implemented

Enhances MySQL2 client instrumentation:
- Patches `query` and `prepare` methods
- Validates span context before setting attributes (defensive coding)
- Same intelligent slow query detection as PG adapter
- Full async query support

**Added Attributes:**
- `code.filepath` - Application file path
- `code.lineno` - Line number where query originated
- `code.activerecord.model` - ActiveRecord model name (e.g., "Product")
- `code.activerecord.method` - Method that triggered the query (e.g., "where")
- `db.query.duration_ms` - Query execution time
- `db.query.slow_threshold_ms` - Configured threshold value

### Redis (`redis`)
**Status:** ✅ Implemented (opt-in)

Enhances the official `opentelemetry-instrumentation-redis` gem:
- Patches `RedisClient::Middlewares` for both single and pipelined commands
- Uses official instrumentation's `with_attributes` API for proper attribute injection
- Disabled by default (can be noisy for high-throughput Redis usage)
- Works with both standalone commands and pipelined operations

**Added Attributes:**
- `code.filepath` - Application file path
- `code.lineno` - Line number where Redis call originated

**Note:** Unlike database adapters, Redis tracking doesn't use slow query thresholds—it's all-or-nothing to avoid complexity with pipelined operations.

### ClickHouse (`clickhouse`)
**Status:** ✅ Implemented

Creates full OpenTelemetry instrumentation for ClickHouse clients (no official instrumentation exists):
- Supports multiple client gem variants (`ClickHouse::Client`, `Clickhouse::Client`, `ClickHouse::Connection`)
- Creates client spans with semantic conventions (`db.system`, `db.operation`, `db.statement`)
- Patches common methods: `query`, `select`, `insert`, `execute`, `command`
- Includes slow query detection with source tracking
- Thread-local reentrancy guard to prevent double-instrumentation

**Span Attributes:**
- `db.system` - Always set to `"clickhouse"`
- `db.operation` - Operation type (QUERY, SELECT, INSERT, etc.)
- `db.statement` - The SQL statement (when available)
- `code.filepath` - Source location (for slow queries)
- `code.lineno` - Line number (for slow queries)
- `db.query.duration_ms` - Duration (for slow queries)
- `db.query.slow_threshold_ms` - Threshold (for slow queries)

## Installation

Add to your Rails Gemfile:

```ruby
gem 'rails-otel-context'
```

Or for local development/testing:

```ruby
gem 'rails-otel-context', path: 'path/to/rails-otel-context'
```

Then run:

```bash
bundle install
```

### Automatic Rails Integration

The gem automatically integrates via a Railtie—**no manual initialization needed!**

- Adapters install automatically when ActiveRecord loads
- Environment variables are read and applied during Rails initialization
- Works with standard Rails boot process (no special setup required)

Just add the gem and configure OpenTelemetry as usual. `rails-otel-context` will enhance your traces automatically.

## Usage

### Basic Configuration

The gem works out-of-the-box with sensible defaults (200ms slow query threshold). To customize:

```ruby
# config/initializers/rails_otel_context.rb (Rails)
RailsOtelContext.configure do |c|
  # PostgreSQL slow query tracking
  c.pg_slow_query_enabled = true
  c.pg_slow_query_threshold_ms = 200.0

  # MySQL slow query tracking
  c.mysql2_slow_query_enabled = true
  c.mysql2_slow_query_threshold_ms = 200.0

  # Redis source tracking (opt-in, can be noisy)
  c.redis_source_enabled = false

  # ClickHouse instrumentation and slow query tracking
  c.clickhouse_enabled = true
  c.clickhouse_slow_query_threshold_ms = 200.0
end
```

### Custom Span Names with ActiveRecord Context

By default, database spans are named by the underlying instrumentation (e.g., "SELECT postgres.users"). You can customize span names using ActiveRecord context to make traces more readable:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  # Simple formatter: "User.find" instead of "SELECT postgres.users"
  c.span_name_formatter = lambda do |original_name, ar_context|
    model = ar_context[:model_name]
    method = ar_context[:method_name]

    if model && method
      "#{model}.#{method}"
    else
      original_name # fallback to original if no AR context
    end
  end
end
```

**Benefits:**
- **Clearer traces**: See "User.find" instead of generic "SELECT postgres.users"
- **Better grouping**: Group spans by model and method in APM tools
- **Faster debugging**: Immediately understand what operation caused the query

**Advanced example with operation types:**

```ruby
c.span_name_formatter = lambda do |original_name, ar_context|
  model = ar_context[:model_name]
  method = ar_context[:method_name]

  if model && method
    operation = case method
                when /find/, /where/, /select/ then 'SELECT'
                when /create/, /insert/ then 'INSERT'
                when /update/, /save/ then 'UPDATE'
                when /delete/, /destroy/ then 'DELETE'
                else 'QUERY'
                end
    "#{operation} #{model}.#{method}"
  else
    original_name
  end
end
```

**Important notes:**
- The formatter is called only when ActiveRecord context is available
- Errors in the formatter are caught and logged—they won't break your application
- The formatter applies to all adapters (PostgreSQL, MySQL, ClickHouse)
- Redis spans are not renamed (no ActiveRecord context for cache operations)

See [`examples/rails/span_name_formatter_example.rb`](examples/rails/span_name_formatter_example.rb) for more examples.

### Environment Variable Configuration

All settings can be controlled via environment variables—ideal for container deployments:

```bash
# PostgreSQL
export RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED=true
export RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS=200.0

# Legacy fallback (still supported)
export OTEL_SLOW_QUERY_MS=200.0

# MySQL
export RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_ENABLED=true
export RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS=200.0

# Redis
export RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED=false

# ClickHouse
export RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED=true
export RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS=200.0
```

**Supported boolean values:** `1`, `true`, `yes`, `on` (case-insensitive) → `true` | `0`, `false`, `no`, `off` → `false`

### Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_ENABLED` | `true` | Enable/disable PG slow query enrichment |
| `RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS` | `200.0` | PG slow query threshold in milliseconds |
| `OTEL_SLOW_QUERY_MS` | `200.0` | Legacy fallback for PG threshold |
| `RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_ENABLED` | `true` | Enable/disable MySQL2 slow query enrichment |
| `RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS` | `200.0` | MySQL2 slow query threshold in milliseconds |
| `RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED` | `false` | Enable/disable Redis source location tracking |
| `RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED` | `true` | Enable/disable ClickHouse instrumentation |
| `RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS` | `200.0` | ClickHouse slow query threshold in milliseconds |

## Configuration Best Practices

### Choosing Slow Query Thresholds

The default 200ms threshold works well for most applications, but consider your specific SLOs:

- **API services:** 100-200ms (user-facing requests need tight budgets)
- **Background jobs:** 500-1000ms (more tolerance for slower operations)
- **Analytical workloads:** 1000-5000ms (complex queries are expected)

**Pro tip:** Set thresholds at **50-75% of your SLO target**. If your p99 target is 400ms, use a 200-300ms threshold to catch queries that are consuming most of your budget.

### Redis Source Tracking

Redis source tracking is **disabled by default** because:
- High-throughput applications make thousands of Redis calls per second
- Most Redis operations are fast (<1ms), so tracking isn't as valuable
- The overhead and span size increase may not justify the benefit

**Enable it when:**
- Debugging cache key patterns or cache penetration issues
- Your application has moderate Redis usage (<1000 ops/sec)
- You're investigating Redis hot spots and need to identify calling code

### Per-Environment Configuration

Different environments have different performance characteristics:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  if Rails.env.production?
    # Tighter thresholds in production
    c.pg_slow_query_threshold_ms = 150.0
    c.mysql2_slow_query_threshold_ms = 150.0
    c.redis_source_enabled = false  # Too noisy in prod
  elsif Rails.env.development?
    # Lower thresholds to catch issues early
    c.pg_slow_query_threshold_ms = 50.0
    c.mysql2_slow_query_threshold_ms = 50.0
    c.redis_source_enabled = true   # Helpful for debugging
  end
end
```

## Rails Usage Examples

### Example 1: Complete Rails Setup

```ruby
# Gemfile
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp'
gem 'opentelemetry-instrumentation-rails'
gem 'opentelemetry-instrumentation-pg'
gem 'opentelemetry-instrumentation-redis'
gem 'rails-otel-context'  # 👈 Add this for enhanced tracing
```

```ruby
# config/initializers/opentelemetry.rb
require 'opentelemetry/sdk'
require 'opentelemetry/instrumentation/all'

OpenTelemetry::SDK.configure do |c|
  c.service_name = 'my-rails-app'
  c.service_version = ENV['APP_VERSION']
  c.use_all  # Install all available instrumentations
end
```

```ruby
# config/initializers/rails_otel_context.rb (optional - for custom config)
RailsOtelContext.configure do |c|
  c.pg_slow_query_threshold_ms = 150.0
  c.redis_source_enabled = Rails.env.development?
end
```

That's it! No manual adapter installation needed—Rails handles everything via the Railtie.

### Example 2: Environment-Based Configuration

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  if Rails.env.production?
    # Strict thresholds in production
    c.pg_slow_query_threshold_ms = 150.0
    c.mysql2_slow_query_threshold_ms = 150.0
    c.redis_source_enabled = false  # Too noisy
  elsif Rails.env.development?
    # Catch issues early in dev
    c.pg_slow_query_threshold_ms = 50.0
    c.mysql2_slow_query_threshold_ms = 50.0
    c.redis_source_enabled = true
  elsif Rails.env.test?
    # Disable in test environment
    c.pg_slow_query_enabled = false
    c.mysql2_slow_query_enabled = false
  end
end
```

### Example 3: Docker/Kubernetes Configuration

Instead of Ruby configuration, use environment variables in your container:

```yaml
# docker-compose.yml or Kubernetes manifest
environment:
  # OpenTelemetry base config
  OTEL_SERVICE_NAME: my-rails-app
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318

  # rails-otel-context config
  RAILS_OTEL_CONTEXT_PG_SLOW_QUERY_MS: "150"
  RAILS_OTEL_CONTEXT_MYSQL2_SLOW_QUERY_MS: "150"
  RAILS_OTEL_CONTEXT_REDIS_SOURCE_ENABLED: "false"
  RAILS_OTEL_CONTEXT_CLICKHOUSE_ENABLED: "true"
  RAILS_OTEL_CONTEXT_CLICKHOUSE_SLOW_QUERY_MS: "200"
```

No code changes needed—the gem reads these automatically!

### Example 4: What You'll See in Production

**Scenario:** A user reports slow page loads on `/products` page.

**Without rails-otel-context:**
```json
{
  "span": "SELECT products",
  "db.statement": "SELECT * FROM products WHERE active = true",
  "duration_ms": 450
}
```
You know there's a slow query, but where is it called from? Time to grep the codebase... 😞

**With rails-otel-context:**
```json
{
  "span": "SELECT products",
  "db.statement": "SELECT * FROM products WHERE active = true",
  "duration_ms": 450,
  "code.filepath": "app/controllers/products_controller.rb",
  "code.lineno": 23,
  "code.activerecord.model": "Product",
  "code.activerecord.method": "where",
  "db.query.duration_ms": 447.3,
  "db.query.slow_threshold_ms": 200.0
}
```
Navigate directly to `app/controllers/products_controller.rb:23` and see it's `Product.where`—found the issue! 🎉

## How It Works

### Source Location Tracking

The gem uses Ruby's `Thread.each_caller_location` API (introduced in Ruby 3.1) to walk the call stack efficiently:

```ruby
Thread.each_caller_location do |location|
  path = location.absolute_path || location.path
  # Skip if not in Rails app code
  next unless path&.start_with?(Rails.root.to_s)
  # Skip gem internals
  next if path.include?('/gems/')

  return [path.delete_prefix("#{Rails.root}/"), location.lineno]
end
```

This approach:
- ✅ Is more performant than `caller_locations` (no array allocation)
- ✅ Stops early when application code is found
- ✅ Filters out gem internals automatically
- ✅ Returns relative paths for cleaner output

### Monkey-Patching Strategy

The gem uses Ruby's `prepend` mechanism to intercept method calls without breaking the original implementation:

```ruby
module MyPatch
  def query(*args)
    # Capture source location and timing
    result = super(*args)  # Call original method
    # Add span attributes if slow
    result
  end
end

Mysql2::Client.prepend(MyPatch)
```

**Why prepend?**
- Cleaner than `alias_method` chains
- Plays nicely with other gems that may also patch the same methods
- Easy to detect and skip if already applied
- Supports method signature changes across gem versions

### Span Attribute Timing

For PostgreSQL and MySQL, attributes are added **after** the query completes:
1. Query starts → capture stack trace and start time
2. Query executes → (original instrumentation creates span)
3. Query completes → calculate duration
4. If slow → add attributes to the current span

For ClickHouse, we create the span ourselves:
1. Start span with operation name
2. Execute query
3. Add attributes based on duration threshold

## Example Output

### Slow PostgreSQL Query in Your Observability Platform

Without `rails-otel-context`:
```json
{
  "name": "SELECT products",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM products WHERE category = $1",
  "duration_ms": 450
}
```

With `rails-otel-context`:
```json
{
  "name": "SELECT products",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM products WHERE category = $1",
  "duration_ms": 450,
  "code.filepath": "app/controllers/products_controller.rb",
  "code.lineno": 23,
  "db.query.duration_ms": 447.3,
  "db.query.slow_threshold_ms": 200.0
}
```

**The difference:** You can immediately navigate to `app/controllers/products_controller.rb:23` and see exactly which code path triggered the slow query—no guessing, no grepping.

### ClickHouse Query Trace

```json
{
  "name": "SELECT clickhouse",
  "db.system": "clickhouse",
  "db.operation": "SELECT",
  "db.statement": "SELECT user_id, count(*) FROM events WHERE timestamp > ?",
  "duration_ms": 1250,
  "code.filepath": "app/services/analytics_service.rb",
  "code.lineno": 67,
  "db.query.duration_ms": 1247.8,
  "db.query.slow_threshold_ms": 200.0
}
```

## Troubleshooting

### Attributes Not Appearing

**Problem:** Slow queries aren't getting enriched with source location attributes.

**Solutions:**

1. **Check your Ruby version:**
   ```bash
   ruby -v  # Must be >= 3.1.0
   ```
   The gem requires Ruby 3.1+ for `Thread.each_caller_location` support.

2. **Verify adapters are installed:**
   ```ruby
   # In Rails console
   PG::Connection.ancestors.any? { |m| m.to_s.include?('RailsOtelContext') }
   # => Should return true
   ```

3. **Check threshold configuration:**
   ```ruby
   RailsOtelContext.configuration.pg_slow_query_threshold_ms
   # Make sure it's lower than your query duration
   ```

4. **Ensure queries originate from Rails app code:**
   - Only calls from files under `Rails.root` are tracked
   - Gem internal calls are intentionally excluded

### ClickHouse Spans Not Created

**Problem:** ClickHouse operations aren't creating spans.

**Solutions:**

1. **Verify ClickHouse client is loaded:**
   ```ruby
   defined?(ClickHouse::Client)  # or Clickhouse::Client
   # => Should return "constant"
   ```

2. **Check if enabled:**
   ```ruby
   RailsOtelContext.configuration.clickhouse_enabled
   # => Should be true
   ```

3. **Ensure tracer provider is configured:**
   ```ruby
   OpenTelemetry.tracer_provider.tracer('test').in_span('test') { |span| puts span.class }
   # Should output a span class, not a no-op span
   ```

### High Cardinality Concerns

**Problem:** Worried about attribute cardinality with `code.filepath` and `code.lineno`.

**Answer:** This is generally safe because:
- Attributes are added to individual spans, not as metrics dimensions
- Source locations have bounded cardinality (limited by your codebase size)
- Only slow queries get enriched (a small fraction of total queries)
- File paths are relative to app root (no customer/tenant-specific data)

**If storage is a concern:**
- Increase slow query thresholds to reduce the number of enriched spans
- Use tail-based sampling to keep only traces with slow queries
- Disable specific adapters (e.g., Redis) that may be high-volume

### Performance Impact

**Q: What's the overhead?**

**A:** Minimal in production:
- `Thread.each_caller_location` is optimized for early termination
- Stack walking only happens during database calls (already I/O-bound)
- Attributes are only added for slow queries (fast queries have zero overhead)
- Module prepending has negligible cost (single method dispatch indirection)

**Benchmarks:** In typical Rails applications, the overhead is <0.1ms per database call—imperceptible compared to actual query execution time.

## Compatibility

### Ruby Versions
- **Required:** Ruby >= 3.1.0 (for `Thread.each_caller_location`)

### Rails Versions
- **Required:** Rails >= 7.0
- **Recommended:** Rails 7.1+ for best compatibility
- **Note:** This gem is Rails-only and will not work in standalone Ruby applications

### Database Gems
- `pg` - All versions with `PG::Constants::EXEC_ISH_METHODS`
- `mysql2` - All versions with `query` and `prepare` methods
- `redis-client` with `opentelemetry-instrumentation-redis`
- `click_house`, `clickhouse` - Multiple client variants supported

### OpenTelemetry
- `opentelemetry-api` >= 1.0
- `opentelemetry-sdk` (required for tracing)
- `opentelemetry-instrumentation-pg` (optional, but recommended for PG)
- `opentelemetry-instrumentation-mysql2` (optional, but recommended for MySQL)
- `opentelemetry-instrumentation-redis` (required for Redis adapter)

## Roadmap

Potential future enhancements:

- [ ] **More database adapters:** SQLite, Oracle, SQL Server
- [ ] **HTTP client enrichment:** Add source locations to HTTP spans
- [ ] **Sampling controls:** Per-adapter sampling rates
- [ ] **Query parameter capture:** Optionally capture bind parameters
- [ ] **Async query support:** Better handling for async database operations
- [ ] **Custom attribute callbacks:** User-defined attributes based on query patterns

## Contributing

We welcome contributions! Areas of interest:

1. **New adapters** for popular Ruby database/cache clients
2. **Test coverage** improvements
3. **Performance optimizations**
4. **Documentation** enhancements

## License

MIT License - See [LICENSE](LICENSE) for details.

## Maintainers

Maintained with ❤️ by the observability team at [Last9](https://last9.io).

## Support

- 🐛 **Issues:** [GitHub Issues](https://github.com/last9/rails-otel-context/issues)
- 💬 **Discussions:** [GitHub Discussions](https://github.com/last9/rails-otel-context/discussions)
- 📧 **Email:** engineering@last9.io
