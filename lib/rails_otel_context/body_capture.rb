# frozen_string_literal: true

module RailsOtelContext
  # Rack middleware that captures request and response bodies as OpenTelemetry
  # span attributes. Works with any OTel Rack instrumentation — the middleware
  # must sit inside (after) the span-creating middleware so current_span is set.
  #
  # Usage:
  #   # config/application.rb (or an initializer after OTel is configured)
  #   config.middleware.use RailsOtelContext::BodyCapture
  #
  #   # With options:
  #   config.middleware.use RailsOtelContext::BodyCapture,
  #     on_error_only: true,
  #     max_bytes:     4096
  #
  # Span attributes set:
  #   http.request.body  — captured request body (when content type matches)
  #   http.response.body — captured response body (when content type matches)
  class BodyCapture
    DEFAULT_CONTENT_TYPES = %w[application/json application/xml text/plain].freeze
    DEFAULT_EXCLUDE_PATHS = %w[/health /ready /metrics].freeze
    DEFAULT_MAX_BYTES     = 8_192
    TRUNCATED_SUFFIX      = '...[TRUNCATED]'
    private_constant :DEFAULT_CONTENT_TYPES, :DEFAULT_EXCLUDE_PATHS,
                     :DEFAULT_MAX_BYTES, :TRUNCATED_SUFFIX

    def initialize(app, # rubocop:disable Metrics/ParameterLists
                   capture_request:  true,
                   capture_response: true,
                   max_bytes:        DEFAULT_MAX_BYTES,
                   on_error_only:    false,
                   content_types:    DEFAULT_CONTENT_TYPES,
                   include_paths:    [],
                   exclude_paths:    DEFAULT_EXCLUDE_PATHS)
      @app              = app
      @capture_request  = capture_request
      @capture_response = capture_response
      @max_bytes        = max_bytes
      @on_error_only    = on_error_only
      @content_types    = content_types
      @include_paths    = include_paths
      @exclude_paths    = exclude_paths
    end

    def call(env)
      return @app.call(env) unless should_capture?(env['PATH_INFO'])

      request_str           = read_request(env)
      status, headers, body = @app.call(env)

      # With on_error_only, skip body drain on successful responses — no buffering
      # overhead on the happy path. (Synchronous Rack means we know status before
      # deciding to drain, unlike async frameworks that must always buffer.)
      should_record = !@on_error_only || status >= 400

      if should_record && @capture_response
        body, response_str = drain_response(body, headers)
      end

      set_span_attributes(request_str, response_str) if should_record

      [status, headers, body]
    end

    private

    def should_capture?(path)
      return false if @exclude_paths.any? { |p| path.start_with?(p) }
      return true  if @include_paths.empty?

      @include_paths.any? { |p| path.start_with?(p) }
    end

    def allowed_content_type?(content_type)
      return false unless content_type && !content_type.empty?
      return true  if @content_types.empty?

      @content_types.any? { |ct| content_type.include?(ct) }
    end

    def read_request(env)
      return unless @capture_request
      return unless allowed_content_type?(env['CONTENT_TYPE'])

      input = env['rack.input']
      return unless input

      raw = input.read
      input.rewind
      cap(raw)
    end

    def drain_response(body, headers)
      chunks = body.map { |chunk| chunk }
      body.close if body.respond_to?(:close)

      content_type = headers['Content-Type'] || headers['content-type']
      body_str     = cap(chunks.join) if allowed_content_type?(content_type)

      [chunks, body_str]
    end

    def set_span_attributes(request_str, response_str)
      return unless defined?(OpenTelemetry)

      span = OpenTelemetry::Trace.current_span
      return unless span.context.valid?

      span.set_attribute('http.request.body',  request_str)  if request_str
      span.set_attribute('http.response.body', response_str) if response_str
    end

    def cap(str)
      return nil if str.nil? || str.empty?
      return str if str.bytesize <= @max_bytes

      # scrub cleans up any incomplete multibyte sequence at the slice boundary
      str.byteslice(0, @max_bytes).scrub + TRUNCATED_SUFFIX
    end
  end
end
