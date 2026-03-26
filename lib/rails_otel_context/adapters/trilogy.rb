# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Trilogy
      module_function

      def install!(app_root:, threshold_ms:)
        return unless defined?(::Trilogy)

        patch_module = patch_module_for
        patch_module.configure(app_root: app_root, threshold_ms: threshold_ms)

        return if ::Trilogy.ancestors.include?(patch_module)

        ::Trilogy.prepend(patch_module)
      end

      def patch_module_for
        @patch_module ||= build_patch_module
      end

      def build_patch_module
        mod = Module.new do
          class << self
            attr_accessor :app_root, :threshold_ms

            def configure(app_root:, threshold_ms:)
              @app_root = app_root.to_s
              @threshold_ms = threshold_ms.to_f
            end

            def source_location_for_app
              return unless Thread.respond_to?(:each_caller_location)

              Thread.each_caller_location do |location|
                path = location.absolute_path || location.path
                next unless path&.start_with?(app_root)
                next if path.include?('/gems/')

                return [path.delete_prefix("#{app_root}/"), location.lineno]
              end

              nil
            end

            def activerecord_context
              RailsOtelContext::ActiveRecordContext.extract(app_root: app_root)
            end
          end

          define_method(:query) do |sql|
            ar_context = mod.activerecord_context
            source = mod.source_location_for_app

            # Store AR context in thread-local for the CallContextProcessor's
            # on_start hook, which fires when OTel creates the DB span inside super.
            Thread.current[:_rails_otel_ctx_ar] = ar_context
            Thread.current[:_rails_otel_ctx_src] = source

            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = super(sql)
            duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0

            # Also try to apply directly (works when prepend order is correct)
            span = OpenTelemetry::Trace.current_span
            if span.context.valid?
              config = RailsOtelContext.configuration

              if ar_context && config.span_name_formatter
                begin
                  new_name = config.span_name_formatter.call(span.name, ar_context)
                  span.update_name(new_name) if new_name && new_name != span.name
                rescue StandardError
                end
              end

              if ar_context
                span.set_attribute('code.activerecord.model', ar_context[:model_name]) if ar_context[:model_name]
                span.set_attribute('code.activerecord.method', ar_context[:method_name]) if ar_context[:method_name]
              end

              threshold = config.trilogy_slow_query_threshold_ms
              if source && duration_ms >= threshold
                span.set_attribute('code.filepath', source[0])
                span.set_attribute('code.lineno', source[1])
                span.set_attribute('db.query.duration_ms', duration_ms.round(1))
                span.set_attribute('db.query.slow_threshold_ms', threshold)
              end
            end

            result
          ensure
            Thread.current[:_rails_otel_ctx_ar] = nil
            Thread.current[:_rails_otel_ctx_src] = nil
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
