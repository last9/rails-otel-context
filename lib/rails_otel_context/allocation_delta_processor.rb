# frozen_string_literal: true

module RailsOtelContext
  # Attaches Ruby allocation and GC deltas to every OTel span.
  #
  # OTel Ruby SDK 1.11 freezes Span#@attributes before calling
  # SpanProcessor#on_finish, so the natural on_finish hook can't write
  # attributes. We prepend onto the Span class instead: snapshot in
  # #initialize, write the delta via set_attribute inside #finish, before
  # super freezes the hash.
  #
  # Attributes written on every finished span:
  #   ruby.alloc.objects   — objects allocated during the span
  #   ruby.gc.time_ms      — GC time during the span
  #   ruby.gc.major_count  — major GC cycles during the span
  #   ruby.gc.minor_count  — minor GC cycles during the span
  #
  # GC.stat is process-global — under threaded Puma, concurrent spans on the
  # same worker smear deltas across each other. p99 ranking still surfaces
  # real offenders.
  module SpanAllocationTracking
    ATTR_OBJECTS    = 'ruby.alloc.objects'
    ATTR_GC_TIME_MS = 'ruby.gc.time_ms'
    ATTR_GC_MAJOR   = 'ruby.gc.major_count'
    ATTR_GC_MINOR   = 'ruby.gc.minor_count'

    def initialize(...)
      super
      @_roc_snap_objects = GC.stat(:total_allocated_objects)
      @_roc_snap_gc_time = GC.stat(:time)
      @_roc_snap_gc_major = GC.stat(:major_gc_count)
      @_roc_snap_gc_minor = GC.stat(:minor_gc_count)
    rescue StandardError
      @_roc_snap_objects = nil
    end

    def finish(end_timestamp: nil)
      write_allocation_delta
      super
    end

    private

    def write_allocation_delta
      return unless @_roc_snap_objects

      objs  = GC.stat(:total_allocated_objects) - @_roc_snap_objects
      gc_ms = GC.stat(:time) - @_roc_snap_gc_time
      major = GC.stat(:major_gc_count) - @_roc_snap_gc_major
      minor = GC.stat(:minor_gc_count) - @_roc_snap_gc_minor

      set_attribute(ATTR_OBJECTS, objs) if objs.positive?
      set_attribute(ATTR_GC_TIME_MS, gc_ms) if gc_ms.positive?
      set_attribute(ATTR_GC_MAJOR, major) if major.positive?
      set_attribute(ATTR_GC_MINOR, minor) if minor.positive?
    rescue StandardError
      nil
    end
  end

  module AllocationDeltaProcessor
    def self.install!
      return if @installed
      return unless defined?(OpenTelemetry::SDK::Trace::Span)

      OpenTelemetry::SDK::Trace::Span.prepend(SpanAllocationTracking)
      @installed = true
    end
  end
end
