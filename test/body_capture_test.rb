# frozen_string_literal: true

require_relative 'test_helper'

class BodyCaptureTest < Minitest::Test
  include SpanHelpers

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds a minimal Rack env. rack.input is a rewound StringIO so it behaves
  # like a real request body stream.
  def make_env(path: '/', content_type: nil, body: nil)
    {
      'PATH_INFO' => path,
      'CONTENT_TYPE' => content_type || '',
      'rack.input' => StringIO.new(body || '')
    }
  end

  # Builds a minimal downstream Rack app that returns a fixed response.
  def make_app(status: 200, body: [''], content_type: 'application/json')
    ->(_env) { [status, { 'Content-Type' => content_type }, body] }
  end

  def middleware(**opts)
    RailsOtelContext::BodyCapture.new(make_app(**opts.slice(:status, :body, :content_type)),
                                      **opts.except(:status, :body, :content_type))
  end

  # ---------------------------------------------------------------------------
  # Request body capture
  # ---------------------------------------------------------------------------

  def test_sets_request_body_attribute_on_span
    env = make_env(content_type: 'application/json', body: '{"id":1}')
    mw  = RailsOtelContext::BodyCapture.new(make_app)

    with_current_span do |span|
      mw.call(env)
      assert_equal '{"id":1}', span.attributes['http.request.body']
    end
  end

  def test_request_body_remains_readable_by_downstream_app
    read_by_app = nil
    app = lambda do |env|
      read_by_app = env['rack.input'].read
      [200, { 'Content-Type' => 'application/json' }, ['{}']]
    end
    mw  = RailsOtelContext::BodyCapture.new(app)
    env = make_env(content_type: 'application/json', body: '{"id":1}')

    with_current_span do |_span|
      mw.call(env)
    end

    assert_equal '{"id":1}', read_by_app
  end

  def test_does_not_capture_request_when_content_type_not_allowed
    env = make_env(content_type: 'text/html', body: '<html/>')
    mw  = RailsOtelContext::BodyCapture.new(make_app)

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
    end
  end

  def test_does_not_capture_request_when_capture_request_false
    env = make_env(content_type: 'application/json', body: '{"id":1}')
    mw  = RailsOtelContext::BodyCapture.new(make_app, capture_request: false)

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
    end
  end

  # ---------------------------------------------------------------------------
  # Response body capture
  # ---------------------------------------------------------------------------

  def test_sets_response_body_attribute_on_span
    mw = RailsOtelContext::BodyCapture.new(
      make_app(body: ['{"status":"ok"}'], content_type: 'application/json')
    )

    with_current_span do |span|
      mw.call(make_env)
      assert_equal '{"status":"ok"}', span.attributes['http.response.body']
    end
  end

  def test_response_body_still_delivered_to_caller
    mw     = RailsOtelContext::BodyCapture.new(make_app(body: ['hello'], content_type: 'text/plain'))
    result = nil

    with_current_span do |_span|
      _, _, body = mw.call(make_env)
      chunks = body.map { |c| c }
      result = chunks.join
    end

    assert_equal 'hello', result
  end

  def test_does_not_capture_response_when_content_type_not_allowed
    mw = RailsOtelContext::BodyCapture.new(make_app(body: ['<html/>'], content_type: 'text/html'))

    with_current_span do |span|
      mw.call(make_env)
      refute span.attributes.key?('http.response.body')
    end
  end

  def test_does_not_capture_response_when_capture_response_false
    mw = RailsOtelContext::BodyCapture.new(
      make_app(body: ['{"ok":1}'], content_type: 'application/json'),
      capture_response: false
    )

    with_current_span do |span|
      mw.call(make_env)
      refute span.attributes.key?('http.response.body')
    end
  end

  # ---------------------------------------------------------------------------
  # Path filtering
  # ---------------------------------------------------------------------------

  def test_skips_excluded_paths
    mw = RailsOtelContext::BodyCapture.new(make_app(body: ['{}']))
    env = make_env(path: '/health', content_type: 'application/json', body: '{}')

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
      refute span.attributes.key?('http.response.body')
    end
  end

  def test_captures_non_excluded_paths
    mw  = RailsOtelContext::BodyCapture.new(make_app(body: ['{"ok":1}']))
    env = make_env(path: '/api/orders', content_type: 'application/json', body: '{}')

    with_current_span do |span|
      mw.call(env)
      assert span.attributes.key?('http.response.body')
    end
  end

  def test_include_paths_restricts_capture_to_matching_prefix
    mw = RailsOtelContext::BodyCapture.new(
      make_app(body: ['{}'], content_type: 'application/json'),
      include_paths: ['/api'],
      exclude_paths: []
    )

    with_current_span do |span|
      mw.call(make_env(path: '/web/page', content_type: 'application/json', body: '{}'))
      refute span.attributes.key?('http.request.body'), 'non-included path must not be captured'
    end
  end

  def test_include_paths_captures_matching_prefix
    mw = RailsOtelContext::BodyCapture.new(
      make_app(body: ['{"ok":1}'], content_type: 'application/json'),
      include_paths: ['/api'],
      exclude_paths: []
    )

    with_current_span do |span|
      mw.call(make_env(path: '/api/orders', content_type: 'application/json', body: '{}'))
      assert span.attributes.key?('http.response.body'), 'included path must be captured'
    end
  end

  # ---------------------------------------------------------------------------
  # on_error_only
  # ---------------------------------------------------------------------------

  def test_on_error_only_skips_successful_responses
    mw = RailsOtelContext::BodyCapture.new(
      make_app(status: 200, body: ['{}'], content_type: 'application/json'),
      on_error_only: true
    )
    env = make_env(content_type: 'application/json', body: '{"id":1}')

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
      refute span.attributes.key?('http.response.body')
    end
  end

  def test_on_error_only_captures_error_responses
    mw = RailsOtelContext::BodyCapture.new(
      make_app(status: 500, body: ['{"error":"oops"}'], content_type: 'application/json'),
      on_error_only: true
    )

    with_current_span do |span|
      mw.call(make_env)
      assert span.attributes.key?('http.response.body')
    end
  end

  def test_on_error_only_captures_at_400_boundary
    mw = RailsOtelContext::BodyCapture.new(
      make_app(status: 400, body: ['{"error":"bad"}'], content_type: 'application/json'),
      on_error_only: true
    )

    with_current_span do |span|
      mw.call(make_env)
      assert span.attributes.key?('http.response.body')
    end
  end

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  def test_truncates_request_body_above_max_bytes
    long_body = 'x' * 100
    env = make_env(content_type: 'application/json', body: long_body)
    mw  = RailsOtelContext::BodyCapture.new(make_app, max_bytes: 10)

    with_current_span do |span|
      mw.call(env)
      assert_includes span.attributes['http.request.body'], '...[TRUNCATED]'
      assert span.attributes['http.request.body'].start_with?('xxxxxxxxxx')
    end
  end

  def test_truncates_response_body_above_max_bytes
    long_body = '{"this":"is a very long response body"}'
    mw = RailsOtelContext::BodyCapture.new(
      make_app(body: [long_body], content_type: 'application/json'),
      max_bytes: 10
    )

    with_current_span do |span|
      mw.call(make_env)
      assert_includes span.attributes['http.response.body'], '...[TRUNCATED]'
    end
  end

  def test_does_not_truncate_body_within_max_bytes
    env = make_env(content_type: 'application/json', body: '{"id":1}')
    mw  = RailsOtelContext::BodyCapture.new(make_app, max_bytes: 8192)

    with_current_span do |span|
      mw.call(env)
      assert_equal '{"id":1}', span.attributes['http.request.body']
    end
  end

  # ---------------------------------------------------------------------------
  # Span context guard
  # ---------------------------------------------------------------------------

  def test_does_not_set_attributes_when_span_context_invalid
    env = make_env(content_type: 'application/json', body: '{"id":1}')
    mw  = RailsOtelContext::BodyCapture.new(make_app)

    with_current_span(FakeSpan.new(valid_context: false)) do |span|
      mw.call(env)
      assert_empty span.attributes
    end
  end
end
