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
  # RequestContext thread-local storage — controller
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
  # RequestContext thread-local storage — job
  # ---------------------------------------------------------------------------

  def test_set_job_and_read
    RailsOtelContext::RequestContext.set_job(job_class: 'InvoiceJob')
    assert_equal 'InvoiceJob', RailsOtelContext::RequestContext.job
  end

  def test_set_job_resets_query_count
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 2 }
    RailsOtelContext::RequestContext.set_job(job_class: 'InvoiceJob')
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end

  def test_clear_job_clears_job_and_query_count
    RailsOtelContext::RequestContext.set_job(job_class: 'NotifyJob')
    Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY] = { 'User.Load' => 1 }
    RailsOtelContext::RequestContext.clear_job!
    assert_nil RailsOtelContext::RequestContext.job
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end

  def test_clear_also_clears_job
    RailsOtelContext::RequestContext.set_job(job_class: 'NotifyJob')
    RailsOtelContext::RequestContext.clear!
    assert_nil RailsOtelContext::RequestContext.job
  end

  # ---------------------------------------------------------------------------
  # SpanProcessor propagation — rails.controller / rails.action
  # ---------------------------------------------------------------------------

  def test_rails_controller_and_action_propagated_to_all_spans
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set(controller: 'Api::PaymentsController', action: 'create')

    [FakeSpan.new, FakeSpan.new, FakeSpan.new].each_with_index do |span, i|
      processor.on_start(span, nil)
      assert_equal 'Api::PaymentsController', span.attributes['rails.controller'], "span #{i}"
      assert_equal 'create', span.attributes['rails.action'], "span #{i}"
    end
  end

  def test_no_rails_controller_when_context_not_set
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    span = FakeSpan.new
    processor.on_start(span, nil)
    refute span.attributes.key?('rails.controller')
    refute span.attributes.key?('rails.action')
  end

  def test_cleanup_after_request_prevents_leakage
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)

    RailsOtelContext::RequestContext.set(controller: 'OrdersController', action: 'show')
    span1 = FakeSpan.new
    processor.on_start(span1, nil)
    assert_equal 'OrdersController', span1.attributes['rails.controller']

    RailsOtelContext::RequestContext.clear!

    span2 = FakeSpan.new
    processor.on_start(span2, nil)
    refute span2.attributes.key?('rails.controller')
  end

  # ---------------------------------------------------------------------------
  # SpanProcessor propagation — rails.job
  # ---------------------------------------------------------------------------

  def test_rails_job_propagated_to_all_spans
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set_job(job_class: 'WeeklyReportJob')

    span = FakeSpan.new
    processor.on_start(span, nil)
    assert_equal 'WeeklyReportJob', span.attributes['rails.job']
    refute span.attributes.key?('rails.controller')
  end

  def test_rails_controller_takes_priority_over_job_when_both_somehow_set
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'index')
    Thread.current[RailsOtelContext::RequestContext::JOB_KEY] = 'SomeJob'

    span = FakeSpan.new
    processor.on_start(span, nil)
    assert_equal 'UsersController', span.attributes['rails.controller']
    refute span.attributes.key?('rails.job')
  ensure
    Thread.current[RailsOtelContext::RequestContext::JOB_KEY] = nil
  end

  # ---------------------------------------------------------------------------
  # Coexistence with other features
  # ---------------------------------------------------------------------------

  def test_coexists_with_call_context_and_custom_attributes
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { { 'env' => 'production' } }
    end
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'update')

    span = FakeSpan.new
    processor.on_start(span, nil)
    assert_equal 'UsersController', span.attributes['rails.controller']
    assert_equal 'update', span.attributes['rails.action']
    assert_equal 'production', span.attributes['env']
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
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'show')
    assert_nil Thread.current[RailsOtelContext::RequestContext::QUERY_COUNT_KEY]
  end

  # ---------------------------------------------------------------------------
  # View template stack
  # ---------------------------------------------------------------------------

  def test_view_template_returns_nil_when_empty
    assert_nil RailsOtelContext::RequestContext.view_template
  end

  def test_push_and_read_view_template
    RailsOtelContext::RequestContext.push_view_template('/app/views/users/index.html.erb')
    assert_equal '/app/views/users/index.html.erb', RailsOtelContext::RequestContext.view_template
  ensure
    RailsOtelContext::RequestContext.pop_view_template
  end

  def test_nested_partials_use_innermost_template
    RailsOtelContext::RequestContext.push_view_template('/app/views/users/index.html.erb')
    RailsOtelContext::RequestContext.push_view_template('/app/views/users/_row.html.erb')
    assert_equal '/app/views/users/_row.html.erb', RailsOtelContext::RequestContext.view_template
    RailsOtelContext::RequestContext.pop_view_template
    assert_equal '/app/views/users/index.html.erb', RailsOtelContext::RequestContext.view_template
    RailsOtelContext::RequestContext.pop_view_template
    assert_nil RailsOtelContext::RequestContext.view_template
  end

  def test_clear_resets_view_stack
    RailsOtelContext::RequestContext.push_view_template('/app/views/users/index.html.erb')
    RailsOtelContext::RequestContext.clear!
    assert_nil RailsOtelContext::RequestContext.view_template
    assert_nil Thread.current[RailsOtelContext::RequestContext::VIEW_STACK_KEY]
  end

  def test_view_template_propagated_to_span
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'index')
    RailsOtelContext::RequestContext.push_view_template('/app/views/users/_row.html.erb')

    span = FakeSpan.new
    processor.on_start(span, nil)
    assert_equal 'UsersController', span.attributes['rails.controller']
    assert_equal '/app/views/users/_row.html.erb', span.attributes['rails.view.template']
  ensure
    RailsOtelContext::RequestContext.pop_view_template
  end

  def test_no_view_template_when_not_rendering
    processor = RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
    RailsOtelContext::RequestContext.set(controller: 'UsersController', action: 'index')

    span = FakeSpan.new
    processor.on_start(span, nil)
    refute span.attributes.key?('rails.view.template')
  end
end
