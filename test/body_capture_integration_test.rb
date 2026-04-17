# frozen_string_literal: true

require_relative 'test_helper'

# Integration tests for BodyCapture as a full Rack middleware stack.
#
# Each test wires up: BodyCapture.new(downstream_app) and calls .call(env),
# which exercises the real code path end-to-end — request read, downstream
# call, response drain, span attribute writes — with no internal stubs.
#
# Span writes are captured by replacing OpenTelemetry::Trace.current_span
# with a FakeSpan for the duration of each test.
class BodyCaptureIntegrationTest < Minitest::Test
  include SpanHelpers

  JSON_CT  = 'application/json'
  PLAIN_CT = 'text/plain'

  # ── helpers ──────────────────────────────────────────────────────────────────

  # Minimal Rack app — returns status, headers, body.
  def downstream(status: 200, body: '{"ok":true}', content_type: JSON_CT)
    lambda do |_env|
      [status, { 'Content-Type' => content_type }, [body]]
    end
  end

  def env_for(path: '/api/orders', method: 'GET', body: nil, content_type: nil)
    input = StringIO.new(body.to_s)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'rack.input' => input,
      'CONTENT_TYPE' => content_type || ''
    }
  end

  # ── request body capture ─────────────────────────────────────────────────────

  def test_request_body_captured_on_json_post
    mw = RailsOtelContext::BodyCapture.new(downstream, capture_request: true)
    env = env_for(method: 'POST', body: '{"user":"alice"}', content_type: JSON_CT)

    with_current_span do |span|
      mw.call(env)
      assert_equal '{"user":"alice"}', span.attributes['http.request.body']
    end
  end

  def test_request_body_not_captured_when_disabled
    mw = RailsOtelContext::BodyCapture.new(downstream, capture_request: false)
    env = env_for(method: 'POST', body: '{"user":"alice"}', content_type: JSON_CT)

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
    end
  end

  def test_request_body_not_captured_for_non_json_content_type
    mw = RailsOtelContext::BodyCapture.new(downstream, capture_request: true)
    env = env_for(method: 'POST', body: 'binary data', content_type: 'image/png')

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
    end
  end

  # ── response body capture ────────────────────────────────────────────────────

  def test_response_body_captured_on_json_response
    mw  = RailsOtelContext::BodyCapture.new(downstream(body: '{"id":1}'), capture_response: true)
    env = env_for

    with_current_span do |span|
      status, _headers, body = mw.call(env)
      assert_equal 200, status
      assert_equal '{"id":1}', span.attributes['http.response.body']
      assert_equal ['{"id":1}'], body.to_a, 'response body must be passthrough-compatible'
    end
  end

  def test_response_body_not_captured_when_disabled
    mw  = RailsOtelContext::BodyCapture.new(downstream, capture_response: false)
    env = env_for

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.response.body')
    end
  end

  def test_response_body_not_captured_for_non_json_content_type
    mw  = RailsOtelContext::BodyCapture.new(downstream(body: '<html/>', content_type: 'text/html'))
    env = env_for

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.response.body')
    end
  end

  # ── on_error_only ────────────────────────────────────────────────────────────

  def test_on_error_only_skips_capture_on_2xx
    mw  = RailsOtelContext::BodyCapture.new(downstream(status: 200), on_error_only: true)
    env = env_for

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.response.body'), '2xx must not be captured with on_error_only'
    end
  end

  def test_on_error_only_captures_on_4xx
    mw = RailsOtelContext::BodyCapture.new(
      downstream(status: 422, body: '{"error":"invalid"}'),
      on_error_only: true
    )
    env = env_for

    with_current_span do |span|
      mw.call(env)
      assert_equal '{"error":"invalid"}', span.attributes['http.response.body']
    end
  end

  def test_on_error_only_captures_on_5xx
    mw = RailsOtelContext::BodyCapture.new(
      downstream(status: 500, body: '{"error":"boom"}'),
      on_error_only: true
    )
    env = env_for

    with_current_span do |span|
      mw.call(env)
      assert_equal '{"error":"boom"}', span.attributes['http.response.body']
    end
  end

  # ── exclude_paths ────────────────────────────────────────────────────────────

  def test_excluded_path_skips_entire_capture
    mw = RailsOtelContext::BodyCapture.new(
      downstream(body: '{"ok":true}'),
      exclude_paths: ['/health']
    )
    env = env_for(path: '/health')

    with_current_span do |span|
      mw.call(env)
      refute span.attributes.key?('http.request.body')
      refute span.attributes.key?('http.response.body')
    end
  end

  def test_non_excluded_path_is_captured
    mw = RailsOtelContext::BodyCapture.new(
      downstream(body: '{"ok":true}'),
      exclude_paths: ['/health']
    )
    env = env_for(path: '/api/orders', method: 'POST', body: '{}', content_type: JSON_CT)

    with_current_span do |span|
      mw.call(env)
      assert span.attributes.key?('http.response.body')
    end
  end

  # ── max_bytes truncation ─────────────────────────────────────────────────────

  def test_response_body_truncated_at_max_bytes
    long_body = 'x' * 200
    mw = RailsOtelContext::BodyCapture.new(
      downstream(body: long_body),
      max_bytes: 100
    )
    env = env_for

    with_current_span do |span|
      mw.call(env)
      captured = span.attributes['http.response.body']
      assert captured.end_with?('...[TRUNCATED]'), 'long body must be truncated'
      assert captured.bytesize < long_body.bytesize
    end
  end

  # ── response passthrough integrity ───────────────────────────────────────────

  def test_multi_chunk_response_is_fully_returned
    chunked_app = ->(_env) { [200, { 'Content-Type' => JSON_CT }, ['{"a":', '"b"}']] }
    mw  = RailsOtelContext::BodyCapture.new(chunked_app)
    env = env_for

    with_current_span do |span|
      _status, _headers, body = mw.call(env)
      assert_equal '{"a":"b"}', body.join
      assert_equal '{"a":"b"}', span.attributes['http.response.body']
    end
  end

  # ── no span / invalid context does not raise ─────────────────────────────────

  def test_no_active_span_does_not_raise
    mw  = RailsOtelContext::BodyCapture.new(downstream)
    env = env_for(method: 'POST', body: '{}', content_type: JSON_CT)

    # No with_current_span wrapper — OpenTelemetry returns a no-op span whose
    # context.valid? is false; BodyCapture must not crash.
    assert_silent { mw.call(env) }
  end
end
