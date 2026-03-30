# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.1] - 2026-03-31

### Fixed
- **SQL-named spans not renamed in development**: `ar_table_model_map` was built once lazily, often hitting an empty `ActiveRecord::Base.descendants` in dev (lazy class loading). Added `config.to_prepare` hook in Railtie to reset the map after every code reload so counter-cache `UPDATE`, `INSERT`, and raw `SELECT` spans get model context and are renamed by the formatter.
- **Cold-boot production gap**: Added `after_initialize` warm-up call so the map is populated before the first request rather than on the first SQL-named event.

## [0.8.0] - 2026-03-31

### Added
- **Push-model `FrameContext`** — push `class_name`/`method_name` at call entry so span processors read an O(1) thread-local instead of walking the call stack on every span start. Supports `with_frame` (block), `push`/`pop` (manual ensure), and `clear!`.
- **`Frameable` mixin** — include in service objects, jobs, or any class to get `with_otel_frame { }` which auto-pushes `self.class.name` + calling method name.
- **Railtie controller frame push** — new `install_frame_context` initializer installs an `around_action` that automatically pushes the controller class and action name for every request. Zero config required.
- **SQL-named span observability** — `sql.active_record` notifications with `name: "SQL"` (counter caches, `touch_later`, `connection.execute`) are now enriched with `code.activerecord.model` and `code.activerecord.method` by parsing the raw SQL and resolving the table name via a lazy AR model index.
- **`db.async` attribute** — set to `true` on spans for async queries (when `payload[:async]` is present).
- **AR table→model map** — lazy-built index of `table_name → model_name` with STI filtering (subclasses sharing a parent's table are excluded so counter-cache spans report the base class).
- **`call_site_for_app`** in `SourceLocation` — unified helper returning all four call-site attributes (`class_name`, `method_name`, `filepath`, `lineno`) in one stack walk. All DB adapters (Trilogy, PG, MySQL2) now set `code.namespace` + `code.function` in addition to `code.filepath` + `code.lineno`.
- **Allocation guard CI** (`bench/allocation_guard.rb`) — deterministic per-call allocation budget enforced in CI: 4 allocs/span-start, 6 allocs/SQL call.

### Changed
- **`extract_table_after`** replaces table-extraction regex with an index+`getbyte` loop, saving 1 allocation per SQL-named query (7 → 6 allocs/call).
- **`parse_ar_name`** uses `index`+slice instead of `split(' ', 2)`, saving 1 Array allocation per named AR query.
- DB adapters now call `apply_call_site_to_span` (sets all 4 `code.*` attributes) instead of `apply_source_to_span` (filepath+lineno only).
- `CallContextProcessor` includes `SourceLocation` and uses pushed frame as fast path, falling back to `call_site_for_app` stack walk.

### Fixed
- **Thread-safety**: `Subscriber` timing state reverted from instance variables to thread-local storage (`TIMING_ID_KEY`/`TIMING_START_KEY`) — instance variables on a singleton subscriber are shared across threads and would corrupt timing under concurrent load.

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
