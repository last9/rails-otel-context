# frozen_string_literal: true

module RailsOtelContext
  # Background thread that emits process.runtime.ruby.* gauges at a fixed
  # interval. Names follow OTel semantic conventions so backends with built-in
  # Ruby runtime panels surface them without additional configuration.
  #
  # RSS is read from /proc/self/status on Linux. On macOS / Windows the file
  # is absent and RSS emission is silently skipped.
  #
  # Uses synchronous Gauge instruments rather than async observables — the
  # Ruby metrics SDK's observable callback API still differs across minor
  # versions, and once-per-interval overhead is negligible.
  class ProcessSampler
    LINUX_STATUS_PATH = '/proc/self/status'

    GAUGE_SPECS = [
      [:rss,          'process.runtime.ruby.memory.rss',          'By',       'Resident set size of the Ruby process'],
      [:live_slots,   'process.runtime.ruby.gc.heap.live_slots',  '{slot}',   'Live slots on the Ruby GC heap'],
      [:free_slots,   'process.runtime.ruby.gc.heap.free_slots',  '{slot}',   'Free slots on the Ruby GC heap'],
      [:major,        'process.runtime.ruby.gc.major_count',      '{gc}',     'Cumulative major GC cycles'],
      [:minor,        'process.runtime.ruby.gc.minor_count',      '{gc}',     'Cumulative minor GC cycles'],
      [:alloc_objects, 'process.runtime.ruby.allocated_objects',  '{object}', 'Cumulative objects allocated']
    ].freeze

    class << self
      # An interval of 0 or nil disables the sampler entirely.
      def start(interval_sec:, role: nil)
        return unless interval_sec&.positive?
        return if @thread&.alive?

        @role = role || infer_role
        @common_attrs = { 'role' => @role, 'pid' => Process.pid }.freeze
        @rss_supported = File.exist?(LINUX_STATUS_PATH)
        @interval = interval_sec
        @stop = false
        build_instruments

        @thread = Thread.new { loop_emit }
      end

      def stop
        @stop = true
        @thread&.wakeup if @thread&.alive?
        @thread&.join(1)
        @thread = nil
      end

      private

      def infer_role
        return 'sidekiq' if defined?(Sidekiq) && Sidekiq.server?
        return 'web'     if defined?(Puma) || defined?(Rack::Handler)

        'ruby'
      end

      def loop_emit
        Thread.current.name = 'rails_otel_context.process_sampler'
        emit
        until @stop
          sleep @interval
          break if @stop

          emit
        end
      end

      def build_instruments
        m = RailsOtelContext.meter
        @instruments = {}
        GAUGE_SPECS.each do |key, name, unit, desc|
          @instruments[key] = build_gauge(m, name, unit, desc)
        end
      end

      def build_gauge(meter_obj, name, unit, desc)
        return nil unless meter_obj

        if meter_obj.respond_to?(:create_gauge)
          meter_obj.create_gauge(name, unit: unit, description: desc)
        else
          meter_obj.create_histogram(name, unit: unit, description: desc)
        end
      rescue StandardError
        nil
      end

      def emit
        record(:rss,           rss_bytes)
        record(:live_slots,    GC.stat(:heap_live_slots))
        record(:free_slots,    GC.stat(:heap_free_slots))
        record(:major,         GC.stat(:major_gc_count))
        record(:minor,         GC.stat(:minor_gc_count))
        record(:alloc_objects, GC.stat(:total_allocated_objects))
      rescue StandardError
        nil
      end

      def record(key, value)
        return unless value

        @instruments[key]&.record(value, attributes: @common_attrs)
      end

      def rss_bytes
        return nil unless @rss_supported

        File.foreach(LINUX_STATUS_PATH) do |line|
          next unless line.start_with?('VmRSS:')

          return line.split[1].to_i * 1024
        end
        nil
      rescue StandardError
        nil
      end
    end
  end
end
