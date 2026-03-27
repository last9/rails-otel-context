# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

# Simulates Rails CurrentAttributes pattern used in production monoliths
# to propagate request-scoped team/domain context across all spans in a trace.
class FakeCurrent
  TEAM_MAP = {
    'spaces' => 'content',
    'chat_rooms' => 'messaging',
    'notifications' => 'messaging',
    'payments' => 'billing',
    'posts' => 'content'
  }.freeze

  def self.reset!
    Thread.current[:_fake_current_team] = nil
  end

  def self.team
    Thread.current[:_fake_current_team]
  end

  def self.team=(value)
    Thread.current[:_fake_current_team] = value&.freeze
  end

  def self.resolve_team(controller_name)
    TEAM_MAP[controller_name]
  end
end

class CustomSpanAttributesIntegrationTest < Minitest::Test
  include CallerLocationHelpers

  def setup
    RailsOtelContext.reset_configuration!
    @app_root = '/myapp'
    FakeCurrent.reset!
  end

  def teardown
    FakeCurrent.reset!
  end

  # -------------------------------------------------------------------
  # Simulates full request lifecycle: controller sets team on Current,
  # then child spans (DB, HTTP, Redis) all pick it up via the callback.
  # -------------------------------------------------------------------

  def test_team_propagates_to_all_child_spans
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        team = FakeCurrent.team
        team ? { 'team' => team } : nil
      }
    end

    # Simulate: before_action sets Current.team
    FakeCurrent.team = FakeCurrent.resolve_team('chat_rooms')

    # Root span (controller)
    root_span = FakeSpan.new
    new_processor.on_start(root_span, nil)
    assert_equal 'messaging', root_span.attributes['team']

    # Child span (ActiveRecord query)
    db_span = FakeSpan.new
    new_processor.on_start(db_span, nil)
    assert_equal 'messaging', db_span.attributes['team']

    # Child span (HTTP client call)
    http_span = FakeSpan.new
    new_processor.on_start(http_span, nil)
    assert_equal 'messaging', http_span.attributes['team']

    # Child span (Redis)
    redis_span = FakeSpan.new
    new_processor.on_start(redis_span, nil)
    assert_equal 'messaging', redis_span.attributes['team']
  end

  def test_different_requests_get_different_teams
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        team = FakeCurrent.team
        team ? { 'team' => team } : nil
      }
    end

    # Request 1: chat controller
    FakeCurrent.team = FakeCurrent.resolve_team('chat_rooms')
    span1 = FakeSpan.new
    new_processor.on_start(span1, nil)
    assert_equal 'messaging', span1.attributes['team']

    # Request 2: payments controller
    FakeCurrent.team = FakeCurrent.resolve_team('payments')
    span2 = FakeSpan.new
    new_processor.on_start(span2, nil)
    assert_equal 'billing', span2.attributes['team']

    # Request 3: unknown controller (no team mapping)
    FakeCurrent.team = FakeCurrent.resolve_team('unknown_controller')
    span3 = FakeSpan.new
    new_processor.on_start(span3, nil)
    refute span3.attributes.key?('team')
  end

  def test_no_team_set_means_no_attribute
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        team = FakeCurrent.team
        team ? { 'team' => team } : nil
      }
    end

    # Current.team is nil (not set by any before_action)
    span = FakeSpan.new
    new_processor.on_start(span, nil)
    refute span.attributes.key?('team')
  end

  # -------------------------------------------------------------------
  # Kill switch — set custom_span_attributes = nil to disable
  # -------------------------------------------------------------------

  def test_nil_custom_span_attributes_disables_callback
    call_count = 0
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = nil
    end

    FakeCurrent.team = 'billing'

    span = FakeSpan.new
    new_processor.on_start(span, nil)

    assert_equal 0, call_count, 'callback should not be invoked when nil'
    refute span.attributes.key?('team')
  end

  # -------------------------------------------------------------------
  # Performance: callback returning frozen values, no extra allocations
  # -------------------------------------------------------------------

  def test_frozen_hash_values_work
    frozen_attrs = { 'team' => 'billing', 'region' => 'us-east' }.freeze
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { frozen_attrs }
    end

    span = FakeSpan.new
    new_processor.on_start(span, nil)
    assert_equal 'billing', span.attributes['team']
    assert_equal 'us-east', span.attributes['region']
  end

  # -------------------------------------------------------------------
  # Multiple custom attributes alongside code context
  # -------------------------------------------------------------------

  def test_custom_attributes_with_code_context_full_flow
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = lambda {
        team = FakeCurrent.team
        team ? { 'team' => team } : nil
      }
    end

    FakeCurrent.team = 'content'

    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/controllers/posts_controller.rb", label: 'PostsController#index') do
      new_processor.on_start(span, nil)
    end

    # code context attributes
    assert_equal 'PostsController', span.attributes['code.namespace']
    assert_equal 'index', span.attributes['code.function']

    # custom team attribute
    assert_equal 'content', span.attributes['team']
  end

  # -------------------------------------------------------------------
  # Resilience: broken callback never impacts spans
  # -------------------------------------------------------------------

  def test_broken_callback_does_not_prevent_code_context
    RailsOtelContext.configure do |c|
      c.custom_span_attributes = -> { raise NoMethodError, 'undefined method `team` for nil' }
    end

    span = FakeSpan.new
    with_caller_location(path: "#{@app_root}/app/models/user.rb", label: 'User.find') do
      new_processor.on_start(span, nil)
    end

    # code context still works even though custom callback raised
    assert_equal 'User', span.attributes['code.namespace']
    assert_equal 'find', span.attributes['code.function']
    refute span.attributes.key?('team')
  end

  private

  def new_processor
    RailsOtelContext::CallContextProcessor.new(app_root: @app_root)
  end
end
