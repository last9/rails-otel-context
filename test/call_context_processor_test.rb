# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class CallContextProcessorTest < Minitest::Test
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
    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/jobs/invoice_job.rb", label: 'perform') do
      @processor.on_start(span, nil)
    end
    refute span.attributes.key?('code.namespace')
    refute span.attributes.key?('code.function')
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

  def location(path, label, lineno = nil)
    OpenStruct.new(absolute_path: path, path: path, label: label, lineno: lineno)
  end

  def with_caller_location(path:, label:, lineno: nil, &block)
    with_multiple_caller_locations([location(path, label, lineno)], &block)
  end

  def with_multiple_caller_locations(locations)
    thread_singleton = Thread.singleton_class
    had_original = Thread.respond_to?(:each_caller_location)

    if had_original
      thread_singleton.class_eval do
        alias_method :__call_ctx_original_each_caller_location, :each_caller_location
      end
    end

    thread_singleton.define_method(:each_caller_location) do |&blk|
      locations.each { |loc| blk.call(loc) }
    end

    yield
  ensure
    if had_original
      thread_singleton.class_eval do
        alias_method :each_caller_location, :__call_ctx_original_each_caller_location
        remove_method :__call_ctx_original_each_caller_location
      end
    else
      thread_singleton.class_eval { remove_method :each_caller_location }
    end
  end
end
