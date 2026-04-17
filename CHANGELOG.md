# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.9] - 2026-04-17

### Fixed
- **ClickHouse adapter: `insert_rows`/`insert_compact` `ArgumentError` (issue #28)**: `insert_rows(table, body, format: nil)` and `insert_compact` use keyword arguments. The patch module's `define_method` wrapper only captured `*args`, so the `format:` keyword was passed as a stray positional Hash and then forwarded as a third positional argument — raising `ArgumentError: wrong number of arguments (given 3, expected 2)` in production.
- **Reduced monkey-patch surface**: Removed `insert`, `insert_rows`, and `insert_compact` from `CANDIDATE_METHODS`. In click_house v2.x all three delegate to `execute` internally, so patching `execute` alone is sufficient. This eliminates three fragile wraps of methods whose internal keyword-argument signatures may change across gem versions.
- **`**kwargs` forwarding**: `build_patch_module` now uses `|*args, **kwargs, &block|` and `super(*args, **kwargs, &block)` throughout — making the wrapper transparent to any method signature that mixes positional and keyword arguments.

## [0.9.8] - 2026-04-14

### Added
- **ClickHouse adapter v2.x support**: Expanded `CANDIDATE_METHODS` to include `select_all`, `select_one`, `select_value`, `insert_compact`, and `insert_rows` — the method names introduced in `click_house` gem v2.x. Previously only `execute`/`insert`/`query`/`select` were patched, so v2 queries appeared as plain Faraday HTTP spans with no `db.system` attribute. Added `METHOD_OP_ALIAS` map to normalise compound names (`SELECT_ALL → SELECT`, `INSERT_COMPACT → INSERT`) for readable `db.operation` values and span names.
- **ClickHouse span naming — OTel DB convention**: Added `span_name_for` and `parse_table` helpers. Spans are now named `"{VERB} {table}"` (e.g. `SELECT tables`, `INSERT events`) following the OpenTelemetry DB semantic conventions. `parse_table` supports schema-qualified names (`db.table → [db, table]`). The `table_name:` keyword on `span_name_for` avoids a double regex scan when the caller already holds the parsed table.
- **ClickHouse `span_name_formatter` integration**: ClickHouse spans now run the configured `span_name_formatter` inline (with a synthetic AR-shaped context built from `code.namespace`/`code.function`) so they get the same custom display names as ActiveRecord spans.
- **PREPARE span AR context enrichment (PostgreSQL)**: PG's prepared-statement flow emits a `PREPARE` wire operation before `EXECUTE`. The PREPARE span finishes before `sql.active_record` fires, so `on_start` never sees AR context. `CallContextProcessor#on_finish` now stashes PREPARE spans (those with `db.operation: PREPARE` and no `code.activerecord.model`) via `ActiveRecordContext.stash_prepare_span`. When `Subscriber#start` fires for the enclosing notification, it retroactively applies AR context to stashed spans via direct `@attributes` mutation (since `span.recording?` is false for finished spans, `set_attribute` would be a no-op).
- **`BodyCapture` Rack middleware**: New `RailsOtelContext::BodyCapture` middleware captures request and response bodies onto the active OTel span as `http.request.body` / `http.response.body`. Supports `on_error_only:`, `max_bytes:`, `content_types:`, `include_paths:`, and `exclude_paths:` options. On the success path with `on_error_only: true`, the response body is never buffered — zero overhead.
- **`ConnectionPool` checkout tracing**: New `RailsOtelContext::Adapters::ConnectionPool` adapter (opt-in via `config.connection_pool_tracing_enabled = true`) wraps `ActiveRecord::ConnectionAdapters::ConnectionPool#checkout` in an OTel span with `db.pool.size`, `db.pool.busy`, `db.pool.idle`, and `db.pool.waiting` attributes. Skips span creation when a pinned connection is already held (transactions, `with_connection` blocks).

## [0.9.7] - 2026-04-09

### Fixed
- **DB adapter call-site attributes on wrong span**: Trilogy, PG, and Mysql2 adapters previously called `apply_call_site_to_span(current_span)` _after_ `super()`. Because the OTel instrumentation creates and finishes the child DB span inside `super()`, `current_span` at that point is already the parent — so `code.*` attributes were silently dropped. All three adapters now use `with_call_site_frame { super(...) }`, which pushes the nearest app-code frame into `FrameContext` before the child span starts. `CallContextProcessor#on_start` reads `FrameContext` (O(1)) and applies `code.namespace`, `code.function`, `code.filepath`, and `code.lineno` to the child span correctly. Verified end-to-end in a real Rails app: all 31 DB spans received correct call-site attributes.
- **`FrameContext.with_frame` / `push` now accept `filepath` and `lineno`**: Previously these keyword args were silently ignored, so adapters passing full call-site data to `FrameContext` only stored `class_name` and `method_name`. The frame hash now includes all four fields and is frozen.

## [0.9.6] - 2026-04-07

### Added
- **`RailsOtelContext.install!`** — new public method for apps that load the gem with `require: false` and require it conditionally inside `config/initializers/`. When gems are required inside an initializer, Railtie `initializer` blocks have already executed and all `ActiveSupport.on_load` hooks are missed — `rails.controller`, `rails.action`, `rails.job`, `code.activerecord.*` are all absent from spans. Calling `RailsOtelContext.install!` from the same initializer registers all hooks (AR, controller, API controller, job) and installs the span processor regardless of load order. Idempotent — safe to call multiple times.

## [0.9.5] - 2026-04-07

### Fixed
- **`force_flush` / `shutdown` returning `nil`**: `CallContextProcessor#force_flush` and `#shutdown` previously returned `nil` (implicit Ruby return). The OTel SDK's `tracer_provider.force_flush` aggregates processor results with `results.max` — passing `nil` alongside integer status codes raises `ArgumentError: comparison of Integer with nil failed`. Both methods now return `0` (`Export::SUCCESS`), matching the SDK contract. Triggered in production during `db:schema:dump` and other `force_flush` call sites.

## [0.9.4] - 2026-03-31

### Fixed
- **`span_name_formatter` renaming HTTP/controller spans**: The formatter was called on any span when `ActiveRecordContext.current` was non-nil — including the HTTP root span when an AR context happened to be active on the thread. Added a `db.system` attribute guard to both `CallContextProcessor#apply_span_name_formatter` and `ActiveRecordContext#apply_to_span` so the formatter only fires on actual DB spans (Trilogy, PG, MySQL2, ClickHouse — all of which carry `db.system`).

## [0.9.3] - 2026-03-31

### Fixed
- **Gem never loaded when added to Gemfile without explicit `require:`**: Bundler's auto-require converts the gem name `rails-otel-context` to `rails/otel/context` (hyphens → slashes). The file `lib/rails/otel/context.rb` was missing, so `Bundler.require` silently failed and the Railtie never registered — no instrumentation at all. Added `lib/rails/otel/context.rb` as a shim that requires `rails_otel_context`, fixing zero-config installation.

## [0.9.2] - 2026-03-31

### Fixed
- **`rails.controller` / `rails.action` missing in Rails 8 API-only apps**: `install_request_context` was only hooking `on_load(:action_controller)`, which fires for `ActionController::Base` subclasses only. `ActionController::API` (the default in `rails new --api` and Rails 8 API-only apps) fires `on_load(:action_controller_api)` instead. Added a second `on_load(:action_controller_api)` hook with the same `around_action` block so `rails.controller` and `rails.action` appear on every span in API-only apps.

## [0.9.1] - 2026-03-31

### Fixed
- **`RailsOtelContext.install_processor!`** — new public method that registers `CallContextProcessor` with the OTel tracer provider. Call this manually when `OpenTelemetry::SDK.configure` runs after the Railtie's `after_initialize` (e.g. inside a custom `config.after_initialize` block). The Railtie calls it automatically on the standard boot path. Idempotent — safe to call multiple times.

## [0.9.0] - 2026-03-31

### Changed (breaking)
- **`rails.*` attributes on every span**: renamed `request.controller` → `rails.controller` and `request.action` → `rails.action`. These attributes now appear on **all** spans (HTTP, DB, cache, custom), not just DB spans, and are always enabled — `request_context_enabled` is now a no-op (kept for backwards compat).
- **`code.namespace`/`code.function` = nearest frame, zero manual work**: removed `install_frame_context` from the Railtie. The controller frame is no longer auto-pushed into `FrameContext`. `CallContextProcessor` now always stack-walks to find the nearest app-code frame, so service objects, repositories, and jobs all show up correctly without `include Frameable` or `with_otel_frame` calls. `FrameContext.with_frame` / `Frameable` still work as explicit overrides.

### Added
- **`rails.job` on every span inside a job**: new `install_job_context` Railtie initializer hooks `ActiveJob::Base.around_perform`, sets `RequestContext.job = job.class.name`, and clears in ensure. Every DB, HTTP, and custom span created inside a job now carries `rails.job: "MyJobClass"`.
- **`RequestContext.set_job` / `RequestContext.job` / `RequestContext.clear_job!`**: new public API for the job context slot.

## [0.8.5] - 2026-03-31

### Fixed
- **ClickHouse spans missing `code.namespace`/`code.function`**: `build_patch_module` was calling `source_location_for_app` (filepath+lineno only) and `apply_source_to_span`. Switched to `call_site_for_app` + `apply_call_site_to_span` so ClickHouse spans now carry all four `code.*` attributes (`code.namespace`, `code.function`, `code.filepath`, `code.lineno`), consistent with PG/MySQL2/Trilogy.
- **Redis spans missing `code.namespace`/`code.function`**: Redis's `build_patch_module` had an inline `source_location_for_app` implementation returning only `[filepath, lineno]`. Removed the duplicate; included `RailsOtelContext::SourceLocation` on `class << self` and switched to `call_site_for_app`. The `with_attributes` hash now includes all four `code.*` attributes (nils compacted out).

## [0.8.4] - 2026-03-31

### Fixed
- **N+1 counter stale across requests** (bug when `request_context_enabled: false`, the default): `db.query_count` was never reset between requests on reused Puma threads, causing inflated counts on every request after the first. `install_frame_context`'s `around_action` (always installed, no config gate) now resets `QUERY_COUNT_KEY` at request start and in its `ensure` block.
- **`db.slow` on wrong span**: `Subscriber#finish` fired after the OTel Trilogy span had already ended, so `current_span` was the HTTP parent — `db.slow` landed there instead of on the slow DB span. Removed timing from `Subscriber` entirely; moved slow-query detection to `CallContextProcessor#on_finish`, which receives the actual DB span and uses `end_timestamp - start_timestamp` for duration. `db.slow: true` is now set directly on the DB span via its internal attributes store (span is non-recording at that point but the backing hash is still mutable before export).

## [0.8.3] - 2026-03-31

### Fixed
- **Raw SQL spans not enriched / not slow-flagged**: Two related issues with `connection.execute`-style queries:
  1. Slow-query timing was set up after `return unless ctx`, so queries that can't resolve a model name (e.g. `SELECT SLEEP(0.2)`, `SELECT 1`) never got `db.slow: true`. Timing is now set up before the ctx check.
  2. `parse_sql_context` returned `nil` for SQL whose table can't be resolved to an AR model (unregistered table, no FROM clause). It now returns a partial context with `model_name: "SQL"` so the span formatter can produce `"SQL.Select"` / `"SQL.Update"` for tab-group purposes.

## [0.8.2] - 2026-03-31

### Fixed
- **`connection.execute` spans not enriched**: `payload[:name]` is `nil` for raw `connection.execute(sql)` calls (Rails passes `nil` as the name argument, not `"SQL"`). The subscriber was returning early on nil, skipping both model-context enrichment and slow-query timing. Now nil name is treated identically to `"SQL"` — `parse_sql_context` runs, `apply_to_span` enriches the live span, and `db.slow` fires if the threshold is exceeded.

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
