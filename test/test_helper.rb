# frozen_string_literal: true

require 'minitest/autorun'
require 'opentelemetry-api'
require 'logger'

# Allow tests to run without Rails
ENV['RAILS_OTEL_CONTEXT_TEST'] = 'true'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'rails_otel_context'

class FakeSpanContext
  def initialize(valid)
    @valid = valid
  end

  def valid?
    @valid
  end
end

class FakeSpan
  attr_reader :attributes
  attr_accessor :name

  def initialize(valid_context: true)
    @attributes = {}
    @name = 'SELECT'
    @context = FakeSpanContext.new(valid_context)
  end

  def context
    @context
  end

  def set_attribute(key, value)
    @attributes[key] = value
  end

  def add_attributes(hash)
    @attributes.merge!(hash)
  end
end

module CallerLocationHelpers
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
        alias_method :__rails_otel_ctx_original_ecl, :each_caller_location
      end
    end

    thread_singleton.define_method(:each_caller_location) do |&blk|
      locations.each { |loc| blk.call(loc) }
    end

    yield
  ensure
    if had_original
      thread_singleton.class_eval do
        alias_method :each_caller_location, :__rails_otel_ctx_original_ecl
        remove_method :__rails_otel_ctx_original_ecl
      end
    else
      thread_singleton.class_eval { remove_method :each_caller_location }
    end
  end
end

module SpanHelpers
  def with_current_span(fake_span = FakeSpan.new)
    singleton = OpenTelemetry::Trace.singleton_class
    singleton.class_eval do
      alias_method :__rails_otel_context_original_current_span, :current_span
      define_method(:current_span) { fake_span }
    end

    yield fake_span
  ensure
    singleton.class_eval do
      alias_method :current_span, :__rails_otel_context_original_current_span
      remove_method :__rails_otel_context_original_current_span
    end
  end
end
