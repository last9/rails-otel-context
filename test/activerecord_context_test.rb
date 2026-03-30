# frozen_string_literal: true

require_relative 'test_helper'

class ActiveRecordContextTest < Minitest::Test
  include SpanHelpers

  def setup
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def teardown
    RailsOtelContext::ActiveRecordContext.clear!
  end

  # parse_ar_name

  def test_parses_model_load
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('Transaction Load')
    assert_equal 'Transaction', r[:model_name]
    assert_equal 'Load', r[:method_name]
  end

  def test_parses_model_count
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Count')
    assert_equal 'User', r[:model_name]
    assert_equal 'Count', r[:method_name]
  end

  def test_parses_model_create
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('Order Create')
    assert_equal 'Order', r[:model_name]
  end

  def test_parses_model_exists
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Exists?')
    assert_equal 'Exists?', r[:method_name]
  end

  def test_returns_nil_for_schema
    assert_nil RailsOtelContext::ActiveRecordContext.parse_ar_name('SCHEMA')
  end

  def test_returns_nil_for_nil
    assert_nil RailsOtelContext::ActiveRecordContext.parse_ar_name(nil)
  end

  def test_returns_nil_for_activerecord_internal
    assert_nil RailsOtelContext::ActiveRecordContext.parse_ar_name('ActiveRecord Internals')
  end

  # Subscriber lifecycle

  def test_subscriber_sets_and_clears_context
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Transaction Load' })
    assert_equal 'Transaction', RailsOtelContext::ActiveRecordContext.current[:model_name]

    sub.finish('sql.active_record', '1', {})
    assert_nil RailsOtelContext::ActiveRecordContext.current
  end

  def test_subscriber_skips_schema
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'SCHEMA' })
    assert_nil RailsOtelContext::ActiveRecordContext.current
  end

  def test_subscriber_skips_cache
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'CACHE User Load' })
    assert_nil RailsOtelContext::ActiveRecordContext.current
  end

  # Scope tracking via thread-local

  def test_subscriber_includes_scope_name_from_thread_local
    RailsOtelContext::ActiveRecordContext.stub_scope('recent_completed')
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Transaction Load' })

    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_equal 'Transaction', ctx[:model_name]
    assert_equal 'Load', ctx[:method_name]
    assert_equal 'recent_completed', ctx[:scope_name]
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_subscriber_no_scope_when_thread_local_empty
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Transaction Load' })

    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_nil ctx[:scope_name]
  end

  # Issue reproduction: driver-patch instrumentation timing bug
  #
  # OTel's Trilogy/PG instrumentation patches the driver directly via Module#prepend.
  # This means the OTel span is created BEFORE sql.active_record fires:
  #
  #   Trilogy#query called
  #     → OTel creates span → on_start runs → AR context nil → no AR attributes ← BUG
  #     → SQL executes
  #     → sql.active_record notification fires → subscriber enriches span directly ← FIX
  #     → OTel finishes span
  #
  # Without the fix, code.activerecord.model is absent from all Trilogy/PG spans.

  def test_driver_patch_timing_ar_attributes_present_after_on_start_saw_nil_context
    processor = RailsOtelContext::CallContextProcessor.new(app_root: '/myapp')
    RailsOtelContext::ActiveRecordContext.clear!

    with_current_span(FakeSpan.new(valid_context: true)) do |span|
      # Step 1: OTel creates span; on_start fires. AR context not set yet.
      processor.on_start(span, nil)
      refute span.attributes.key?('code.activerecord.model'),
             'pre-condition: no AR context at on_start time'

      # Step 2: sql.active_record notification fires; subscriber enriches span directly.
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'Transaction Load' })

      # AR attributes are now present even though on_start missed them.
      assert_equal 'Transaction', span.attributes['code.activerecord.model']
      assert_equal 'Load', span.attributes['code.activerecord.method']
    end
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  # Direct span enrichment (driver-patch instrumentation timing fix)

  def test_subscriber_enriches_current_span_directly
    # Simulates Trilogy/PG driver-patch instrumentation: span exists before notification fires
    with_current_span(FakeSpan.new(valid_context: true)) do |span|
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'Transaction Load' })

      assert_equal 'Transaction', span.attributes['code.activerecord.model']
      assert_equal 'Load', span.attributes['code.activerecord.method']
    end
  end

  def test_subscriber_skips_span_enrichment_when_no_active_span
    # Simulates notification-based instrumentation where subscriber fires before span is created.
    # OpenTelemetry::Trace.current_span returns a no-op span with invalid context in that case.
    with_current_span(FakeSpan.new(valid_context: false)) do |span|
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'Transaction Load' })

      assert_empty span.attributes
      assert_equal 'Transaction', RailsOtelContext::ActiveRecordContext.current[:model_name],
                   'thread-local AR context must still be set even when span enrichment is skipped'
    end
  end

  def test_subscriber_enriches_scope_on_current_span
    RailsOtelContext::ActiveRecordContext.stub_scope('recent_completed')
    with_current_span(FakeSpan.new(valid_context: true)) do |span|
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'Transaction Load' })

      assert_equal 'Transaction', span.attributes['code.activerecord.model']
      assert_equal 'recent_completed', span.attributes['code.activerecord.scope']
    end
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  # apply_to_span

  def test_apply_to_span_sets_model_and_method
    span = FakeSpan.new(valid_context: true)
    ctx = { model_name: 'Order', method_name: 'Update' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 'Order', span.attributes['code.activerecord.model']
    assert_equal 'Update', span.attributes['code.activerecord.method']
    refute span.attributes.key?('code.activerecord.scope')
  end

  def test_apply_to_span_noop_on_invalid_context
    span = FakeSpan.new(valid_context: false)
    ctx = { model_name: 'Order', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_empty span.attributes
  end

  def test_apply_to_span_applies_formatter_and_preserves_original_name
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ar) { "#{ar[:model_name]}.#{ar[:method_name]}" }
    end

    span = FakeSpan.new(valid_context: true)
    span.name = 'trilogy.query'
    ctx = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 'User.Load', span.name
    assert_equal 'trilogy.query', span.attributes['l9.orig.name']
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_apply_to_span_reads_code_namespace_from_span_for_formatter
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ar) { "#{ar[:code_namespace]}##{ar[:model_name]}" }
    end

    span = FakeSpan.new(valid_context: true)
    span.attributes['code.namespace'] = 'OrdersController'
    ctx = { model_name: 'Order', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 'OrdersController#Order', span.name
  ensure
    RailsOtelContext.reset_configuration!
  end
end
