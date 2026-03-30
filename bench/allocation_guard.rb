#!/usr/bin/env ruby
# frozen_string_literal: true

# Allocation regression guard — runs in CI.
# Fails with exit 1 if any path allocates more objects than its budget.
#
# Allocation counts are deterministic: same code = same count regardless of
# machine speed. This makes them a reliable CI gate. Throughput (IPS) is not.
#
# Budgets are intentionally exact — any increase is a conscious decision.
# Usage: ruby bench/allocation_guard.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'opentelemetry-api'
ENV['RAILS_OTEL_CONTEXT_TEST'] = 'true'
require 'rails_otel_context'
require 'memory_profiler'

# ---------------------------------------------------------------------------
# Minimal stubs (same as subscriber_hot_path.rb)
# ---------------------------------------------------------------------------

module ActiveRecord
  class Base
    def self.descendants = []
  end
end

class FakeSpanContext
  def valid? = true
end

class FakeSpan
  attr_accessor :name
  attr_reader :attributes, :context

  def initialize
    @name       = 'trilogy.query'
    @attributes = {}
    @context    = FakeSpanContext.new
  end

  def set_attribute(k, v) = @attributes[k] = v
end

FAKE_SPAN = FakeSpan.new
module OpenTelemetry
  module Trace
    def self.current_span = FAKE_SPAN
  end
end

RailsOtelContext.configure { |c| c.slow_query_threshold_ms = 100 }

RailsOtelContext::ActiveRecordContext.instance_variable_set(
  :@ar_table_model_map, { 'users' => 'User' }
)

SUB      = RailsOtelContext::ActiveRecordContext::Subscriber.new
EVENT_ID = 'bench-event'.freeze

CASES = [
  {
    label:   'named query (User Load)',
    payload: { name: 'User Load' }.freeze,
    budget:  4
  },
  {
    label:   'SQL-named counter cache UPDATE',
    payload: { name: 'SQL', sql: 'UPDATE `users` SET `comments_count` = 5 WHERE id = 1' }.freeze,
    budget:  6
  }
].freeze

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

ITERATIONS = 100
failures   = []

CASES.each do |c|
  # Warmup: one pass outside the measurement window so lazy initialisations
  # (QUERY_COUNT_KEY hash, first-regex MatchData interning) don't skew counts.
  5.times do
    SUB.start('sql.active_record', EVENT_ID, c[:payload])
    SUB.finish('sql.active_record', EVENT_ID, {})
    RailsOtelContext::ActiveRecordContext.clear!
  end

  report = MemoryProfiler.report(allow_files: 'rails_otel_context') do
    ITERATIONS.times do
      SUB.start('sql.active_record', EVENT_ID, c[:payload])
      SUB.finish('sql.active_record', EVENT_ID, {})
      RailsOtelContext::ActiveRecordContext.clear!
    end
  end

  per_call = report.total_allocated.to_f / ITERATIONS

  status = per_call <= c[:budget] ? 'PASS' : 'FAIL'
  puts "#{status}  #{c[:label]}: #{per_call} allocs/call (budget: #{c[:budget]})"

  if per_call > c[:budget]
    failures << "#{c[:label]}: #{per_call} > #{c[:budget]} allocs/call"

    puts "     top allocating lines:"
    report.allocated_objects_by_location.first(5).each do |entry|
      puts "       #{entry[:count].to_s.rjust(5)}x  #{entry[:data].sub(Dir.pwd + '/', '')}"
    end
  end
end

puts
if failures.empty?
  puts "All allocation budgets met."
  exit 0
else
  puts "Allocation budget exceeded:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
