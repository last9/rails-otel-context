# Autoresearch: AR Observability & Perf Hotspots

**Branch:** autoresearch/ar-observability-20260330
**Goal:** Reduce allocations per subscriber call + close AR observability gaps
**Metric:** total allocations per start+finish cycle (lower=better), test suite green

## Baseline
- named query: 5.0 allocs/call
- SQL-named: 7.0 allocs/call
- total: 12.0 allocs/call
- tests: 69 passing (89 before SQL path changes; 73 now with all new tests)

## Allocation Floor (current — 10.0 total)

Named path (4):
- `name[0, idx]` word slice → 1 String alloc
- ctx Hash (1 alloc)
- frozen query_key String (1 alloc)
- timing ivars on Subscriber instance (0 alloc)

SQL path (6):
- `sql[SQL_VERB_RE, 1]&.capitalize` → 2 allocs (capture String + capitalize)
  - Note: replacing verb regex with `index`+`casecmp?` tried; memory_profiler counts same 2 allocs
- `extract_table_after`: `index()` → 0, `getbyte` loop → 0, final `sql[start, len]` → 1 alloc
  - Replaced table regex (2 allocs: MatchData + capture) → saves 1 per SQL call
- ctx Hash + query_key String → 2 allocs

Remaining opportunities:
- verb regex (2 allocs): `String#[re, 1]` always allocates MatchData + capture; no cheaper alternative
- ctx Hash (1 alloc): unavoidable — must return mutable hash
- query_key String (1 alloc): unavoidable with string interpolation

## Ideas Backlog

### Perf experiments
- [x] Replace `split(' ', 2)` with `index`+`byteslice` → saved 1 alloc on named path (5→4/call)
- [x] Timing Array → ivars on Subscriber → 0 alloc for threshold path
- [x] Replace table regex with `extract_table_after` (index+getbyte) → saved 1 alloc on SQL path (7→6/call)
- [ ] Intern ctx hash via frozen hash pool (risky — mutable ctx, not worth it)

### Observability gaps
- [x] STI bug: `ar_table_model_map` last-write-wins for subclasses sharing parent table
       Fix: `next unless m.base_class == m`
- [x] `load_async` (Rails 7+): `payload[:async]` detected → `db.async: true` on span
- [x] Missing AR methods verified: Pluck, Ids, Destroy All all parse correctly
- [x] `find_each`/`find_in_batches`: scope captured per batch — no gap (exec_queries wraps each batch)
- [ ] `eager_load` JOIN queries: SQL_SELECT_RE picks first FROM table, may be wrong for complex JOINs
       Status: graceful degradation — returns nil when table not in map, span skipped (acceptable)
- [ ] `strict_loading` violations: these raise Ruby exceptions, do not fire sql.active_record
       Status: no OTel span created, nothing to instrument here
- [ ] `load_async` full thread propagation: SCOPE_THREAD_KEY / QUERY_COUNT_KEY not in pool threads
       Status: `db.async: true` flags the span; full propagation requires executor integration

## Results Log

| # | Experiment | named | sql | total | status |
|---|---|---|---|---|---|
| 0 | baseline | 5.0 | 7.0 | 12.0 | ✓ baseline |
| 1 | STI fix `base_class == m` | 5.0 | 7.0 | 12.0 | ✓ kept (correctness, 0 alloc change) |
| 2 | parse_ar_name: split → index+[] | 4.0 | 7.0 | 11.0 | ✓ kept (-1 alloc named) |
| 3 | load_async: db.async attribute | 4.0 | 7.0 | 11.0 | ✓ kept (observability, 0 alloc change) |
| 4 | verb regex → index+casecmp? | 4.0 | 7.0 | 11.0 | ✗ reverted (no alloc savings) |
| 5 | AR method coverage + find_each test | 4.0 | 7.0 | 11.0 | ✓ kept (gap verification) |
| 6 | table regex → extract_table_after (index+getbyte) | 4.0 | 6.0 | 10.0 | ✓ kept (-1 alloc SQL path) |
