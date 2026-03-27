# rails-otel-context

[![CI](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml/badge.svg)](https://github.com/last9/rails-otel-context/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/rails-otel-context.svg)](https://badge.fury.io/rb/rails-otel-context)

Enriches OpenTelemetry spans in Rails with source location, ActiveRecord model context, and caller identity. Works automatically via a Railtie — no setup required.

## What changes

A database span without this gem:

```json
{
  "name": "SELECT products",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM products WHERE active = true",
  "duration_ms": 450
}
```

With this gem:

```json
{
  "name": "Product.active",
  "db.system": "postgresql",
  "db.statement": "SELECT * FROM products WHERE active = true",
  "duration_ms": 450,
  "code.activerecord.model": "Product",
  "code.activerecord.method": "Load",
  "code.activerecord.scope": "active",
  "code.namespace": "ProductsController",
  "code.function": "index",
  "code.filepath": "app/controllers/products_controller.rb",
  "code.lineno": 12
}
```

Navigate straight to the offending line. No grepping required.

## Installation

```ruby
gem 'rails-otel-context', '~> 0.6'
```

That's it. Adapters install automatically when ActiveRecord loads.

## Configuration

The defaults are sensible. A minimal production initializer:

```ruby
# config/initializers/rails_otel_context.rb
RailsOtelContext.configure do |c|
  # Rename DB spans using model + scope/method context
  c.span_name_formatter = ->(original, ar) {
    model = ar[:model_name]
    return original unless model

    method = ar[:scope_name] ||
             (ar[:code_function] if ar[:code_namespace] == model && !ar[:code_function]&.start_with?('<')) ||
             ar[:method_name]
    "#{model}.#{method}"
  }

  # Propagate controller/action to all child spans
  c.request_context_enabled = true

  # Attach team/tenant to every span in the trace
  c.custom_span_attributes = -> { { 'team' => Current.team } if Current.team }
end
```

### Span name formatter

Without a formatter, DB spans are named by the driver (`SELECT`, `INSERT`, etc.). The formatter above renames them to `Model.scope_or_method` using the ActiveRecord context captured on every query:

| Query | `ar` keys available | Span name |
|---|---|---|
| `Transaction.recent_completed.to_a` | `scope_name: "recent_completed"` | `Transaction.recent_completed` |
| `Transaction.total_revenue` | `code_function: "total_revenue"`, `code_namespace: "Transaction"` | `Transaction.total_revenue` |
| `Transaction.where(...).first` | `method_name: "Load"` | `Transaction.Load` |
| `record.update(...)` | `method_name: "Update"` | `Transaction.Update` |

The original span name is preserved in `l9.orig.name`.

### Redis

Redis source location tracking is off by default — it's high-volume and most Redis calls are fast. Enable it when debugging:

```ruby
c.redis_source_enabled = true
```

### ClickHouse

ClickHouse has no official OpenTelemetry instrumentation. This gem creates client spans automatically for any loaded `ClickHouse::Client`, `ClickHouse::Connection`, or `Clickhouse::Client`.

## Requirements

- Ruby >= 3.1
- Rails >= 7.0
- `opentelemetry-api` >= 1.0

## License

MIT
