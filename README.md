# rails-otel-context

[![CI](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml/badge.svg)](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/rails-otel-context)](https://rubygems.org/gems/rails-otel-context)

OpenTelemetry spans for Rails know a lot about your database. They know the SQL. They know how long it took. What they don't know is *which code fired that query* — the service object, the scope, the job, the line number. This gem fixes that.

## Before and after

Without this gem, a database span looks like:

```json
{
  "name": "SELECT",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM transactions WHERE ...",
  "duration_ms": 450
}
```

With this gem:

```json
{
  "name": "Transaction.recent_completed",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM transactions WHERE ...",
  "duration_ms": 450,
  "code.activerecord.model":  "Transaction",
  "code.activerecord.method": "Load",
  "code.activerecord.scope":  "recent_completed",
  "code.namespace":           "BillingService",
  "code.function":            "monthly_summary",
  "code.filepath":            "app/services/billing_service.rb",
  "code.lineno":              42,
  "rails.controller":         "ReportsController",
  "rails.action":             "index",
  "db.query_count":           3
}
```

Notice `code.namespace` is `BillingService`, not `ReportsController` — the gem walks the call stack and finds the service object that actually issued the query, not the controller that dispatched the request. No configuration required.

## Installation

```ruby
gem 'rails-otel-context', '~> 0.9'
```

Add the gem, boot Rails. Everything else happens automatically.

## What gets added to your spans

Every span — DB, Redis, HTTP outbound, custom — gets:

| Attribute | Example | Where it comes from |
|---|---|---|
| `code.namespace` | `"BillingService"` | Nearest app-code class in the call stack |
| `code.function` | `"monthly_summary"` | Method within that class |
| `code.filepath` | `"app/services/billing_service.rb"` | App-relative path |
| `code.lineno` | `42` | Source line number |
| `rails.controller` | `"ReportsController"` | Current Rails controller (set for every request) |
| `rails.action` | `"index"` | Current Rails action |
| `rails.job` | `"MonthlyInvoiceJob"` | ActiveJob class (set for every job, mutually exclusive with `rails.controller`) |

DB spans additionally get:

| Attribute | Example | Description |
|---|---|---|
| `code.activerecord.model` | `"Transaction"` | ActiveRecord model |
| `code.activerecord.method` | `"Load"` | AR operation (Load, Count, Update…) |
| `code.activerecord.scope` | `"recent_completed"` | Named scope or class method |
| `db.query_count` | `3` | Occurrence count this request — 2nd+ flags N+1 patterns |
| `db.slow` | `true` | Set when duration ≥ `slow_query_threshold_ms` |
| `db.async` | `true` | Set when issued via `load_async` (Rails 7.1+) |

## Configuration

Zero configuration gets you everything above. The optional initializer adds span naming, slow-query detection, and opts into the heavier adapters:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  # Rename DB spans: prefer scope name, then calling method, then AR operation
  #
  # Priority (highest to lowest):
  #   1. scope_name   — named scope or class method returning a Relation
  #                     e.g. User.active, Transaction.recent_completed
  #   2. code_function when code_namespace == model — the model's own class method
  #                     e.g. Transaction.total_revenue, User.for_account
  #   3. method_name  — AR operation: Load, Count, Update, Destroy…
  #                     e.g. Transaction.Load, Transaction.Update
  c.span_name_formatter = lambda { |original, ar|
    model = ar[:model_name]
    return original unless model

    scope   = ar[:scope_name]
    code_fn = ar[:code_function]
    code_ns = ar[:code_namespace]
    ar_op   = ar[:method_name]

    method = if scope
               scope
             elsif code_fn && code_ns == model && !code_fn.start_with?('<')
               code_fn
             else
               ar_op
             end

    "#{model}.#{method}"
  }

  # Flag slow queries
  c.slow_query_threshold_ms = 500

  # Attach any per-request context to every span
  c.custom_span_attributes = -> { { 'tenant' => Current.tenant } if Current.tenant }

  # Opt-in adapters — disabled by default because they patch third-party classes
  # and add a span per call. Turn on what you actually use.
  c.clickhouse_enabled             = true  # instrument click_house gem queries
  c.connection_pool_tracing_enabled = true  # span per AR connection checkout
end
```

## Conditional loading (`require: false`)

If your Gemfile has `require: false` and you load the gem from an initializer, call `RailsOtelContext.install!` explicitly. Loading the gem inside `config/initializers/` is too late for Rails to run the railtie's initializer hooks, so without an explicit `install!` call the AR subscriber and `around_action` hooks are never registered — `code.activerecord.*` and `rails.controller` will be absent from all spans.

```ruby
# Gemfile
gem 'rails-otel-context', '~> 0.9', require: false

# config/initializers/opentelemetry.rb
return unless ENV['ENABLE_OTLP']

require 'rails_otel_context'

RailsOtelContext.configure do |c|
  c.span_name_formatter = lambda { |original, ar| ... }
end

RailsOtelContext.install! # registers AR hooks, around_action, and the span processor

require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'opentelemetry/instrumentation/all'

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch('OTEL_SERVICE_NAME', 'my_app')
  c.use_all
end
```

`install!` is idempotent — the railtie calls it automatically via `after_initialize`, so apps that let Bundler auto-require the gem do not need to call it.

## How `code.namespace` / `code.function` works

On every span start, the gem walks the Ruby call stack (`Thread.each_caller_location`) and finds the first frame inside `Rails.root`. That frame becomes the four `code.*` attributes.

This means the right class shows up automatically at every layer:

| Caller | `code.namespace` | `code.function` |
|---|---|---|
| `ReportsController#index` calls `BillingService#monthly_summary` which queries | `BillingService` | `monthly_summary` |
| `UserRepository#find_active` queries directly | `UserRepository` | `find_active` |
| `OrdersController#create` queries directly | `OrdersController` | `create` |
| `MonthlyInvoiceJob#perform` queries | `MonthlyInvoiceJob` | `perform` |

No `include` statements. No `with_frame` calls. The nearest frame wins.

### Override for hot paths

The stack walk is O(stack depth) — roughly 15–25 frame iterations before reaching app code. For code paths that create thousands of spans per second, `FrameContext.with_frame` replaces the walk with a single thread-local read:

```ruby
class ReportingPipeline
  include RailsOtelContext::Frameable

  def run
    # All spans inside this block skip the stack walk.
    # code.namespace: "ReportingPipeline", code.function: "run"
    with_otel_frame { process_all_accounts }
  end
end
```

The pushed frame takes priority for the duration of the block. Outside the block, automatic stack-walk resumes.

## Span naming

Without a formatter, DB spans carry the driver's name (`SELECT`, `INSERT`). With the example formatter above:

| Query | Result |
|---|---|
| `Transaction.recent_completed.to_a` | `Transaction.recent_completed` |
| `Transaction.total_revenue` (class method) | `Transaction.total_revenue` |
| `Transaction.where(...).first` | `Transaction.Load` |
| `record.update(...)` | `Transaction.Update` |
| Counter cache / `connection.execute` | `User.Update` (SQL parsed → table → model) |

The original name is preserved in `l9.orig.name`.

### Counter caches and raw SQL

Rails counter caches, `touch_later`, and `connection.execute` fire `sql.active_record` with `payload[:name] = "SQL"`. The gem parses the statement and maps the table back to an AR model:

```
UPDATE `users` SET `users`.`comments_count` = ...
  → code.activerecord.model: "User", method: "Update"
  → span renamed to "User.Update"
```

### Scope tracking

Both `scope` macro methods and plain class methods returning a Relation are captured:

```ruby
class Transaction < ApplicationRecord
  scope :recent_completed, -> { where(...) }  # code.activerecord.scope: "recent_completed"

  def self.for_account(id)                     # also captured
    where(account_id: id)
  end
end
```

## Redis and ClickHouse

Redis is enabled by default. ClickHouse requires opt-in:

```ruby
c.clickhouse_enabled = true
```

Both get the same `code.*` attributes pointing to the app-code frame that issued the call:

```json
{
  "name": "SET",
  "db.system": "redis",
  "code.namespace": "SessionStore",
  "code.function": "write",
  "code.filepath": "app/lib/session_store.rb",
  "code.lineno": 18,
  "rails.controller": "SessionsController",
  "rails.action": "create"
}
```

### ClickHouse span naming

ClickHouse spans follow the OTel DB convention: `"{VERB} {table}"`. No configuration required — this happens automatically when the ClickHouse adapter is active.

| Query | Span name |
|---|---|
| `SELECT * FROM events` | `SELECT events` |
| `INSERT INTO analytics.page_views ...` | `INSERT page_views` |
| `OPTIMIZE TABLE logs` | `OPTIMIZE clickhouse` (no FROM — falls back gracefully) |

Schema-qualified tables (`db.table`) are supported: `db.name` gets the schema, `db.sql.table` gets the bare table name.

If you've configured a `span_name_formatter`, it runs on ClickHouse spans too — same formatter, no extra wiring. The original OTel name is preserved in `l9.orig.name`.

## Capturing request and response bodies

`BodyCapture` is a Rack middleware that attaches request and response bodies to the active OTel span. It's opt-in — add it to your middleware stack:

```ruby
# config/application.rb (or an initializer, after OTel is configured)
config.middleware.use RailsOtelContext::BodyCapture
```

That's the zero-config path. Bodies land on `http.request.body` and `http.response.body`, capped at 8 KB, for `application/json`, `application/xml`, and `text/plain` content types. `/health`, `/ready`, and `/metrics` are excluded by default.

The option that matters most in production:

```ruby
config.middleware.use RailsOtelContext::BodyCapture, on_error_only: true
```

With `on_error_only: true`, the response body is never buffered on the success path — zero overhead for 2xx. Bodies are only captured when status >= 400, which is exactly when you need them.

Full options:

| Option | Default | Description |
|---|---|---|
| `on_error_only:` | `false` | Capture only on 4xx/5xx |
| `max_bytes:` | `8192` | Truncate bodies above this size |
| `content_types:` | `%w[application/json application/xml text/plain]` | Allowlist |
| `include_paths:` | `nil` | Restrict capture to these path prefixes |
| `exclude_paths:` | `%w[/health /ready /metrics]` | Skip these path prefixes |

## Connection pool tracing

When you're chasing timeouts or thread starvation, knowing that `checkout` spent 200ms waiting for a connection is the difference between guessing and knowing. Both `clickhouse_enabled` and `connection_pool_tracing_enabled` are off by default — they patch third-party classes and add a span per call, which is overhead you should choose consciously. Enable it:

```ruby
RailsOtelContext.configure do |c|
  c.connection_pool_tracing_enabled = true
end
```

Each `checkout` call gets its own span with pool state at the moment of acquisition:

| Attribute | Description |
|---|---|
| `db.pool.size` | Total pool capacity |
| `db.pool.busy` | Connections currently checked out |
| `db.pool.idle` | Connections available |
| `db.pool.waiting` | Threads queued waiting for a connection |

Spans inside transactions and `with_connection` blocks are skipped — a pinned connection is already held, so there's nothing to measure.

## Memory and GC attribution

Your pods are getting OOM-killed. You want to know which endpoint is eating the memory. You don't want to run a profiler in production. You don't want to pay for an APM.

Same problem [Scout APM](https://github.com/scoutapp/scout_apm_ruby) solved years ago with their "Memory Bloat" feature, and their trick is embarrassingly simple: wrap every instrumented layer with `GC.stat` before and after, subtract the two, call the difference "this layer's allocations." No profiler. No stack sampling. No magic.

Turns out OTel already wraps those same layers with spans — controller actions, AR queries, view renders, HTTP calls, cache ops, jobs. So we do the same thing Scout does, just on the Span object instead of in a proprietary agent. One prepend and you get per-layer allocation attribution on every trace, for free.

Off by default. Flip it on:

```ruby
RailsOtelContext.configure do |c|
  c.capture_allocations          = true   # ruby.alloc.* on every span
  c.capture_memory_metrics       = true   # per-request / per-job histograms
  c.process_sampler_interval_sec = 15     # background RSS + heap gauges; nil to disable
end
```

That's it. Now every span in your trace has `ruby.alloc.objects`, `ruby.gc.time_ms`, `ruby.gc.major_count`, `ruby.gc.minor_count`. Because `rails.controller`, `rails.action`, `rails.job`, `code.namespace`, `code.function`, `code.filepath`, `code.lineno` are already there, any tracing backend can rank the offenders. No dashboard required.

You also get histograms — `ruby.request.allocated_objects` labeled by `{controller, action}` and `ruby.job.allocated_objects` labeled by `{job_class, queue}`, plus GC time, major, minor. Low cardinality. Aggregatable. Recorded inside the active span so trace-based exemplars link the spike back to the offending trace. Want that link? One env var:

```bash
OTEL_METRICS_EXEMPLAR_FILTER=trace_based
```

Process-level gauges come out under `process.runtime.ruby.*` — the OTel semantic convention namespace. Backends with built-in Ruby runtime panels (live slots, free slots, RSS, major/minor GC counts, total allocated objects) surface them automatically. Samples carry `role` (`web` or `sidekiq`) and `pid`.

### What you're trading away

- `GC.stat` is process-global. Under threaded Puma, concurrent spans on the same worker smear allocations across each other. p99 ranking still surfaces real offenders. Scout eats the same tradeoff.
- No allocated-**bytes**. `malloc_increase_bytes` resets on every GC, so deltas at span grain are unreliable. Object count is monotonic and that's what we report.
- No retained-heap analysis. That needs `ObjectSpace.dump_all`, which is on-demand only and out of scope here.
- RSS on Linux only. macOS / Windows dev boxes skip the gauge silently.

### Overhead

`GC.stat(:key)` with a symbol returns a primitive, not a Hash — no allocation. Four reads on span start, four on span finish. Sub-microsecond each. If you have a hundred spans per request you're paying under a millisecond for the entire feature.

## Performance

`CallContextProcessor#on_start` fires for every span. For a typical 10–20 span request the overhead is in the low-microsecond range and does not require configuration.

For code paths that generate hundreds of spans per second, `FrameContext.with_frame` / `Frameable#with_otel_frame` replace the per-span stack walk with a single thread-local read. See [Override for hot paths](#override-for-hot-paths).

### Boot cost

`ScopeNameTracking` hooks `singleton_method_added` on every AR model to detect class methods returning a Relation. On a large app (100+ models), this fires thousands of times during warm-up — one `source_location` call and one method redefinition per class method in `app/`. This is a one-time startup cost, not a per-request cost.

`ar_table_model_map` is built once at boot from `AR::Base.descendants`. In development, call `RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!` after a code reload if model names look stale.

## Requirements

- Ruby >= 3.1
- Rails >= 7.0
- `opentelemetry-api` >= 1.0

## License

MIT
