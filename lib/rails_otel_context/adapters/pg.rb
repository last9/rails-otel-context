# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module PG
      module_function

      def install!(app_root:)
        return unless defined?(::PG::Connection)

        methods = exec_methods
        return if methods.empty?

        patch_module = patch_module_for(methods)
        patch_module.configure(app_root: app_root)

        return if ::PG::Connection.ancestors.include?(patch_module)

        ::PG::Connection.prepend(patch_module)
      end

      def exec_methods
        return [] unless defined?(::PG::Constants::EXEC_ISH_METHODS)
        return [] unless defined?(::PG::Constants::EXEC_PREPARED_ISH_METHODS)

        (::PG::Constants::EXEC_ISH_METHODS + ::PG::Constants::EXEC_PREPARED_ISH_METHODS).uniq
      end

      def patch_module_for(methods)
        @patch_module ||= build_patch_module(methods)
      end

      def build_patch_module(methods)
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
          methods.each do |method_name|
            define_method(method_name) do |*args, &user_block|
              mod.with_call_site_frame do
                super(*args) do |result|
                  user_block ? user_block.call(result) : result
                end
              end
            end
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
