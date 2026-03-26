# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class CallContextProcessorTest < Minitest::Test
  include CallerLocationHelpers

  def setup
    RailsOtelContext.reset_configuration!
    @app_root = '/myapp'
    @processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
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
  # Config flag
  # ---------------------------------------------------------------------------

  def test_does_nothing_when_call_context_disabled
    RailsOtelContext.configure { |c| c.call_context_enabled = false }
    proc = new_processor
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: 'perform') do
      proc.on_start(span, nil)
    end
    refute span.attributes.key?('code.namespace')
    refute span.attributes.key?('code.function')
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

  def test_custom_attributes_disabled_via_flag
    call_count = 0
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        call_count += 1
        { 'team' => 'backend' }
      }
      c.custom_span_attributes_enabled = false
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    assert_equal 0, call_count
    refute span.attributes.key?('team')
  end

  def test_custom_attributes_works_with_call_context_disabled
    RailsOtelContext.configure do |c|
      c.call_context_enabled = false
      c.custom_span_attributes = -> { { 'team' => 'platform' } }
    end
    proc = new_processor
    span = FakeSpan.new
    proc.on_start(span, nil)
    refute span.attributes.key?('code.namespace')
    assert_equal 'platform', span.attributes['team']
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
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = { model_name: 'User', method_name: 'Load' }
    span = FakeSpan.new
    @processor.on_start(span, nil)
    assert_equal 'User', span.attributes['code.activerecord.model']
    assert_equal 'Load', span.attributes['code.activerecord.method']
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def test_db_context_sets_scope_name
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = {
      model_name: 'Transaction', method_name: 'Load', scope_name: 'recent_completed'
    }
    span = FakeSpan.new
    @processor.on_start(span, nil)
    assert_equal 'recent_completed', span.attributes['code.activerecord.scope']
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def test_db_context_no_scope_when_absent
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = { model_name: 'User', method_name: 'Count' }
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('code.activerecord.scope')
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def test_db_context_noop_when_no_ar_context
    span = FakeSpan.new
    @processor.on_start(span, nil)
    refute span.attributes.key?('code.activerecord.model')
  end

  def test_db_context_formatter_renames_and_preserves_original
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = { model_name: 'Order', method_name: 'Load' }
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, ctx) { "#{ctx[:model_name]}.#{ctx[:method_name]}" }
    end
    proc = new_processor

    span = FakeSpan.new
    span.define_singleton_method(:name) { @custom_name || 'select' }
    span.define_singleton_method(:name=) { |n| @custom_name = n }

    proc.on_start(span, nil)
    assert_equal 'Order.Load', span.name
    assert_equal 'select', span.attributes['l9.orig.name']
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def test_db_context_formatter_receives_scope_and_code_context
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = {
      model_name: 'Transaction', method_name: 'Load', scope_name: 'recent_completed'
    }
    received_ctx = nil
    RailsOtelContext.configure do |c|
      c.span_name_formatter = lambda { |_orig, ctx|
        received_ctx = ctx
        'renamed'
      }
    end
    proc = new_processor

    span = FakeSpan.new
    span.define_singleton_method(:name) { 'select' }
    span.define_singleton_method(:name=) { |n| @custom_name = n }

    proc.on_start(span, nil)

    assert_equal 'recent_completed', received_ctx[:scope_name]
    assert_equal 'Transaction', received_ctx[:model_name]
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  def test_db_context_formatter_exception_swallowed
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = { model_name: 'User', method_name: 'Load' }
    RailsOtelContext.configure do |c|
      c.span_name_formatter = ->(_orig, _ctx) { raise 'boom' }
    end
    proc = new_processor

    span = FakeSpan.new
    proc.on_start(span, nil)
    # Should not raise, and AR attributes should still be set
    assert_equal 'User', span.attributes['code.activerecord.model']
  ensure
    Thread.current[RailsOtelContext::ActiveRecordContext::THREAD_KEY] = nil
  end

  # ---------------------------------------------------------------------------
  # no-op lifecycle methods
  # ---------------------------------------------------------------------------

  def test_on_finish_is_a_noop
    assert_nil @processor.on_finish(FakeSpan.new)
  end

  def test_force_flush_is_a_noop
    assert_nil @processor.force_flush
  end

  def test_shutdown_is_a_noop
    assert_nil @processor.shutdown
  end

  private

  def new_processor
    RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
  end
end
