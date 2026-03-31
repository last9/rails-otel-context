# frozen_string_literal: true

require_relative 'test_helper'

class ActiveRecordContextTest < Minitest::Test
  include SpanHelpers

  def setup
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def teardown
    RailsOtelContext::ActiveRecordContext.clear!
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = nil
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

  def test_returns_nil_for_single_word
    assert_nil RailsOtelContext::ActiveRecordContext.parse_ar_name('SCHEMA')
  end

  def test_parse_preserves_method_name_with_spaces
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Exists? (or not)')
    assert_equal 'User', r[:model_name]
    assert_equal 'Exists? (or not)', r[:method_name]
  end

  def test_parses_pluck
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Pluck')
    assert_equal 'User', r[:model_name]
    assert_equal 'Pluck', r[:method_name]
  end

  def test_parses_ids
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Ids')
    assert_equal 'User', r[:model_name]
    assert_equal 'Ids', r[:method_name]
  end

  # Rails fires "User Destroy All" for destroy_all — multi-word method name preserved
  def test_parses_destroy_all
    r = RailsOtelContext::ActiveRecordContext.parse_ar_name('User Destroy All')
    assert_equal 'User', r[:model_name]
    assert_equal 'Destroy All', r[:method_name]
  end

  # find_each / find_in_batches: scope ivar lives on the Relation, exec_queries
  # wraps each batch call so scope_name is captured per batch — no gap here.
  def test_scope_thread_key_is_set_during_exec_queries_and_cleared_after
    captured_scope = nil
    relation_class = Class.new do
      prepend RailsOtelContext::ActiveRecordContext::RelationScopeCapture
      define_method(:exec_queries) { captured_scope = Thread.current[:_rails_otel_ctx_scope] }
    end
    relation = relation_class.new
    relation.instance_variable_set(:@_otel_scope_name, 'recent')
    relation.exec_queries
    assert_equal 'recent', captured_scope
    assert_nil Thread.current[:_rails_otel_ctx_scope]
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

  def test_subscriber_skips_sql_when_no_model_found
    # name="SQL" with no sql payload and empty table map → context stays nil
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'SQL' })
    assert_nil RailsOtelContext::ActiveRecordContext.current
  end

  def test_subscriber_nil_name_with_sql_sets_context
    # connection.execute fires payload[:name] = nil — treat same as "SQL"
    with_ar_table_map('users' => 'User') do
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: nil, sql: "SELECT COUNT(*) FROM users WHERE role = 'admin'" })
      ctx = RailsOtelContext::ActiveRecordContext.current
      assert_equal 'User',   ctx[:model_name]
      assert_equal 'Select', ctx[:method_name]
    end
  end

  def test_subscriber_nil_name_no_sql_skips_context
    # nil name with nil sql payload → parse_sql_context returns nil → no context set
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: nil })
    assert_nil RailsOtelContext::ActiveRecordContext.current
  end

  def test_subscriber_finish_clears_thread_key
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'User Load' })
    assert_equal 'User', RailsOtelContext::ActiveRecordContext.current[:model_name]

    sub.finish('sql.active_record', '1', {})
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

  def test_apply_to_span_sets_query_count
    span = FakeSpan.new(valid_context: true)
    ctx = { model_name: 'User', method_name: 'Load', query_count: 5 }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 5, span.attributes['db.query_count']
  end

  def test_apply_to_span_no_query_count_when_absent
    span = FakeSpan.new(valid_context: true)
    ctx = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    refute span.attributes.key?('db.query_count')
  end

  def test_apply_to_span_formatter_returning_nil_skips_rename
    formatter = ->(_orig, _ar) {}
    RailsOtelContext.configure { |c| c.span_name_formatter = formatter }

    span = FakeSpan.new(valid_context: true)
    span.name = 'trilogy.query'
    ctx = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 'trilogy.query', span.name
    refute span.attributes.key?('l9.orig.name')
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_apply_to_span_formatter_returning_same_name_skips_orig
    RailsOtelContext.configure { |c| c.span_name_formatter = ->(_orig, _ar) { 'trilogy.query' } }

    span = FakeSpan.new(valid_context: true)
    span.name = 'trilogy.query'
    ctx = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    refute span.attributes.key?('l9.orig.name'),
           'l9.orig.name should not be set when formatter returns the same name'
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_apply_to_span_formatter_exception_rescued_attributes_still_set
    RailsOtelContext.configure { |c| c.span_name_formatter = ->(_orig, _ar) { raise 'boom' } }

    span = FakeSpan.new(valid_context: true)
    ctx = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, ctx)

    assert_equal 'User', span.attributes['code.activerecord.model']
  ensure
    RailsOtelContext.reset_configuration!
  end

  # ScopeNameTracking — wraps the `scope` macro to tag returned relations
  #
  # In production, AR's `scope` lives in an included ClassMethods module so it's
  # reachable via `super` from ScopeNameTracking. Replicating that here: the base
  # `scope` must be in an *extended module* (not a direct singleton method) so that
  # ScopeNameTracking — extended after — takes precedence in the lookup chain.

  def build_scope_tracking_class
    base = Module.new do
      def scope(name, body)
        define_singleton_method(name, &body)
      end
    end
    Class.new do
      extend base
      extend RailsOtelContext::ActiveRecordContext::ScopeNameTracking
    end
  end
  private :build_scope_tracking_class

  def test_scope_name_tracking_tags_relation_with_scope_name
    model_class = build_scope_tracking_class
    model_class.scope(:active, -> { FakeRelation.new })
    result = model_class.active
    assert_equal 'active', result.instance_variable_get(:@_otel_scope_name)
  end

  def test_scope_name_tracking_no_tag_when_body_returns_non_relation
    model_class = build_scope_tracking_class
    model_class.scope(:count_all, -> { 42 })
    result = model_class.count_all
    assert_equal 42, result
  end

  def test_scope_name_tracking_no_double_wrap
    model_class = build_scope_tracking_class
    relation = FakeRelation.new
    model_class.scope(:active, -> { relation })
    model_class.scope(:active, -> { relation }) # second call — guard prevents double-wrap

    # Should not raise; calling active must still return the relation
    result = model_class.active
    assert_kind_of ActiveRecord::Relation, result
  end

  # RelationScopeCapture — pushes scope name to thread-local during exec_queries

  def test_relation_scope_capture_sets_scope_thread_key_during_exec_queries
    captured_scope = nil

    klass = Class.new(ActiveRecord::Relation) do
      prepend RailsOtelContext::ActiveRecordContext::RelationScopeCapture

      define_method(:exec_queries) do
        captured_scope = Thread.current[:_rails_otel_ctx_scope]
      end
    end

    instance = klass.new
    instance.instance_variable_set(:@_otel_scope_name, 'recent_completed')
    instance.exec_queries

    assert_equal 'recent_completed', captured_scope
  end

  def test_relation_scope_capture_clears_scope_thread_key_after_exec_queries
    klass = Class.new(ActiveRecord::Relation) do
      prepend RailsOtelContext::ActiveRecordContext::RelationScopeCapture

      define_method(:exec_queries) { nil }
    end

    instance = klass.new
    instance.instance_variable_set(:@_otel_scope_name, 'active')
    instance.exec_queries

    assert_nil Thread.current[:_rails_otel_ctx_scope]
  end

  def test_relation_scope_capture_clears_scope_thread_key_on_exception
    klass = Class.new(ActiveRecord::Relation) do
      prepend RailsOtelContext::ActiveRecordContext::RelationScopeCapture

      define_method(:exec_queries) { raise 'db error' }
    end

    instance = klass.new
    instance.instance_variable_set(:@_otel_scope_name, 'active')
    assert_raises(RuntimeError) { instance.exec_queries }

    assert_nil Thread.current[:_rails_otel_ctx_scope],
               'scope thread-local must be cleared even when exec_queries raises'
  end

  def test_relation_scope_capture_skips_when_no_scope_name
    klass = Class.new(ActiveRecord::Relation) do
      prepend RailsOtelContext::ActiveRecordContext::RelationScopeCapture

      define_method(:exec_queries) { nil }
    end

    instance = klass.new
    # No @_otel_scope_name set
    instance.exec_queries

    assert_nil Thread.current[:_rails_otel_ctx_scope]
  end

  # ClassMethodScopeTracking

  def test_class_method_returning_relation_sets_scope_name
    app_root = File.expand_path('..', __dir__)
    RailsOtelContext::ActiveRecordContext.install!(app_root: app_root)

    model_class = Class.new do
      extend RailsOtelContext::ActiveRecordContext::ClassMethodScopeTracking

      def self.active
        FakeRelation.new
      end
    end

    result = model_class.active
    assert_equal 'active', result.otel_scope_name
  end

  def test_class_method_not_returning_relation_skips_scope_name
    app_root = File.expand_path('..', __dir__)
    RailsOtelContext::ActiveRecordContext.install!(app_root: app_root)

    model_class = Class.new do
      extend RailsOtelContext::ActiveRecordContext::ClassMethodScopeTracking

      def self.count
        42
      end
    end

    result = model_class.count
    assert_equal 42, result
  end

  def test_class_method_outside_app_root_not_tracked
    # Source file not under app_root → method not wrapped, no scope name set
    RailsOtelContext::ActiveRecordContext.install!(app_root: '/some/other/root')

    model_class = Class.new do
      extend RailsOtelContext::ActiveRecordContext::ClassMethodScopeTracking

      def self.active
        FakeRelation.new
      end
    end

    result = model_class.active
    assert_nil result.instance_variable_get(:@_otel_scope_name)
  end

  def test_class_method_scope_end_to_end_via_subscriber
    app_root = File.expand_path('..', __dir__)
    RailsOtelContext::ActiveRecordContext.install!(app_root: app_root)

    model_class = Class.new do
      extend RailsOtelContext::ActiveRecordContext::ClassMethodScopeTracking

      def self.active
        FakeRelation.new
      end
    end

    # Simulate what RelationScopeCapture does: push scope to thread-local before exec_queries
    relation = model_class.active
    scope_name = relation.instance_variable_get(:@_otel_scope_name)
    Thread.current[:_rails_otel_ctx_scope] = scope_name

    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'Widget Load' })

    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_equal 'Widget', ctx[:model_name]
    assert_equal 'active', ctx[:scope_name]
  ensure
    Thread.current[:_rails_otel_ctx_scope] = nil
    RailsOtelContext::ActiveRecordContext.clear!
  end

  # N+1 detection

  def test_query_count_increments_for_repeated_queries
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'User Load' })
    assert_nil RailsOtelContext::ActiveRecordContext.current[:query_count],
               'first query should not set query_count'
    RailsOtelContext::ActiveRecordContext.clear!

    sub.start('sql.active_record', '2', { name: 'User Load' })
    assert_equal 2, RailsOtelContext::ActiveRecordContext.current[:query_count]
  end

  def test_query_count_independent_per_model_method
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'User Load' })
    sub.start('sql.active_record', '2', { name: 'Order Load' })

    # Order Load is a different key — should still be first occurrence
    ctx = RailsOtelContext::ActiveRecordContext.current
    assert_nil ctx[:query_count],
               'different model/method pair should not trigger N+1 flag'
  end

  def test_query_count_reset_on_request_context_set
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 5 }
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'index')
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  ensure
    RailsOtelContext::RequestContext.clear!
  end

  def test_query_count_set_on_span_when_repeated
    with_current_span(FakeSpan.new(valid_context: true)) do |span|
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'User Load' })
      RailsOtelContext::ActiveRecordContext.clear!
      sub.start('sql.active_record', '2', { name: 'User Load' })

      assert_equal 2, span.attributes['db.query_count']
    end
  end

  def test_query_count_not_set_on_span_for_first_occurrence
    with_current_span(FakeSpan.new(valid_context: true)) do |span|
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', { name: 'User Load' })

      refute span.attributes.key?('db.query_count'),
             'first occurrence should not carry db.query_count'
    end
  end

  def test_query_count_reaches_nth_on_nth_occurrence
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new

    sub.start('sql.active_record', '1', { name: 'Order Load' })
    RailsOtelContext::ActiveRecordContext.clear!
    sub.start('sql.active_record', '2', { name: 'Order Load' })
    RailsOtelContext::ActiveRecordContext.clear!
    sub.start('sql.active_record', '3', { name: 'Order Load' })

    assert_equal 3, RailsOtelContext::ActiveRecordContext.current[:query_count]
  end

  # Slow query detection


  # parse_sql_context — SQL table-name parsing for name="SQL" notifications
  # (counter caches, touch_later, connection.execute)

  def test_parse_sql_context_update
    with_ar_table_map('users' => 'User') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('UPDATE `users` SET `comments_count` = 5')
      assert_equal 'User',   ctx[:model_name]
      assert_equal 'Update', ctx[:method_name]
    end
  end

  def test_parse_sql_context_insert
    with_ar_table_map('orders' => 'Order') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('INSERT INTO `orders` (`state`) VALUES (?)')
      assert_equal 'Order',  ctx[:model_name]
      assert_equal 'Insert', ctx[:method_name]
    end
  end

  def test_parse_sql_context_insert_ignore
    with_ar_table_map('events' => 'Event') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('INSERT IGNORE INTO `events` (`name`) VALUES (?)')
      assert_equal 'Event',  ctx[:model_name]
      assert_equal 'Insert', ctx[:method_name]
    end
  end

  def test_parse_sql_context_delete
    with_ar_table_map('sessions' => 'Session') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('DELETE FROM `sessions` WHERE id = 1')
      assert_equal 'Session', ctx[:model_name]
      assert_equal 'Delete',  ctx[:method_name]
    end
  end

  def test_parse_sql_context_select
    with_ar_table_map('products' => 'Product') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('SELECT * FROM `products` WHERE active = 1')
      assert_equal 'Product', ctx[:model_name]
      assert_equal 'Select',  ctx[:method_name]
    end
  end

  def test_parse_sql_context_falls_back_to_sql_for_unknown_table
    # Table not in AR model map → falls back to virtual "SQL" model for tab grouping
    with_ar_table_map('users' => 'User') do
      ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('UPDATE `widgets` SET x = 1')
      assert_equal 'SQL',    ctx[:model_name]
      assert_equal 'Update', ctx[:method_name]
      assert_equal 'SQL.Update', ctx[:query_key]
    end
  end

  def test_parse_sql_context_falls_back_to_sql_for_no_table_clause
    # SQL with no extractable table (e.g. SELECT SLEEP) → "SQL.Select" grouping
    ctx = RailsOtelContext::ActiveRecordContext.parse_sql_context('SELECT SLEEP(0.2)')
    assert_equal 'SQL',    ctx[:model_name]
    assert_equal 'Select', ctx[:method_name]
    assert_equal 'SQL.Select', ctx[:query_key]
  end

  def test_parse_sql_context_returns_nil_for_nil_sql
    assert_nil RailsOtelContext::ActiveRecordContext.parse_sql_context(nil)
  end

  def test_parse_sql_context_returns_nil_for_unsupported_verb
    with_ar_table_map('users' => 'User') do
      assert_nil RailsOtelContext::ActiveRecordContext.parse_sql_context('BEGIN')
    end
  end

  def test_subscriber_sets_async_flag_when_payload_async_true
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'User Load', async: true })
    assert RailsOtelContext::ActiveRecordContext.current[:async],
           'async payload flag must be captured in AR context'
  end

  def test_subscriber_no_async_flag_when_payload_async_absent
    sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
    sub.start('sql.active_record', '1', { name: 'User Load' })
    refute RailsOtelContext::ActiveRecordContext.current[:async]
  end

  def test_apply_to_span_sets_db_async_when_flagged
    span = FakeSpan.new(valid_context: true)
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, { model_name: 'User', method_name: 'Load', async: true })
    assert span.attributes['db.async']
  end

  def test_apply_to_span_no_db_async_when_not_flagged
    span = FakeSpan.new(valid_context: true)
    RailsOtelContext::ActiveRecordContext.apply_to_span(span, { model_name: 'User', method_name: 'Load' })
    refute span.attributes.key?('db.async')
  end

  def test_ar_table_model_map_skips_sti_subclasses
    # STI: AdminUser shares users table with User.
    # Map must resolve to the base class, not the last-iterated subclass.
    # base_class == self  → included; base_class != self → skipped.
    base = Struct.new(:name) do
      def self.name = 'User'
      def self.table_name = 'users'
      def self.base_class = self
    end
    sub = Struct.new(:name) do
      def self.name = 'AdminUser'
      def self.table_name = 'users'
      def self.base_class = base
    end
    sub.singleton_class.define_method(:base_class) { base }

    allow_real_descendants([base, sub]) do
      map = RailsOtelContext::ActiveRecordContext.ar_table_model_map
      assert_equal 'User', map['users'],
                   'STI subclass must not overwrite base class in table map'
    end
  end

  def test_subscriber_enriches_sql_named_span_when_model_found
    with_ar_table_map('users' => 'User') do
      with_current_span(FakeSpan.new(valid_context: true)) do |span|
        sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
        sub.start('sql.active_record', '1', {
                    name: 'SQL',
                    sql: 'UPDATE `users` SET `comments_count` = COALESCE(`comments_count`, 0) + 1'
                  })
        assert_equal 'User',   span.attributes['code.activerecord.model']
        assert_equal 'Update', span.attributes['code.activerecord.method']
      end
    end
  end

  def test_subscriber_sql_named_span_falls_back_to_sql_model_when_not_found
    # Unknown table → falls back to virtual "SQL" model instead of skipping
    with_ar_table_map('users' => 'User') do
      sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
      sub.start('sql.active_record', '1', {
                  name: 'SQL',
                  sql: 'UPDATE `unknown_table` SET x = 1'
                })
      ctx = RailsOtelContext::ActiveRecordContext.current
      assert_equal 'SQL',    ctx[:model_name]
      assert_equal 'Update', ctx[:method_name]
    end
  end

  def test_subscriber_sql_named_span_applies_formatter
    RailsOtelContext.configure do |c|
      c.span_name_formatter = lambda { |_orig, ar|
        "#{ar[:model_name]}.#{ar[:method_name]}"
      }
    end
    with_ar_table_map('posts' => 'Post') do
      with_current_span(FakeSpan.new(valid_context: true)) do |span|
        span.name = 'trilogy.query'
        sub = RailsOtelContext::ActiveRecordContext::Subscriber.new
        sub.start('sql.active_record', '1', { name: 'SQL', sql: 'UPDATE `posts` SET views = 1' })
        assert_equal 'Post.Update', span.name
      end
    end
  ensure
    RailsOtelContext.reset_configuration!
  end

  private

  def with_ar_table_map(map)
    RailsOtelContext::ActiveRecordContext.instance_variable_set(:@ar_table_model_map, map)
    yield
  ensure
    RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
  end

  # Temporarily replaces AR::Base.descendants with a controlled list so
  # ar_table_model_map builds from exactly those classes, then resets the cache.
  def allow_real_descendants(list)
    # Ensure AR::Base exists (test env may only have AR::Relation)
    unless defined?(ActiveRecord::Base)
      ActiveRecord.const_set(:Base, Class.new)
    end
    orig_method = begin
      ActiveRecord::Base.singleton_class.instance_method(:descendants)
    rescue StandardError
      nil
    end
    ActiveRecord::Base.define_singleton_method(:descendants) { list }
    RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
    yield
  ensure
    if orig_method
      ActiveRecord::Base.singleton_class.define_method(:descendants, orig_method)
    else
      begin
        ActiveRecord::Base.singleton_class.remove_method(:descendants)
      rescue StandardError
        nil
      end
    end
    RailsOtelContext::ActiveRecordContext.reset_ar_table_model_map!
  end
end
