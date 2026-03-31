# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Redis
      module_function

      def install!(app_root:)
        return unless defined?(::RedisClient::Middlewares)
        return unless defined?(::OpenTelemetry::Instrumentation::Redis)

        patch_module = patch_module_for
        patch_module.configure(app_root: app_root)

        return if ::RedisClient::Middlewares.ancestors.include?(patch_module)

        ::RedisClient::Middlewares.prepend(patch_module)
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

          define_method(:call) do |command, redis_config, &block|
            site = mod.call_site_for_app
            return super(command, redis_config, &block) unless site

            attrs = {
              'code.namespace' => site[:class_name],
              'code.function'  => site[:method_name],
              'code.filepath'  => site[:filepath],
              'code.lineno'    => site[:lineno]
            }.compact
            OpenTelemetry::Instrumentation::Redis.with_attributes(attrs) do
              super(command, redis_config, &block)
            end
          end

          define_method(:call_pipelined) do |commands, redis_config, &block|
            site = mod.call_site_for_app
            return super(commands, redis_config, &block) unless site

            attrs = {
              'code.namespace' => site[:class_name],
              'code.function'  => site[:method_name],
              'code.filepath'  => site[:filepath],
              'code.lineno'    => site[:lineno]
            }.compact
            OpenTelemetry::Instrumentation::Redis.with_attributes(attrs) do
              super(commands, redis_config, &block)
            end
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
