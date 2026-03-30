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
          %i[query prepare].each do |method_name|
            define_method(method_name) do |*args|
              result = super(*args)
              mod.apply_call_site_to_span(OpenTelemetry::Trace.current_span, mod.call_site_for_app)
              result
            end
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
