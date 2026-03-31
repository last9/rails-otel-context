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

Zero configuration gets you everything above. The optional initializer adds span naming and slow-query detection:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  # Rename DB spans from "SELECT" to "Transaction.recent_completed"
  c.span_name_formatter = ->(original, ar) {
    model = ar[:model_name]
    return original unless model

    method = ar[:scope_name] ||
             (ar[:code_function] if ar[:code_namespace] == model && !ar[:code_function]&.start_with?('<')) ||
             ar[:method_name]
    "#{model}.#{method}"
  }

  # Flag slow queries
  c.slow_query_threshold_ms = 500

  # Attach any per-request context to every span
  c.custom_span_attributes = -> { { 'tenant' => Current.tenant } if Current.tenant }
end
```

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

Redis and ClickHouse spans get the same `code.*` attributes pointing to the app-code frame that issued the call:

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

## Performance

### Per-span cost

`CallContextProcessor#on_start` fires for every span. The main costs:

**Stack walk (default, O(stack depth))**: `Thread.each_caller_location` iterates lazily and stops at the first app-code frame. Typically 15–25 frame checks through Rack/Rails/OTel internals. Each miss checks `absolute_path.start_with?(app_root)` — a string prefix test. On a hit, `build_call_site` allocates ~6–8 short-lived objects (a Hash, a few Strings). These are collected in the next minor GC; they do not accumulate.

**Explicit override (O(1))**: `FrameContext.with_frame` / `Frameable#with_otel_frame` replace the walk with one thread-local read per span. Use this for code paths generating thousands of spans per second. For a typical 10–20 span request, the walk overhead is ~5–10 µs — measure before optimizing.

### AR subscriber allocation budget

The `sql.active_record` subscriber runs on every SQL query. The budget is enforced in CI:

```
ruby bench/allocation_guard.rb
```

```
PASS  named query (User Load): 4.0 allocs/call (budget: 4)
PASS  SQL-named counter cache UPDATE: 6.0 allocs/call (budget: 6)
```

Any increase requires updating the budget constant — a deliberate, reviewed decision.

### Full profiling

```
bundle exec ruby bench/subscriber_hot_path.rb
```

Outputs throughput, per-call allocations with top allocating lines, and a StackProf CPU flamegraph at `tmp/subscriber.dump`:

```
stackprof --flamegraph tmp/subscriber.dump | open -f -a 'Google Chrome'
```

**Baseline (Ruby 3.3, Apple M-series):**

| Path | Allocs/call | Throughput |
|---|---|---|
| Named AR query (`User Load`) | 4 objects | ~900k i/s |
| SQL counter cache (`name=SQL`) | 6 objects | ~650k i/s |

### Boot cost

`ScopeNameTracking` hooks `singleton_method_added` on every AR model to detect class methods returning a Relation. On a large app (100+ models), this fires thousands of times during warm-up — one `source_location` call and one method redefinition per class method in `app/`. This is a one-time startup cost, not a per-request cost.

`ar_table_model_map` is built once at boot from `AR::Base.descendants`. In development, call `RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!` after a code reload if model names look stale.

## Requirements

- Ruby >= 3.1
- Rails >= 7.0
- `opentelemetry-api` >= 1.0

## License

MIT
