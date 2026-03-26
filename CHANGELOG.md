# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-03-27

### Added
- **Custom span attributes** (`custom_span_attributes`) — propagate request-scoped attributes (team, tenant, domain) to every span in a trace via a lambda callback
- **Request context propagation** (`request_context_enabled`) — automatically propagate `request.controller` and `request.action` to all child spans
- **ActiveRecord scope tracking** — capture scope names (e.g., `recent_completed`, `by_status`) on lazy relation queries via `code.activerecord.scope` attribute
- **Notification-based AR context** — use `sql.active_record` notification subscriber (same approach as Datadog/Scout APM) instead of stack-walking for reliable model name extraction
- **Span name formatter** receives `scope_name`, `code_namespace`, `code_function` in `ar_context` for intelligent span renaming
- **Original span name preservation** — `l9.orig.name` attribute stores the original span name when the formatter renames it
- **Trilogy adapter** support for MySQL-compatible databases
- **ProxyTracerProvider guard** — gracefully skip processor registration when OTel SDK is not configured (e.g., behind `ENABLE_OTLP` env var)
- **Environment variable kill switches** — `RAILS_OTEL_CONTEXT_CUSTOM_SPAN_ATTRIBUTES_ENABLED` and `RAILS_OTEL_CONTEXT_REQUEST_CONTEXT_ENABLED` for instant rollback without redeploy
- Thread-local `RequestContext` with leak-proof `around_action` cleanup
- 98 tests across 9 test files

### Changed
- **AR model attributes always set** — `code.activerecord.model` and `code.activerecord.method` are now set on every DB span regardless of query speed (previously gated behind slow query threshold)
- **Config read at query time** — slow query thresholds are read from config at query execution time, not captured at adapter install time (fixes load-order issues with Rails initializers)
- **Span rename uses `name=`** instead of `update_name` (correct OTel Ruby SDK API)
- Extracted `SourceLocation` into shared module (was duplicated across all adapters)
- Attribute name constants: `AR_MODEL_ATTR`, `AR_METHOD_ATTR`, `AR_SCOPE_ATTR`, `ORIG_NAME_ATTR`
- Thread-local keys are now private constants with `stub_context`/`clear!` test helpers
- `ScopeNameTracking` guards against double-wrap on class reload in development

### Fixed
- `NoMethodError` when OTel SDK not configured (`ProxyTracerProvider` lacks `add_span_processor`)
- `ActiveRecordContext.extract` returning nil in real Rails apps (stack-walking couldn't find model names through AR gem internals)
- Load-order bug where user's `trilogy_slow_query_threshold_ms = 0.0` was ignored because adapter captured default 200ms at install time

## [0.1.0] - 2026-03-25

### Added
- Initial release
- Source code location tracking for database queries (PG, MySQL2, ClickHouse)
- ActiveRecord model and method context extraction via stack-walking
- Redis source location tracking (opt-in)
- ClickHouse instrumentation (creates spans where none exist)
- Caller context processor (`code.namespace`, `code.function`, `code.lineno` on all spans)
- Configurable slow query thresholds per adapter
- Environment variable configuration support
- Zero-config Rails integration via Railtie
- Span name formatter for customizing DB span names
