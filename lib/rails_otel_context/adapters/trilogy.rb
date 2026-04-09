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

          # Push call-site into FrameContext BEFORE super so the OTel child span
          # created inside super picks it up via CallContextProcessor#on_start.
          # The old approach (apply_call_site_to_span after super) targeted
          # current_span which had already reverted to the parent.
          define_method(:query) do |sql|
            site = mod.call_site_for_app
            if site
              RailsOtelContext::FrameContext.push(
                class_name: site[:class_name], method_name: site[:method_name],
                filepath: site[:filepath], lineno: site[:lineno]
              )
            end
            super(sql)
          ensure
            RailsOtelContext::FrameContext.pop if site
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
