# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Trilogy
      module_function

      def install!(app_root:)
        return unless defined?(::Trilogy)

        patch_module = patch_module_for
        patch_module.configure(app_root: app_root)

        return if ::Trilogy.ancestors.include?(patch_module)

        ::Trilogy.prepend(patch_module)
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
          define_method(:query) do |sql|
            result = super(sql)

            span = OpenTelemetry::Trace.current_span
            mod.apply_source_to_span(span, mod.source_location_for_app) if span.context.valid?

            result
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
