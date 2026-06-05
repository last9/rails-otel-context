# CLAUDE.md — rails-otel-context

## Project
Ruby gem (`rails-otel-context`) providing Rails-specific OpenTelemetry enrichment.
Published to RubyGems. Maintained by Last9.

## Release workflow
1. Edit `lib/rails_otel_context/version.rb`
2. Add entry to `CHANGELOG.md`
3. Run `bundle exec rake test` — all must pass
4. Run `bundle exec rubocop` — no offenses
5. `gem build rails-otel-context.gemspec`
6. Commit, push, tag: `git tag vX.Y.Z <sha> && git push origin vX.Y.Z`
7. `gem push rails-otel-context-X.Y.Z.gem` (requires OTP)

## Bug workflow
Always reproduce first — write a failing test before touching code.
Run the new test against pre-fix code to confirm it fails, then apply fix and
confirm it passes. Never commit a fix without a reproducing test.
Documented solutions to past problems live in `docs/solutions/` (organized by
category, YAML frontmatter: `module`, `tags`, `problem_type`) — relevant when
debugging or changing behavior in previously documented areas.

## ClickHouse adapter rules
- `CANDIDATE_METHODS` must not include methods that delegate entirely to another
  candidate (e.g. `insert`/`insert_rows`/`insert_compact` all call `execute` — only
  `execute` belongs in the list). Wrapping delegators adds fragile patches that break
  when the gem changes keyword-argument signatures.
- Tests for ClickHouse adapter changes must cover: span name, `db.operation`,
  `db.system`, and kwarg forwarding where the patched method uses keyword args.
- `build_patch_module` must always use `|*args, **kwargs, &block|` and
  `super(*args, **kwargs, &block)` — never drop the `**kwargs` splat.

## Key invariants
- `span_name_formatter` must only run on DB spans (`db.system` attribute present).
  Never rename HTTP, controller, job, or custom spans.
- `RequestContext` is set by `around_action` — must hook both
  `on_load(:action_controller)` AND `on_load(:action_controller_api)` for
  API-only Rails apps.
- `install_processor!` is idempotent — guarded by `@processor_installed`.
- Bundler auto-require: `rails-otel-context` → `require 'rails/otel/context'`.
  `lib/rails/otel/context.rb` shim must exist.

## Never commit
- Screenshots, exports, or any media/data files (*.png, *.jpg, *.csv, *.pdf, etc.)
  — covered by .gitignore, but double-check before `git add`
- `TESTING.md` files
- Customer names in commit messages, PR titles, or code comments
- `.env` files or credentials
