# frozen_string_literal: true

require_relative 'test_helper'

class RequestContextTest < Minitest::Test
  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::RequestContext.clear!
    @app_root = '/myapp'
  end

  def teardown
    RailsOtelContext::RequestContext.clear!
  end

  # ---------------------------------------------------------------------------
  # RequestContext thread-local storage
  # ---------------------------------------------------------------------------

  def test_set_and_read
    RailsOtelContext::RequestContext.set(controller: 'PostsController', action: 'index')
    assert_equal 'PostsController', RailsOtelContext::RequestContext.controller
    assert_equal 'index', RailsOtelContext::RequestContext.action
  end

  def test_clear_resets_all_values
    RailsOtelContext::RequestContext.set(controller: 'PostsController', action: 'index')
    RailsOtelContext::RequestContext.clear!
    assert_nil RailsOtelContext::RequestContext.controller
    assert_nil RailsOtelContext::RequestContext.action
  end

  def test_returns_nil_when_not_set
    assert_nil RailsOtelContext::RequestContext.controller
    assert_nil RailsOtelContext::RequestContext.action
  end

  # ---------------------------------------------------------------------------
  # SpanProcessor propagation
  # ---------------------------------------------------------------------------

  def test_request_context_propagated_to_all_spans
    RailsOtelContext.configure do |c|
      c.request_context_enabled = true
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    # Simulate: around_action sets context
    RailsOtelContext::RequestContext.set(controller: 'Api::PaymentsController', action: 'create')

    # Root span
    root = FakeSpan.new
    processor.on_start(root, nil)
    assert_equal 'Api::PaymentsController', root.attributes['request.controller']
    assert_equal 'create', root.attributes['request.action']

    # Child DB span
    db_span = FakeSpan.new
    processor.on_start(db_span, nil)
    assert_equal 'Api::PaymentsController', db_span.attributes['request.controller']
    assert_equal 'create', db_span.attributes['request.action']

    # Child HTTP span
    http_span = FakeSpan.new
    processor.on_start(http_span, nil)
    assert_equal 'Api::PaymentsController', http_span.attributes['request.controller']
    assert_equal 'create', http_span.attributes['request.action']
  end

  def test_no_attributes_when_request_context_not_set
    RailsOtelContext.configure do |c|
      c.request_context_enabled = true
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    span = FakeSpan.new
    processor.on_start(span, nil)
    refute span.attributes.key?('request.controller')
    refute span.attributes.key?('request.action')
  end

  def test_no_attributes_when_feature_disabled
    RailsOtelContext.configure do |c|
      c.request_context_enabled = false
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    RailsOtelContext::RequestContext.set(controller: 'PostsController', action: 'index')

    span = FakeSpan.new
    processor.on_start(span, nil)
    refute span.attributes.key?('request.controller')
    refute span.attributes.key?('request.action')
  end

  def test_cleanup_after_request_prevents_leakage
    RailsOtelContext.configure do |c|
      c.request_context_enabled = true
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    # Request 1
    RailsOtelContext::RequestContext.set(controller: 'OrdersController', action: 'show')
    span1 = FakeSpan.new
    processor.on_start(span1, nil)
    assert_equal 'OrdersController', span1.attributes['request.controller']

    # Request ends — cleanup
    RailsOtelContext::RequestContext.clear!

    # Next request on same thread — should have no leftover context
    span2 = FakeSpan.new
    processor.on_start(span2, nil)
    refute span2.attributes.key?('request.controller')
  end

  def test_coexists_with_call_context_and_custom_attributes
    RailsOtelContext.configure do |c|
      c.request_context_enabled = true
      c.custom_span_attributes = -> { { 'env' => 'production' } }
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'update')

    span = FakeSpan.new
    processor.on_start(span, nil)
    assert_equal 'UsersController', span.attributes['request.controller']
    assert_equal 'update', span.attributes['request.action']
    assert_equal 'production', span.attributes['env']
  end

  def test_default_request_context_is_disabled
    assert_equal false, RailsOtelContext.configuration.request_context_enabled
  end

  # ---------------------------------------------------------------------------
  # QUERY_COUNT_KEY lifecycle
  # ---------------------------------------------------------------------------

  def test_set_resets_query_count
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 3 }
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'index')
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end

  def test_clear_resets_query_count
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 3 }
    RailsOtelContext::RequestContext.clear!
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end

  def test_query_count_starts_fresh_across_requests
    RailsOtelContext::RequestContext.set(controller: 'PostsController', action: 'index')
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'Post.Load' => 5 }

    # Simulates the next request arriving on the same thread
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'show')
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end
end
