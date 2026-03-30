# rails-otel-context

[![CI](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml/badge.svg)](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/rails-otel-context)](https://rubygems.org/gems/rails-otel-context)

OpenTelemetry spans for Rails know a lot about your database. They know the SQL. They know how long it took. What they don't know is *which code fired that query* — the model, the scope, the controller, the line number. This gem fixes that.

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
  "code.activerecord.model": "Transaction",
  "code.activerecord.method": "Load",
  "code.activerecord.scope": "recent_completed",
  "code.namespace": "DashboardController",
  "code.function": "index",
  "code.filepath": "app/controllers/dashboard_controller.rb",
  "code.lineno": 14,
  "db.query_count": 47
}
```

You navigate straight to the offending line. No grepping, no guessing.

## Installation

```ruby
gem 'rails-otel-context', '~> 0.7'
```

That's it. Everything installs automatically when Rails boots.

## Configuration

The defaults are sensible. A production initializer that gets the most out of this gem:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  # Rename DB spans to Model.scope — makes traces scannable at a glance
  c.span_name_formatter = ->(original, ar) {
    model = ar[:model_name]
    return original unless model

    scope = ar[:scope_name] ||
            (ar[:code_function] if ar[:code_namespace] == model && !ar[:code_function]&.start_with?('<')) ||
            ar[:method_name]
    "#{model}.#{scope}"
  }

  # Carry controller + action name into every DB span fired during the request
  c.request_context_enabled = true

  # Flag slow queries (sets db.slow: true on spans exceeding the threshold)
  c.slow_query_threshold_ms = 500

  # Attach any per-request context to every span in the trace
  c.custom_span_attributes = -> { { 'team' => Current.team } if Current.team }
end
```

## What gets added to your spans

| Attribute | Example | Description |
|---|---|---|
| `code.activerecord.model` | `"Transaction"` | ActiveRecord model name |
| `code.activerecord.method` | `"Load"` | AR operation (Load, Count, Update…) |
| `code.activerecord.scope` | `"recent_completed"` | Named scope or class method that produced the query |
| `code.namespace` | `"DashboardController"` | Ruby class that triggered the span |
| `code.function` | `"index"` | Method name within that class |
| `code.filepath` | `"app/controllers/..."` | App-relative source file |
| `code.lineno` | `14` | Line number |
| `request.controller` | `"DashboardController"` | Rails controller (requires `request_context_enabled`) |
| `request.action` | `"index"` | Rails action (requires `request_context_enabled`) |
| `db.query_count` | `47` | How many times this model+operation was queried in this request — appears only on the 2nd+ occurrence, which flags N+1 patterns |
| `db.slow` | `true` | Set when query duration exceeds `slow_query_threshold_ms` |
| `db.async` | `true` | Set when query was issued via `load_async` (Rails 7.1+) |

## Span naming

Without a formatter, DB spans arrive named by the driver (`SELECT`, `INSERT`). The formatter in the example above renames them using what this gem knows about each query:

| What fired the query | Available context | Span name |
|---|---|---|
| `Transaction.recent_completed.to_a` | `scope_name: "recent_completed"` | `Transaction.recent_completed` |
| `Transaction.total_revenue` | `code_function: "total_revenue"` | `Transaction.total_revenue` |
| `Transaction.where(...).first` | `method_name: "Load"` | `Transaction.Load` |
| `record.update(...)` | `method_name: "Update"` | `Transaction.Update` |
| Counter cache, `connection.execute` | SQL parsed → table mapped to model | `User.Update` |

The original span name is preserved in `l9.orig.name` so you can always filter on the raw driver operation.

### Counter caches and raw SQL

Rails counter caches, `touch_later`, and `connection.execute` calls fire `sql.active_record` with `payload[:name] = "SQL"` rather than `"User Update"`. The gem parses the SQL statement directly and maps the table name back to the AR model:

```
UPDATE `users` SET `users`.`comments_count` = COALESCE(...)
  → code.activerecord.model: "User"
  → code.activerecord.method: "Update"
  → span renamed to "User.Update" (with formatter)
```

The table→model map is built from `AR::Base.descendants` on first use. In production with `eager_load!` this is always correct. In development, call this after a code reload if you see stale model names:

```ruby
RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
```

### Scope tracking

The gem captures scope names from both the `scope` macro and plain class methods that return a relation:

```ruby
class Transaction < ApplicationRecord
  scope :recent_completed, -> { where(...) }  # captured as code.activerecord.scope

  def self.for_account(id)                     # also captured
    where(account_id: id)
  end
end
```

## Redis

Redis source location tracking is off by default — it fires on every cache read and most Redis calls are fast. Turn it on when debugging:

```ruby
c.redis_source_enabled = true
```

## ClickHouse

No official OTel instrumentation exists for ClickHouse. This gem creates client spans automatically for `ClickHouse::Client`, `ClickHouse::Connection`, and `Clickhouse::Client`.

## Benchmarks

The subscriber runs in the hot path of every SQL query. Two scripts live in `bench/`:

### Allocation guard (also runs in CI)

Verifies the per-call allocation budget hasn't regressed. Deterministic — same count every run regardless of machine:

```
ruby bench/allocation_guard.rb
```

```
PASS  named query (User Load): 4.0 allocs/call (budget: 4)
PASS  SQL-named counter cache UPDATE: 6.0 allocs/call (budget: 6)

All allocation budgets met.
```

Exits 1 if any path exceeds its budget. Update the budget constant in `bench/allocation_guard.rb` whenever a deliberate trade-off is made.

### Full profiling suite

Throughput, per-call allocations with top allocating lines, and a StackProf CPU flamegraph:

```
bundle exec ruby bench/subscriber_hot_path.rb
```

The flamegraph dump lands at `tmp/subscriber.dump`. View it with:

```
stackprof --flamegraph tmp/subscriber.dump | open -f -a 'Google Chrome'
```

**Baseline (Ruby 3.3, Apple M-series):**

| Path | Allocs/call | Throughput |
|---|---|---|
| Named AR query (`User Load`) | 4 objects | ~900k i/s |
| SQL counter cache (`name=SQL`) | 6 objects | ~650k i/s |

## Requirements

- Ruby >= 3.1
- Rails >= 7.0
- `opentelemetry-api` >= 1.0

## License

MIT
