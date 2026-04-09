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

          # Push call-site into FrameContext BEFORE super so the OTel child span
          # created inside super picks it up via CallContextProcessor#on_start.
          %i[query prepare].each do |method_name|
            define_method(method_name) do |*args|
              mod.with_call_site_frame { super(*args) }
            end
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
