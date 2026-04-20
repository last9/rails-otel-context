# frozen_string_literal: true

require 'singleton'

module RailsOtelContext
  # Emits low-cardinality OTel Meter histograms for per-request and per-job
  # allocation and GC cost. Called from the gem's existing around_action and
  # around_perform hooks so trace-based exemplars attach to the bucket.
  #
  # Labels stay bounded:
  #   request → {controller, action}
  #   job     → {job_class, queue}
  module MemoryRecorder
    INSTRUMENTATION_NAME = 'rails_otel_context'

    REQUEST_METRICS = [
      ['ruby.request.allocated_objects', '{object}', 'Objects allocated during an HTTP request', :objects],
      ['ruby.request.gc_time_ms',        'ms',       'GC time spent during an HTTP request',     :gc_ms],
      ['ruby.request.gc_major_count',    '{gc}',     'Major GC cycles during an HTTP request',   :major],
      ['ruby.request.gc_minor_count',    '{gc}',     'Minor GC cycles during an HTTP request',   :minor]
    ].freeze

    JOB_METRICS = [
      ['ruby.job.allocated_objects', '{object}', 'Objects allocated during a background job', :objects],
      ['ruby.job.gc_time_ms',        'ms',       'GC time spent during a background job',     :gc_ms],
      ['ruby.job.gc_major_count',    '{gc}',     'Major GC cycles during a background job',   :major],
      ['ruby.job.gc_minor_count',    '{gc}',     'Minor GC cycles during a background job',   :minor]
    ].freeze

    class << self
      def snapshot
        [
          GC.stat(:total_allocated_objects),
          GC.stat(:time),
          GC.stat(:major_gc_count),
          GC.stat(:minor_gc_count)
        ]
      rescue StandardError
        nil
      end

      def record_request(snap, controller:, action:)
        return unless snap

        record(REQUEST_METRICS, deltas(snap), 'controller' => controller, 'action' => action)
      end

      def record_job(snap, job_class:, queue: nil)
        return unless snap

        attrs = { 'job_class' => job_class }
        attrs['queue'] = queue if queue
        record(JOB_METRICS, deltas(snap), attrs)
      end

      # Test hook — forces re-resolution of the Meter. Tests that swap the
      # meter provider call this; production code does not.
      def reset!
        @instruments = nil
      end

      private

      def deltas(snap)
        {
          objects: GC.stat(:total_allocated_objects) - snap[0],
          gc_ms: GC.stat(:time) - snap[1],
          major: GC.stat(:major_gc_count) - snap[2],
          minor: GC.stat(:minor_gc_count) - snap[3]
        }
      end

      def record(specs, deltas, attrs)
        bucket = instruments
        specs.each do |name, _unit, _desc, key|
          value = deltas[key]
          next unless value.positive?

          bucket[name].record(value, attributes: attrs)
        end
      rescue StandardError
        nil
      end

      def instruments
        @instruments ||= build_instruments
      end

      def build_instruments
        m = RailsOtelContext.meter
        bucket = Hash.new(NoopInstrument.instance)
        return bucket unless m.respond_to?(:create_histogram)

        (REQUEST_METRICS + JOB_METRICS).each do |name, unit, desc, _key|
          bucket[name] = m.create_histogram(name, unit: unit, description: desc)
        end
        bucket
      rescue StandardError
        Hash.new(NoopInstrument.instance)
      end
    end

    # Shared fallback used when no meter provider is configured. Zero-cost
    # recording so call sites stay branchless.
    class NoopInstrument
      include Singleton

      def record(_value, attributes: nil); end
    end
  end
end
