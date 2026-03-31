# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class CallContextProcessorTest < Minitest::Test
  include CallerLocationHelpers

  def setup
    # Thread.each_caller_location requires Ruby >= 3.2 for call_context tests
    skip 'Requires Ruby >= 3.2' unless Thread.respond_to?(:each_caller_location)

    RailsOtelContext.reset_configuration!
    @app_root = '/myapp'
    @processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
  end

  def teardown
    RailsOtelContext::FrameContext.clear!
    RailsOtelContext.reset_configuration!
  end

  # ---------------------------------------------------------------------------
  # Label-based class + method extraction
  # ---------------------------------------------------------------------------

  def test_extracts_class_and_method_from_dot_label
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/models/user.rb", label: 'User.find') do
      @processor.on_start(span, nil)
    end
    assert_equal 'User', span.attributes['code.namespace']
    assert_equal 'find', span.attributes['code.function']
  end

  def test_extracts_class_and_method_from_hash_label
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'OrderService#create') do
      @processor.on_start(span, nil)
    end
    assert_equal 'OrderService', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
  end

  def test_handles_namespaced_class_in_label
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/services/billing/invoice_service.rb",
                         label: 'Billing::InvoiceService#charge') do
      @processor.on_start(span, nil)
    end
    assert_equal 'Billing::InvoiceService', span.attributes['code.namespace']
    assert_equal 'charge', span.attributes['code.function']
  end

  # ---------------------------------------------------------------------------
  # File-path-based class inference (label has no class prefix)
  # ---------------------------------------------------------------------------

  def test_infers_class_from_file_path_when_label_has_no_class
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: 'perform') do
      @processor.on_start(span, nil)
    end
    assert_equal 'InvoiceJob', span.attributes['code.namespace']
    assert_equal 'perform', span.attributes['code.function']
  end

  def test_infers_class_for_controller_action
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/controllers/products_controller.rb", label: 'index') do
      @processor.on_start(span, nil)
    end
    assert_equal 'ProductsController', span.attributes['code.namespace']
    assert_equal 'index', span.attributes['code.function']
  end

  # ---------------------------------------------------------------------------
  # Block / rescue label cleanup
  # ---------------------------------------------------------------------------

  def test_strips_block_in_prefix_from_method
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: 'block in perform') do
      @processor.on_start(span, nil)
    end
    assert_equal 'InvoiceJob', span.attributes['code.namespace']
    assert_equal 'perform', span.attributes['code.function']
  end

  def test_strips_rescue_in_prefix_from_method
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'rescue in create') do
      @processor.on_start(span, nil)
    end
    assert_equal 'OrderService', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
  end

  # ---------------------------------------------------------------------------
  # Frame filtering
  # ---------------------------------------------------------------------------

  def test_skips_gem_frames_and_uses_next_app_frame
    span = FakeSpan.new
    gem_location    = location("#{@app_root}/vendor/bundle/ruby/3.1.0/gems/sidekiq-7.0/lib/sidekiq.rb", 'call')
    app_location    = location("#{@app_root}/app/jobs/invoice_job.rb", 'perform')

    with_multiple_caller_locations([gem_location, app_location]) do
      @processor.on_start(span, nil)
    end
    assert_equal 'InvoiceJob', span.attributes['code.namespace']
  end

  def test_skips_frames_outside_app_root
    span = FakeSpan.new
    stdlib_location = location('/usr/local/lib/ruby/rack.rb', 'call')
    app_location    = location("#{@app_root}/app/services/order_service.rb", 'create')

    with_multiple_caller_locations([stdlib_location, app_location]) do
      @processor.on_start(span, nil)
    end
    assert_equal 'OrderService', span.attributes['code.namespace']
  end

  def test_sets_no_attributes_when_no_app_frame_found
    span = FakeSpan.new
    with_caller_location(path: '/usr/local/lib/ruby/rack.rb', label: 'call') do
      @processor.on_start(span, nil)
    end
    refute span.attributes.key?('code.namespace')
    refute span.attributes.key?('code.function')
  end

  # ---------------------------------------------------------------------------
  # code.lineno
  # ---------------------------------------------------------------------------

  def test_sets_code_lineno_and_filepath_from_label_pattern
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/models/user.rb", label: 'User.find', lineno: 42) do
      @processor.on_start(span, nil)
    end
    assert_equal 42, span.attributes['code.lineno']
    assert_equal 'app/models/user.rb', span.attributes['code.filepath']
  end

  def test_sets_code_lineno_and_filepath_from_file_path_fallback
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: 'perform', lineno: 17) do
      @processor.on_start(span, nil)
    end
    assert_equal 17, span.attributes['code.lineno']
    assert_equal 'app/jobs/invoice_job.rb', span.attributes['code.filepath']
  end

  def test_code_lineno_not_set_without_filepath_when_lineno_is_nil
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/models/user.rb", label: 'User.find', lineno: nil) do
      @processor.on_start(span, nil)
    end
    refute span.attributes.key?('code.lineno')
    refute span.attributes.key?('code.filepath')
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  def test_sets_no_attributes_when_each_caller_location_not_available
    span = FakeSpan.new
    original = Thread.method(:respond_to?)
    Thread.define_singleton_method(:respond_to?) { |m| m == :each_caller_location ? false : original.call(m) }
    @processor.on_start(span, nil)
    refute span.attributes.key?('code.namespace')
    refute span.attributes.key?('code.function')
  ensure
    Thread.singleton_class.send(:remove_method, :respond_to?)
    Thread.define_singleton_method(:respond_to?, original)
  end

  def test_strips_ensure_in_prefix_from_method
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'ensure in create') do
      @processor.on_start(span, nil)
    end
    assert_equal 'OrderService', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
  end

  def test_code_function_not_set_when_label_is_empty
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: '') do
      @processor.on_start(span, nil)
    end
    assert_equal 'InvoiceJob', span.attributes['code.namespace']
    refute span.attributes.key?('code.function')
  end

  def test_uses_path_when_absolute_path_is_nil
    span = FakeSpan.new
    loc  = OpenStruct.new(absolute_path: nil, path: "#{@app_root}/app/services/order_service.rb",
                          label: 'create', lineno: 5)
    with_multiple_caller_locations([loc]) { @processor.on_start(span, nil) }
    assert_equal 'OrderService', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
    assert_equal 5, span.attributes['code.lineno']
    assert_equal 'app/services/order_service.rb', span.attributes['code.filepath']
  end

  # ---------------------------------------------------------------------------
  # pushed frame fast path
  # ---------------------------------------------------------------------------

  def test_pushed_frame_sets_namespace_and_function
    span = FakeSpan.new
    RailsOtelContext::FrameContext.with_frame(class_name: 'PaymentsController', method_name: 'create') do
      @processor.on_start(span, nil)
    end
    assert_equal 'PaymentsController', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
  end

  def test_pushed_frame_beats_stack_walk
    span = FakeSpan.new
    # stack walk would return OrderService from the caller location
    RailsOtelContext::FrameContext.with_frame(class_name: 'PaymentsController', method_name: 'create') do
      with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'OrderService#call') do
        @processor.on_start(span, nil)
      end
    end
    # pushed frame wins
    assert_equal 'PaymentsController', span.attributes['code.namespace']
    assert_equal 'create', span.attributes['code.function']
  end

  def test_pushed_frame_does_not_set_lineno_or_filepath
    span = FakeSpan.new
    RailsOtelContext::FrameContext.with_frame(class_name: 'OrdersController', method_name: 'index') do
      @processor.on_start(span, nil)
    end
    refute span.attributes.key?('code.lineno')
    refute span.attributes.key?('code.filepath')
  end

  def test_stack_walk_used_when_no_frame_pushed
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'OrderService#call') do
      @processor.on_start(span, nil)
    end
    assert_equal 'OrderService', span.attributes['code.namespace']
    assert_equal 'call', span.attributes['code.function']
  end

  def test_pushed_frame_cleared_after_with_frame_block
    span_inside  = FakeSpan.new
    span_outside = FakeSpan.new

    RailsOtelContext::FrameContext.with_frame(class_name: 'Foo', method_name: 'bar') do
      @processor.on_start(span_inside, nil)
    end

    with_caller_location(path: "#{@app_root}/app/services/order_service.rb", label: 'OrderService#call') do
      @processor.on_start(span_outside, nil)
    end

    assert_equal 'Foo', span_inside.attributes['code.namespace']
    assert_equal 'OrderService', span_outside.attributes['code.namespace']
  end

  # ---------------------------------------------------------------------------
  # custom_span_attributes
  # ---------------------------------------------------------------------------

  def test_custom_attributes_applied_to_span
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { { 'team' => 'payments', 'domain' => 'checkout' } }
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    assert_equal 'payments', span.attributes['team']
    assert_equal 'checkout', span.attributes['domain']
  end

  def test_custom_attributes_nil_return_is_noop
    RailsOtelContext.configure { |c| c.custom_span_attributes = -> {} }
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    refute span.attributes.key?('team')
  end

  def test_custom_attributes_empty_hash_is_noop
    call_count = 0
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        call_count += 1
        {}
      }
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    assert_equal 1, call_count
    refute span.attributes.key?('team')
  end

  def test_custom_attributes_skips_nil_values
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { { 'team' => 'backend', 'domain' => nil } }
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    assert_equal 'backend', span.attributes['team']
    refute span.attributes.key?('domain')
  end

  def test_custom_attributes_exception_is_swallowed
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { raise 'boom' }
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    refute span.attributes.key?('team')
  end

  def test_custom_attributes_skipped_when_nil
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = nil
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    refute span.attributes.key?('team')
  end

  def test_custom_attributes_coexist_with_call_context
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { { 'team' => 'notifications' } }
    end
    proc = new_processor
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/models/user.rb", label: 'User.find') do
      proc.on_start(span, nil)
    end
    assert_equal 'User', span.attributes['code.namespace']
    assert_equal 'notifications', span.attributes['team']
  end

  def test_custom_attributes_non_callable_raises_argument_error
    assert_raises(ArgumentError) do
      RailsOtelContext.configure { |c| c.custom_span_attributes = { 'team' => 'x' } }
    end
  end

  def test_custom_attributes_nil_callable_is_valid
    RailsOtelContext.configure { |c| c.custom_span_attributes = nil }
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('team')
  end

  # ---------------------------------------------------------------------------
  # apply_db_context (AR model attributes, scope, formatter, l9.orig.name)
  # ---------------------------------------------------------------------------

  def test_db_context_sets_ar_model_and_method
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'User', method_name: 'Load' })
    span = FakeSpan.new
    @processor.on_start(span, nil)
    assert_equal 'User', span.attributes['code.activerecord.model']
    assert_equal 'Load', span.attributes['code.activerecord.method']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_sets_scope_name
    RailsOtelContext::ActiveRecordContext.stub_context(
      model_name: 'Transaction', method_name: 'Load', scope_name: 'recent_completed'
    )
    span = FakeSpan.new
    @processor.on_start(span, nil)
    assert_equal 'recent_completed', span.attributes['code.activerecord.scope']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_no_scope_when_absent
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'User', method_name: 'Count' })
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('code.activerecord.scope')
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_noop_when_no_ar_context
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('code.activerecord.model')
  end

  def test_db_context_formatter_renames_and_preserves_original
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'Order', method_name: 'Load' })
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ctx) { "#{ctx[:model_name]}.#{ctx[:method_name]}" }
    end
    proc = new_processor

    span = FakeSpan.new
    span.set_attribute('db.system', 'mysql2')
    span.define_singleton_method(:name) { @custom_name || 'select' }
    span.define_singleton_method(:name=) { |n| @custom_name = n }

    proc.on_start(span, nil)
    assert_equal 'Order.Load', span.name
    assert_equal 'select', span.attributes['l9.orig.name']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_formatter_receives_scope_and_code_context
    RailsOtelContext::ActiveRecordContext.stub_context(
      model_name: 'Transaction', method_name: 'Load', scope_name: 'recent_completed'
    )
    received_ctx = nil
    RailsOtelContext.configure do |c|
      c.span_name_formatter = lambda { |_orig, ctx|
        received_ctx = ctx
        'renamed'
      }
    end
    proc = new_processor

    span = FakeSpan.new
    span.set_attribute('db.system', 'mysql2')
    span.define_singleton_method(:name) { 'select' }
    span.define_singleton_method(:name=) { |n| @custom_name = n }

    proc.on_start(span, nil)

    assert_equal 'recent_completed', received_ctx[:scope_name]
    assert_equal 'Transaction', received_ctx[:model_name]
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_formatter_skips_non_db_spans
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'User', method_name: 'Load' })
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ctx) { "#{ctx[:model_name]}.#{ctx[:method_name]}" }
    end
    proc = new_processor

    # HTTP/controller span — no db.system attribute
    span = FakeSpan.new
    span.name = 'GET /users'
    proc.on_start(span, nil)
    assert_equal 'GET /users', span.name, 'formatter must not rename non-DB spans'
    assert_nil span.attributes['l9.orig.name']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_formatter_exception_swallowed
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'User', method_name: 'Load' })
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, _ctx) { raise 'boom' }
    end
    proc = new_processor

    span = FakeSpan.new
    proc.on_start(span, nil)
    # Should not raise, and AR attributes should still be set
    assert_equal 'User', span.attributes['code.activerecord.model']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_sets_query_count_when_repeated
    RailsOtelContext::ActiveRecordContext.stub_context(
      model_name: 'User', method_name: 'Load', query_count: 3
    )
    span = FakeSpan.new
    @processor.on_start(span, nil)
    assert_equal 3, span.attributes['db.query_count']
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  def test_db_context_no_query_count_on_first_occurrence
    RailsOtelContext::ActiveRecordContext.stub_context({ model_name: 'User', method_name: 'Load' })
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('db.query_count')
  ensure
    RailsOtelContext::ActiveRecordContext.clear!
  end

  # ---------------------------------------------------------------------------
  # on_finish — db.slow detection
  # ---------------------------------------------------------------------------

  def test_on_finish_noop_without_threshold
    # No slow_query_threshold_ms configured → never sets db.slow
    span = db_span(start_ns: 0, end_ns: 500_000_000) # 500ms
    @processor.on_finish(span)
    refute span.attributes.key?('db.slow')
  end

  def test_on_finish_sets_db_slow_on_slow_db_span
    with_slow_query_threshold(100) do
      span = db_span(start_ns: 0, end_ns: 200_000_000) # 200ms > 100ms
      @processor.on_finish(span)
      assert span.attributes['db.slow'], 'slow DB span should be flagged'
    end
  end

  def test_on_finish_no_db_slow_for_fast_span
    with_slow_query_threshold(100) do
      span = db_span(start_ns: 0, end_ns: 50_000_000) # 50ms < 100ms
      @processor.on_finish(span)
      refute span.attributes.key?('db.slow')
    end
  end

  def test_on_finish_db_slow_at_exact_threshold
    with_slow_query_threshold(100) do
      span = db_span(start_ns: 0, end_ns: 100_000_000) # exactly 100ms
      @processor.on_finish(span)
      assert span.attributes['db.slow'], 'query at exact threshold should be flagged'
    end
  end

  def test_on_finish_skips_non_db_spans
    with_slow_query_threshold(10) do
      span = FakeSpan.new(start_timestamp: 0, end_timestamp: 500_000_000)
      # no db.system attribute → not a DB span
      @processor.on_finish(span)
      refute span.attributes.key?('db.slow')
    end
  end

  def test_on_finish_skips_span_without_timestamps
    with_slow_query_threshold(10) do
      span = FakeSpan.new
      span.set_attribute('db.system', 'mysql')
      # no start/end timestamps
      @processor.on_finish(span)
      refute span.attributes.key?('db.slow')
    end
  end

  def test_force_flush_is_a_noop
    assert_nil @processor.force_flush
  end

  def test_shutdown_is_a_noop
    assert_nil @processor.shutdown
  end

  # ---------------------------------------------------------------------------
  # GC pressure tracking (track_gc_stats: true)
  # ---------------------------------------------------------------------------

  def test_gc_stats_disabled_by_default
    span = FakeSpan.new
    @processor.on_start(span, nil)
    GC.start # force a collection
    @processor.on_finish(span)
    refute span.attributes.key?('ruby.gc.count')
    refute span.attributes.key?('ruby.gc.major_gc_count')
  end

  def test_gc_stats_sets_no_attribute_when_no_gc_occurred
    with_gc_stats_tracking do
      span = FakeSpan.new
      @processor.on_start(span, nil)
      # Manually restore the snapshot to simulate no GC happened
      snapshots = Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY]
      snapshots[span] = [GC.stat(:count), GC.stat(:major_gc_count)]
      @processor.on_finish(span)
      refute span.attributes.key?('ruby.gc.count'), 'should not set gc.count when delta is 0'
    end
  end

  def test_gc_stats_sets_count_when_gc_occurred
    with_gc_stats_tracking do
      span = FakeSpan.new
      @processor.on_start(span, nil)
      # Inject a fake snapshot as if GC ran 3 times between on_start and on_finish
      snapshots = Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY]
      current_count = GC.stat(:count)
      current_major = GC.stat(:major_gc_count)
      snapshots[span] = [current_count - 3, current_major]
      @processor.on_finish(span)
      assert_equal 3, span.attributes['ruby.gc.count']
      refute span.attributes.key?('ruby.gc.major_gc_count'), 'should omit major when 0'
    end
  end

  def test_gc_stats_sets_major_gc_count_when_major_occurred
    with_gc_stats_tracking do
      span = FakeSpan.new
      @processor.on_start(span, nil)
      snapshots = Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY]
      current_count = GC.stat(:count)
      current_major = GC.stat(:major_gc_count)
      snapshots[span] = [current_count - 5, current_major - 2]
      @processor.on_finish(span)
      assert_equal 5, span.attributes['ruby.gc.count']
      assert_equal 2, span.attributes['ruby.gc.major_gc_count']
    end
  end

  def test_gc_stats_snapshot_cleaned_up_after_on_finish
    with_gc_stats_tracking do
      span = FakeSpan.new
      @processor.on_start(span, nil)
      snapshots = Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY]
      assert snapshots.key?(span)
      @processor.on_finish(span)
      refute snapshots.key?(span), 'snapshot must be deleted to prevent memory leak'
    end
  end

  def test_gc_stats_independent_per_span
    with_gc_stats_tracking do
      span1 = FakeSpan.new
      span2 = FakeSpan.new
      @processor.on_start(span1, nil)
      @processor.on_start(span2, nil)
      snapshots = Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY]
      # Simulate 2 GC cycles on span1, 1 on span2
      base = GC.stat(:count)
      snapshots[span1] = [base - 2, GC.stat(:major_gc_count)]
      snapshots[span2] = [base - 1, GC.stat(:major_gc_count)]
      @processor.on_finish(span1)
      @processor.on_finish(span2)
      assert_equal 2, span1.attributes['ruby.gc.count']
      assert_equal 1, span2.attributes['ruby.gc.count']
    end
  end

  private

  def new_processor
    RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
  end

  # Build a FakeSpan that looks like a DB span (has db.system) with timestamps.
  # start_ns / end_ns are in nanoseconds (same unit as OTel span timestamps).
  def db_span(start_ns:, end_ns:)
    span = FakeSpan.new(start_timestamp: start_ns, end_timestamp: end_ns)
    span.set_attribute('db.system', 'mysql')
    span
  end

  def with_slow_query_threshold(threshold_ms)
    RailsOtelContext.configure { |c| c.slow_query_threshold_ms = threshold_ms }
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    # Swap @processor so on_finish tests use the newly configured instance
    orig = @processor
    @processor = processor
    yield
  ensure
    @processor = orig
    RailsOtelContext.reset_configuration!
  end

  def with_gc_stats_tracking
    RailsOtelContext.configure { |c| c.track_gc_stats = true }
    orig = @processor
    @processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    yield
  ensure
    @processor = orig
    RailsOtelContext.reset_configuration!
    Thread.current[RailsOtelContext::CallContextProcessor::GC_SNAPSHOT_KEY] = nil
  end
end
