# frozen_string_literal: true

require_relative 'test_helper'

class ActiveRecordContextTest < Minitest::Test
  def setup
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def teardown
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
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
    Thread.current[RailsOtelContext::ActiveRecordContext::SCOPE_THREAD_KEY] = 'recent_completed'
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Transaction Load' })

    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_equal 'Transaction', ctx[:model_name]
    assert_equal 'Load', ctx[:method_name]
    assert_equal 'recent_completed', ctx[:scope_name]
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::SCOPE_THREAD_KEY] = nil
  end

  def test_subscriber_no_scope_when_thread_local_empty
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Transaction Load' })

    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_nil ctx[:scope_name]
  end

  # Legacy extract

  def test_extract_returns_current
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = { model_name: 'Order', method_name: 'Create' }
    ctx = RailsOtelContext::ActiveRecordContext.extract(app_root: '/app')
    assert_equal 'Order', ctx[:model_name]
  end
end
