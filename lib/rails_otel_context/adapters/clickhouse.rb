# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Clickhouse
      module_function

      CANDIDATE_METHODS = %i[query select insert execute command].freeze
      REENTRANCY_KEY = :_rails_otel_ctx_clickhouse_instrumenting

      def install!(app_root:, **)
        begin
          require 'click_house'
        rescue LoadError
          # ClickHouse client gem is optional for consumers.
        end

        target_clients.each do |klass|
          methods = CANDIDATE_METHODS.select { |method_name| klass.method_defined?(method_name) }
          next if methods.empty?

          patch_module = patch_module_for(klass, methods)
          patch_module.configure(app_root: app_root)
          next if klass.ancestors.include?(patch_module)

          klass.prepend(patch_module)
        end
      end

      def target_clients
        clients = []

        clients << ::ClickHouse::Client if defined?(::ClickHouse::Client)
        clients << ::ClickHouse::Connection if defined?(::ClickHouse::Connection)
        clients << ::Clickhouse::Client if defined?(::Clickhouse::Client)

        clients.uniq
      end

      def patch_module_for(klass, methods)
        @patch_modules ||= {}
        key = [klass.name, methods.sort].join(':')
        @patch_modules[key] ||= build_patch_module(methods)
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

          # AR context and span renaming handled by CallContextProcessor.apply_db_context.
          reentrancy_key = RailsOtelContext::Adapters::Clickhouse::REENTRANCY_KEY

          methods.each do |method_name|
            operation = method_name.to_s.upcase.freeze

            define_method(method_name) do |*args, &block|
              return super(*args, &block) if Thread.current[reentrancy_key]

              site      = mod.call_site_for_app
              statement = args.first.is_a?(String) ? args.first : nil

              tracer = OpenTelemetry.tracer_provider.tracer('rails-otel-context-clickhouse')
              Thread.current[reentrancy_key] = true

              tracer.in_span("#{operation} clickhouse", kind: :client) do |span|
                span.set_attribute('db.system', 'clickhouse')
                span.set_attribute('db.operation', operation)
                span.set_attribute('db.statement', statement) if statement

                result = super(*args, &block)
                mod.apply_call_site_to_span(span, site)
                result
              end
            ensure
              Thread.current[reentrancy_key] = false
            end
          end
        end

        mod
      end
      private_class_method :build_patch_module
    end
  end
end
