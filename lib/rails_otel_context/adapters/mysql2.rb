# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Mysql2
      module_function

      def install!(app_root:)
        return unless defined?(::Mysql2::Client)

        patch_module = patch_module_for
        patch_module.configure(app_root: app_root)

        return if ::Mysql2::Client.ancestors.include?(patch_module)

        ::Mysql2::Client.prepend(patch_module)
      end

      def patch_module_for
        @patch_module ||= build_patch_module
      end

      def build_patch_module
        mod = Module.new do
          class << self
            include RailsOtelContext::SourceLocation

            attr_accessor :app_root

            def configure(app_root:)
              @app_root = app_root.to_s
            end
          end

          # AR context and span renaming handled by CallContextProcessor.apply_db_context.
          # This adapter adds source location to every query span.
          define_method(:query) do |sql, options = {}|
            source = mod.source_location_for_app
            result = super(sql, options)

            span = OpenTelemetry::Trace.current_span
            if span.context.valid? && source
              span.set_attribute('code.filepath', source[0])
              span.set_attribute('code.lineno', source[1])
            end

            result
          end

          define_method(:prepare) do |sql|
            source = mod.source_location_for_app
            result = super(sql)

            span = OpenTelemetry::Trace.current_span
            if span.context.valid? && source
              span.set_attribute('code.filepath', source[0])
              span.set_attribute('code.lineno', source[1])
            end

            result
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
