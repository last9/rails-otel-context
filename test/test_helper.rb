# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/test/'
    add_filter '/bench/'
    track_files 'lib/**/*.rb'
  end
end

require 'minitest/autorun'
require 'minitest/mock'
require 'opentelemetry-api'
require 'ostruct'
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
  attr_reader :attributes, :context
  attr_accessor :name, :start_timestamp, :end_timestamp

  def initialize(valid_context: true, start_timestamp: nil, end_timestamp: nil)
    @attributes      = {}
    @name            = 'SELECT'
    @context         = FakeSpanContext.new(valid_context)
    @start_timestamp = start_timestamp
    @end_timestamp   = end_timestamp
  end

  def set_attribute(key, value)
    @attributes[key] = value
  end

  def add_attributes(hash)
    @attributes.merge!(hash)
  end
end

# Minimal stub so FakeRelation passes is_a?(::ActiveRecord::Relation) in tests
unless defined?(ActiveRecord::Relation)
  module ActiveRecord
    Relation = Class.new
  end
end

# Stands in for ActiveRecord::Relation in ClassMethodScopeTracking tests
class FakeRelation < ActiveRecord::Relation
  def otel_scope_name
    instance_variable_get(:@_otel_scope_name)
  end
end

module CallerLocationHelpers
  def location(path, label, lineno = nil)
    OpenStruct.new(absolute_path: path, path: path, label: label, lineno: lineno)
  end

  def with_caller_location(path:, label:, lineno: nil, &block)
    with_multiple_caller_locations([location(path, label, lineno)], &block)
  end

  # Stubs Thread.each_caller_location to return a single app-code frame built
  # from a relative +path+ (joined to Dir.pwd) and optional +label+.
  # Used by adapter tests that need to exercise call-site extraction.
  def with_thread_source(path, lineno, label: nil, &block)
    abs = File.join(Dir.pwd, path)
    with_multiple_caller_locations(
      [OpenStruct.new(absolute_path: abs, path: nil, lineno: lineno, label: label)],
      &block
    )
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

  # Temporarily replaces Process.clock_gettime with a stub callable.
  # Restores the original after the block so Minitest's timing still works.
  def with_stubbed_clock(stub)
    ps = Process.singleton_class
    ps.alias_method(:__otel_orig_clock_gettime, :clock_gettime)
    ps.define_method(:clock_gettime) { |*_| stub.call }
    yield
  ensure
    ps.alias_method(:clock_gettime, :__otel_orig_clock_gettime)
    ps.remove_method(:__otel_orig_clock_gettime)
  end
end
