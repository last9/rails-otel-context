# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module ConnectionPool
      TRACER_NAME = 'rails_otel_context'
      SPAN_NAME   = 'active_record.connection_checkout'
      private_constant :TRACER_NAME, :SPAN_NAME

      module_function

      def install!
        return unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool)

        patch_module = patch_module_for
        return if ::ActiveRecord::ConnectionAdapters::ConnectionPool.ancestors.include?(patch_module)

        ::ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(patch_module)
      end

      def patch_module_for
        @patch_module ||= build_patch_module
      end

      def build_patch_module
        # Capture as locals so define_method closes over them — constants declared
        # private_constant are inaccessible from the anonymous module's def scope.
        tracer_name   = TRACER_NAME
        span_name     = SPAN_NAME
        # Cached lazily on first checkout — tracer_provider may not be fully
        # configured when install! runs at boot.
        cached_tracer = nil

        Module.new do
          define_method(:checkout) do |checkout_timeout = @checkout_timeout|
            # Rails 7.2+ fast path: pinned connection bypasses pool wait entirely.
            # No span needed — duration would be ~0ms and it's misleading noise.
            return super(checkout_timeout) if @pinned_connection

            cached_tracer ||= OpenTelemetry.tracer_provider.tracer(tracer_name)

            cached_tracer.in_span(span_name) do |span|
              result = super(checkout_timeout)

              # stat acquires the pool's monitor lock and iterates @connections —
              # acceptable for opt-in diagnostics. Avoid enabling this permanently
              # on high-traffic pools where lock contention is already a concern.
              pool_stat = stat
              span.set_attribute('db.pool.size',    pool_stat[:size])
              span.set_attribute('db.pool.busy',    pool_stat[:busy])
              span.set_attribute('db.pool.idle',    pool_stat[:idle])
              span.set_attribute('db.pool.waiting', pool_stat[:waiting])

              result
            end
          end
        end
      end
      private_class_method :patch_module_for, :build_patch_module
    end
  end
end
