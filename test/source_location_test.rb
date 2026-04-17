# frozen_string_literal: true

require 'test_helper'

class SourceLocationTest < Minitest::Test
  include CallerLocationHelpers

  # A minimal host that includes SourceLocation and exposes app_root.
  class Host
    include RailsOtelContext::SourceLocation

    def initialize(app_root)
      @app_root = app_root
    end

    attr_reader :app_root
  end

  def setup
    @app_root = Dir.pwd
    @host     = Host.new(@app_root)
  end

  # ── source_location_for_app (legacy) ─────────────────────────────────────

  def test_source_location_for_app_returns_filepath_and_lineno
    with_thread_source('app/models/order.rb', 42) do
      result = @host.source_location_for_app
      assert_equal ['app/models/order.rb', 42], result
    end
  end

  def test_source_location_for_app_returns_nil_when_no_app_frame
    with_multiple_caller_locations([]) do
      result = @host.source_location_for_app
      assert_nil result
    end
  end

  def test_source_location_for_app_skips_gem_frames
    abs_gem = File.join(@app_root, 'vendor/gems/foo/lib/foo.rb')
    abs_app = File.join(@app_root, 'app/services/svc.rb')
    gem_loc = OpenStruct.new(absolute_path: abs_gem, path: nil, lineno: 1, label: nil)
    app_loc = OpenStruct.new(absolute_path: abs_app, path: nil, lineno: 7, label: nil)
    with_multiple_caller_locations([gem_loc, app_loc]) do
      result = @host.source_location_for_app
      assert_equal ['app/services/svc.rb', 7], result
    end
  end

  # ── apply_source_to_span (legacy) ────────────────────────────────────────

  def test_apply_source_to_span_sets_filepath_and_lineno
    span = FakeSpan.new
    @host.apply_source_to_span(span, ['app/controllers/orders_controller.rb', 55])
    assert_equal 'app/controllers/orders_controller.rb', span.attributes['code.filepath']
    assert_equal 55,                                     span.attributes['code.lineno']
  end

  def test_apply_source_to_span_is_noop_when_source_nil
    span = FakeSpan.new
    @host.apply_source_to_span(span, nil)
    refute span.attributes.key?('code.filepath')
    refute span.attributes.key?('code.lineno')
  end

  # ── build_call_site (via call_site_for_app) ───────────────────────────────

  def test_call_site_for_app_parses_class_method_label
    with_thread_source('app/models/order.rb', 10, label: 'Order.find_by_ref') do
      site = @host.call_site_for_app
      assert_equal 'Order',        site[:class_name]
      assert_equal 'find_by_ref',  site[:method_name]
      assert_equal 10,             site[:lineno]
      assert_equal 'app/models/order.rb', site[:filepath]
    end
  end

  def test_call_site_for_app_parses_instance_method_label
    with_thread_source('app/services/payment_service.rb', 23, label: 'PaymentService#charge') do
      site = @host.call_site_for_app
      assert_equal 'PaymentService', site[:class_name]
      assert_equal 'charge',         site[:method_name]
    end
  end

  def test_call_site_for_app_strips_block_prefix_from_method
    with_thread_source('app/jobs/report_job.rb', 5, label: 'ReportJob#perform') do
      site = @host.call_site_for_app
      assert_equal 'perform', site[:method_name]
    end
  end

  def test_call_site_for_app_handles_label_without_class
    with_thread_source('app/helpers/utils.rb', 3, label: 'my_helper') do
      site = @host.call_site_for_app
      # Falls back to filename-derived class name
      assert_equal 'Utils',      site[:class_name]
      assert_equal 'my_helper',  site[:method_name]
    end
  end

  def test_call_site_for_app_returns_nil_when_no_app_frame
    with_multiple_caller_locations([]) do
      assert_nil @host.call_site_for_app
    end
  end

  # ── apply_call_site_to_span ───────────────────────────────────────────────

  def test_apply_call_site_to_span_sets_all_attributes
    span = FakeSpan.new
    site = { class_name: 'OrderService', method_name: 'create', filepath: 'app/services/order_service.rb', lineno: 12 }
    @host.apply_call_site_to_span(span, site)
    assert_equal 'OrderService',                  span.attributes['code.namespace']
    assert_equal 'create',                        span.attributes['code.function']
    assert_equal 'app/services/order_service.rb', span.attributes['code.filepath']
    assert_equal 12,                              span.attributes['code.lineno']
  end

  def test_apply_call_site_to_span_skips_nil_method_name
    span = FakeSpan.new
    site = { class_name: 'Foo', method_name: nil, filepath: 'app/foo.rb', lineno: 1 }
    @host.apply_call_site_to_span(span, site)
    refute span.attributes.key?('code.function')
  end

  def test_apply_call_site_to_span_is_noop_when_site_nil
    span = FakeSpan.new
    @host.apply_call_site_to_span(span, nil)
    refute span.attributes.key?('code.namespace')
  end

  def test_apply_call_site_to_span_is_noop_when_context_invalid
    span = FakeSpan.new(valid_context: false)
    site = { class_name: 'Foo', method_name: 'bar', filepath: 'app/foo.rb', lineno: 1 }
    @host.apply_call_site_to_span(span, site)
    refute span.attributes.key?('code.namespace')
  end
end
