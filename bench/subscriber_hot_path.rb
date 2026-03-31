#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks the Subscriber hot path (start + finish) in isolation.
# No Rails boot required — we stub out OTel, AR, and AS::Notifications.
#
# Usage:
#   ruby bench/subscriber_hot_path.rb
#
# Reports:
#   1. benchmark-ips  — throughput (iterations/sec)
#   2. memory_profiler — allocations per single start+finish cycle
#   3. stackprof       — CPU flamegraph (written to tmp/subscriber.dump)

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'opentelemetry-api'
require 'logger'
ENV['RAILS_OTEL_CONTEXT_TEST'] = 'true'
require 'rails_otel_context'
require 'benchmark/ips'
require 'memory_profiler'
require 'stackprof'
require 'fileutils'

# ---------------------------------------------------------------------------
# Minimal stubs
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

# Patch OTel to return a stable fake span
FAKE_SPAN = FakeSpan.new
module OpenTelemetry
  module Trace
    def self.current_span = FAKE_SPAN
  end
end

# ---------------------------------------------------------------------------
# Subscriber under test
# ---------------------------------------------------------------------------

RailsOtelContext.configure do |c|
  c.slow_query_threshold_ms = 100 # enable timing path
end

SUB = RailsOtelContext::ActiveRecordContext::Subscriber.new

# Simulates the most common query: a named AR query (e.g. "User Load")
NAMED_PAYLOAD = { name: 'User Load' }.freeze

# Simulates a counter-cache update (name="SQL")
RailsOtelContext::ActiveRecordContext.instance_variable_set(
  :@ar_table_model_map, { 'users' => 'User' }
)
SQL_PAYLOAD = { name: 'SQL', sql: 'UPDATE `users` SET `comments_count` = 5 WHERE id = 1' }.freeze

# Stable event id (avoids object churn in the id slot)
EVENT_ID = 'bench-event-1'

# ---------------------------------------------------------------------------
# 1. Throughput — benchmark-ips
# ---------------------------------------------------------------------------

puts "\n== benchmark-ips: Subscriber#start+finish throughput ==\n\n"

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report('named query (User Load)') do
    SUB.start('sql.active_record', EVENT_ID, NAMED_PAYLOAD)
    SUB.finish('sql.active_record', EVENT_ID, {})
    RailsOtelContext::ActiveRecordContext.clear!
  end

  x.report('SQL-named (counter cache UPDATE)') do
    SUB.start('sql.active_record', EVENT_ID, SQL_PAYLOAD)
    SUB.finish('sql.active_record', EVENT_ID, {})
    RailsOtelContext::ActiveRecordContext.clear!
  end

  x.compare!
end

# ---------------------------------------------------------------------------
# 2. Allocations — memory_profiler
# ---------------------------------------------------------------------------

puts "\n== memory_profiler: allocations per start+finish cycle ==\n\n"

[
  ['named query (User Load)', NAMED_PAYLOAD],
  ['SQL-named (counter cache UPDATE)', SQL_PAYLOAD]
].each do |label, payload|
  report = MemoryProfiler.report(allow_files: 'rails_otel_context') do
    100.times do
      SUB.start('sql.active_record', EVENT_ID, payload)
      SUB.finish('sql.active_record', EVENT_ID, {})
      RailsOtelContext::ActiveRecordContext.clear!
    end
  end

  total_allocs = report.total_allocated
  total_bytes  = report.total_allocated_memsize

  puts "#{label}:"
  puts "  total allocated objects : #{total_allocs} over 100 calls (#{total_allocs / 100.0} per call)"
  puts "  total allocated bytes   : #{total_bytes} over 100 calls (#{total_bytes / 100.0} per call)"

  # Top allocating lines within our gem
  by_location = report.allocated_objects_by_location
                      .first(5)
  unless by_location.empty?
    puts '  top allocating lines:'
    by_location.each do |entry|
      puts "    #{entry[:count].to_s.rjust(4)}x  #{entry[:data].sub("#{Dir.pwd}/", '')}"
    end
  end
  puts
end

# ---------------------------------------------------------------------------
# 3. CPU profile — stackprof
# ---------------------------------------------------------------------------

puts "== stackprof: CPU profile (100_000 iterations) ==\n\n"

FileUtils.mkdir_p('tmp')

profile = StackProf.run(mode: :cpu, interval: 100, raw: true) do
  100_000.times do
    SUB.start('sql.active_record', EVENT_ID, NAMED_PAYLOAD)
    SUB.finish('sql.active_record', EVENT_ID, {})
    RailsOtelContext::ActiveRecordContext.clear!
  end
end

StackProf::Report.new(profile).print_text(false, 20)

dump_path = File.expand_path('../tmp/subscriber.dump', __dir__)
File.binwrite(dump_path, Marshal.dump(profile))
puts "\nRaw profile written to #{dump_path}"
puts "View flamegraph: stackprof --flamegraph #{dump_path} | open -f -a 'Google Chrome'"
