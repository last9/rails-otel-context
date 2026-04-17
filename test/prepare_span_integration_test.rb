# frozen_string_literal: true

require_relative 'test_helper'

# End-to-end integration test for the PREPARE span retroactive enrichment flow.
#
# PG's prepared-statement wire protocol sends PREPARE and EXECUTE as two separate
# round-trips. The PREPARE span finishes before sql.active_record fires, so
# CallContextProcessor#on_finish stashes it. When the notification fires,
# Subscriber#start retroactively applies AR context to all stashed spans.
#
# This test exercises the full stash → enrich → rename path without any external
# database — using FakeSpan and the public module APIs.
class PrepareSpanIntegrationTest < Minitest::Test
  APP_ROOT = Dir.pwd

  def setup
    RailsOtelContext.reset_configuration!
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = nil
  end

  def teardown
    RailsOtelContext.reset_configuration!
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = nil
  end

  # Full flow: on_finish stashes PREPARE span → retroactively_apply enriches it.
  def test_prepare_span_gets_enriched_after_notification
    processor = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)
    prepare_span = build_prepare_span

    # on_finish detects db.operation == 'PREPARE' with no AR model → stashes it
    processor.on_finish(prepare_span)

    pending = Thread.current[:_rails_otel_ctx_pending_prepare_spans]
    assert_equal [prepare_span], pending, 'PREPARE span must be stashed by on_finish'

    # Simulate Subscriber#start enriching and flushing stashed spans
    ctx = { model_name: 'User', method_name: 'find', scope_name: nil }
    pending.each { |s| RailsOtelContext::ActiveRecordContext.retroactively_apply_to_span(s, ctx) }
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = nil

    assert_equal 'User', prepare_span.attributes[RailsOtelContext::CallContextProcessor::AR_MODEL_ATTR]
    assert_equal 'find', prepare_span.attributes[RailsOtelContext::CallContextProcessor::AR_METHOD_ATTR]
  end

  # PREPARE span that already has AR model (e.g. enriched by another path) is not stashed.
  def test_prepare_span_with_existing_ar_model_is_not_stashed
    processor    = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)
    prepare_span = build_prepare_span
    prepare_span.set_attribute(RailsOtelContext::CallContextProcessor::AR_MODEL_ATTR, 'AlreadySet')

    processor.on_finish(prepare_span)

    pending = Thread.current[:_rails_otel_ctx_pending_prepare_spans]
    assert_nil pending, 'Span already bearing AR model must not be stashed again'
  end

  # Non-PREPARE spans (SELECT, INSERT, etc.) are not stashed regardless of missing AR model.
  def test_non_prepare_span_is_not_stashed
    processor = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)
    select_span = FakeSpan.new
    select_span.set_attribute('db.system',    'postgresql')
    select_span.set_attribute('db.operation', 'SELECT')

    processor.on_finish(select_span)

    pending = Thread.current[:_rails_otel_ctx_pending_prepare_spans]
    assert_nil pending
  end

  # Multiple PREPARE spans in one request are all enriched and flushed.
  def test_multiple_prepare_spans_all_get_enriched
    processor = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)
    spans     = Array.new(3) { build_prepare_span }

    spans.each { |s| processor.on_finish(s) }

    pending = Thread.current[:_rails_otel_ctx_pending_prepare_spans]
    assert_equal 3, pending.size

    ctx = { model_name: 'Order', method_name: 'create', scope_name: nil }
    pending.each { |s| RailsOtelContext::ActiveRecordContext.retroactively_apply_to_span(s, ctx) }
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = nil

    spans.each do |s|
      assert_equal 'Order', s.attributes[RailsOtelContext::CallContextProcessor::AR_MODEL_ATTR]
    end
  end

  # span_name_formatter renames the PREPARE span retroactively.
  def test_prepare_span_is_renamed_by_formatter_after_enrichment
    RailsOtelContext.configure do |c|
      c.span_name_formatter = lambda { |_original, ctx|
        next unless ctx[:model_name]

        "#{ctx[:model_name]}.#{ctx[:method_name]}"
      }
    end

    processor    = RailsOtelContext::CallContextProcessor.new(app_root: APP_ROOT)
    prepare_span = build_prepare_span
    processor.on_finish(prepare_span)

    ctx = { model_name: 'Post', method_name: 'recent', scope_name: nil }
    pending = Thread.current[:_rails_otel_ctx_pending_prepare_spans]
    pending&.each { |s| RailsOtelContext::ActiveRecordContext.retroactively_apply_to_span(s, ctx) }
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = nil

    assert_equal 'Post.recent', prepare_span.name
    assert_equal 'PREPARE posts',
                 prepare_span.attributes[RailsOtelContext::CallContextProcessor::ORIG_NAME_ATTR]
  end

  # Subscriber#finish clears any leftover stashed PREPARE spans (e.g. when
  # sql.active_record#start never fired — DDL, connection errors, etc.)
  def test_subscriber_finish_clears_leftover_prepare_spans
    spans = [build_prepare_span, build_prepare_span]
    Thread.current[:_rails_otel_ctx_pending_prepare_spans] = spans

    subscriber = RailsOtelContext::ActiveRecordContext::Subscriber.new
    subscriber.finish('sql.active_record', nil, {})

    assert_nil Thread.current[:_rails_otel_ctx_pending_prepare_spans]
  end

  private

  def build_prepare_span(table: 'posts')
    span = FakeSpan.new
    span.name = "PREPARE #{table}"
    span.set_attribute('db.system',    'postgresql')
    span.set_attribute('db.operation', 'PREPARE')
    span
  end
end
