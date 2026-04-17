# frozen_string_literal: true

require_relative 'test_helper'

AR_CTX  = RailsOtelContext::ActiveRecordContext
REQ_CTX = RailsOtelContext::RequestContext
CCP     = RailsOtelContext::CallContextProcessor

# Integration tests for span enrichment flows that span multiple components.
#
# Covers cross-component invariants that unit tests with stubs cannot catch:
#   1. span_name_formatter must ONLY fire on DB spans (db.system present).
#   2. RequestContext controller/action/job propagates to child spans via the processor.
#   3. Slow-query threshold writes db.slow via @attributes mutation on a finished span.
#   4. ConnectionPool patch records checkout stats on a span via the tracer.
class SpanEnrichmentIntegrationTest < Minitest::Test
  APP_ROOT = Dir.pwd

  def setup
    RailsOtelContext.reset_configuration!
    REQ_CTX.clear!
    AR_CTX.stub_context(nil)
  end

  def teardown
    RailsOtelContext.reset_configuration!
    REQ_CTX.clear!
    AR_CTX.stub_context(nil)
  end

  # ── 1. span_name_formatter isolation ────────────────────────────────────────
  # CLAUDE.md invariant: formatter must ONLY run on DB spans (db.system present).

  def test_formatter_renames_db_span_but_not_http_or_job_spans
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ctx) { "#{ctx[:model_name]}.query" if ctx[:model_name] }
    end

    AR_CTX.stub_context(model_name: 'Post', method_name: 'index', scope_name: nil, query_count: nil, async: false)
    processor = CCP.new(app_root: APP_ROOT)

    db_span   = build_named_span('trilogy.query', 'db.system' => 'mysql2')
    http_span = build_named_span('HTTP GET /posts')
    job_span  = build_named_span('ImportJob#perform')

    processor.on_start(db_span, nil)
    processor.on_start(http_span, nil)
    processor.on_start(job_span, nil)

    assert_equal 'Post.query',        db_span.name,   'DB span must be renamed by formatter'
    assert_equal 'HTTP GET /posts',   http_span.name, 'HTTP span must NOT be renamed'
    assert_equal 'ImportJob#perform', job_span.name,  'job span must NOT be renamed'
  end

  def test_formatter_not_called_when_no_ar_context
    called = false
    RailsOtelContext.configure do |c|
      c.span_name_formatter = lambda { |_orig, _ctx|
        called = true
        nil
      }
    end

    processor = CCP.new(app_root: APP_ROOT)
    db_span   = build_named_span('pg.query', 'db.system' => 'postgresql')
    processor.on_start(db_span, nil)

    refute called, 'formatter must not be called when no AR context is set'
    assert_equal 'pg.query', db_span.name
  end

  def test_formatter_records_orig_name_on_rename
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ctx) { "#{ctx[:model_name]}.load" if ctx[:model_name] }
    end

    AR_CTX.stub_context(model_name: 'User', method_name: 'find', scope_name: nil, query_count: nil, async: false)
    processor = CCP.new(app_root: APP_ROOT)
    db_span   = build_named_span('SELECT `users`', 'db.system' => 'mysql2')
    processor.on_start(db_span, nil)

    assert_equal 'User.load',        db_span.name
    assert_equal 'SELECT `users`',   db_span.attributes[CCP::ORIG_NAME_ATTR]
  end

  # ── 2. RequestContext propagation ────────────────────────────────────────────

  def test_controller_and_action_propagate_to_child_span
    REQ_CTX.set(controller: 'PostsController', action: 'index')
    span = FakeSpan.new
    CCP.new(app_root: APP_ROOT).on_start(span, nil)

    assert_equal 'PostsController', span.attributes[CCP::SPAN_CONTROLLER_ATTR]
    assert_equal 'index',           span.attributes[CCP::SPAN_ACTION_ATTR]
  end

  def test_job_class_propagates_to_child_span
    REQ_CTX.set_job(job_class: 'ReportJob')
    span = FakeSpan.new
    CCP.new(app_root: APP_ROOT).on_start(span, nil)

    assert_equal 'ReportJob', span.attributes[CCP::SPAN_JOB_ATTR]
    refute span.attributes.key?(CCP::SPAN_CONTROLLER_ATTR)
  end

  def test_cleared_request_context_not_propagated
    REQ_CTX.set(controller: 'PostsController', action: 'index')
    REQ_CTX.clear!

    span = FakeSpan.new
    CCP.new(app_root: APP_ROOT).on_start(span, nil)

    refute span.attributes.key?(CCP::SPAN_CONTROLLER_ATTR)
    refute span.attributes.key?(CCP::SPAN_ACTION_ATTR)
  end

  def test_controller_takes_precedence_over_job
    REQ_CTX.set(controller: 'OrdersController', action: 'create')
    REQ_CTX.set_job(job_class: 'SomeJob')

    span = FakeSpan.new
    CCP.new(app_root: APP_ROOT).on_start(span, nil)

    assert_equal 'OrdersController', span.attributes[CCP::SPAN_CONTROLLER_ATTR]
    refute span.attributes.key?(CCP::SPAN_JOB_ATTR),
           'controller context wins over job context'
  ensure
    REQ_CTX.clear_job!
  end

  # ── 3. Slow query threshold ───────────────────────────────────────────────────
  # on_finish writes db.slow via @attributes direct mutation — span.set_attribute
  # is a no-op after a span has finished.

  def test_slow_span_gets_db_slow_true
    RailsOtelContext.configure { |c| c.slow_query_threshold_ms = 100 }
    processor = CCP.new(app_root: APP_ROOT)
    span      = db_span_with_duration_ms(200)

    processor.on_finish(span)

    assert_equal true, span.attributes[AR_CTX::DB_SLOW_ATTR]
  end

  def test_fast_span_does_not_get_db_slow
    RailsOtelContext.configure { |c| c.slow_query_threshold_ms = 100 }
    processor = CCP.new(app_root: APP_ROOT)
    span      = db_span_with_duration_ms(50)

    processor.on_finish(span)

    refute span.attributes.key?(AR_CTX::DB_SLOW_ATTR)
  end

  def test_slow_query_not_set_on_non_db_span
    RailsOtelContext.configure { |c| c.slow_query_threshold_ms = 1 }
    processor = CCP.new(app_root: APP_ROOT)

    span = FakeSpan.new(start_timestamp: 0, end_timestamp: 200_000_000)
    processor.on_finish(span) # no db.system attribute

    refute span.attributes.key?(AR_CTX::DB_SLOW_ATTR)
  end

  def test_slow_query_threshold_nil_skips_check
    RailsOtelContext.configure { |c| c.slow_query_threshold_ms = nil }
    processor = CCP.new(app_root: APP_ROOT)
    span      = db_span_with_duration_ms(999)

    processor.on_finish(span)

    refute span.attributes.key?(AR_CTX::DB_SLOW_ATTR)
  end

  # ── 4. ConnectionPool checkout span ─────────────────────────────────────────
  # Verifies the patch intercepts checkout, calls stat after getting the connection,
  # and records pool metrics on the span yielded by in_span.

  def test_connection_pool_checkout_records_pool_stats
    return skip 'AR::ConnectionPool not defined' unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool)

    fake_pool_class = Class.new do
      def checkout(_timeout = nil) = :the_connection
      def stat = { size: 5, busy: 2, idle: 3, waiting: 0 }
    end

    # Reset the memoized patch so the in_span lambda captures our fake tracer.
    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
    patch = RailsOtelContext::Adapters::ConnectionPool.send(:build_patch_module)

    captured_span = nil
    fake_tracer = Object.new
    fake_tracer.define_singleton_method(:in_span) do |name, &block|
      span      = FakeSpan.new
      span.name = name
      captured_span = span
      block.call(span)
    end

    with_stubbed_tracer_provider(fake_tracer) do
      fake_pool_class.prepend(patch)
      result = fake_pool_class.new.checkout
      assert_equal :the_connection, result, 'checkout must return the underlying connection'
    end

    refute_nil captured_span, 'checkout must create a span via the tracer'
    assert_equal 'active_record.connection_checkout', captured_span.name
    assert_equal 5, captured_span.attributes['db.pool.size']
    assert_equal 2, captured_span.attributes['db.pool.busy']
    assert_equal 3, captured_span.attributes['db.pool.idle']
    assert_equal 0, captured_span.attributes['db.pool.waiting']
  ensure
    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
  end

  private

  def build_named_span(name, attrs = {})
    span = FakeSpan.new
    span.name = name
    attrs.each { |k, v| span.set_attribute(k, v) }
    span
  end

  def db_span_with_duration_ms(duration_ms)
    span = FakeSpan.new(
      start_timestamp: 0,
      end_timestamp: duration_ms * 1_000_000
    )
    span.set_attribute('db.system', 'postgresql')
    span
  end

  def with_stubbed_tracer_provider(fake_tracer)
    fake_provider = Object.new
    fake_provider.define_singleton_method(:tracer) { |_name| fake_tracer }

    original = OpenTelemetry.tracer_provider
    OpenTelemetry.tracer_provider = fake_provider
    yield
  ensure
    OpenTelemetry.tracer_provider = original
  end
end
