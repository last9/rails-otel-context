# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    module Clickhouse
      module_function

      # click_house gem v1.x used :query/:select; v2.x uses :select_all/:select_one/:select_value.
      # We list all known variants so install! picks whichever the loaded gem version defines.
      #
      # insert/insert_rows/insert_compact are intentionally absent: in v2.x they all delegate
      # to execute, so patching execute alone is sufficient and avoids wrapping methods whose
      # keyword-argument signatures may differ across gem versions.
      CANDIDATE_METHODS = %i[
        select_all select_one select_value
        execute command
        query select
      ].freeze
      REENTRANCY_KEY = :_rails_otel_ctx_clickhouse_instrumenting

      def install!(app_root:)
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

      # Maps compound gem method names to their SQL verb for span naming.
      # select_all/select_one/select_value → SELECT.
      METHOD_OP_ALIAS = {
        'SELECT_ALL' => 'SELECT',
        'SELECT_ONE' => 'SELECT',
        'SELECT_VALUE' => 'SELECT'
      }.freeze

      # Derives a human-readable span name from the SQL statement.
      # Follows OTel DB convention: "{sql_verb} {table}".
      # Falls back to "{method_op} clickhouse" when the statement is absent
      # or cannot be parsed (e.g. raw ClickHouse commands with no FROM clause).
      #
      # Accepts an optional pre-parsed +table_name+ to avoid a second regex scan
      # when the caller already holds the result of parse_table.
      def span_name_for(statement, method_op, table_name: nil)
        effective_op = METHOD_OP_ALIAS.fetch(method_op, method_op)
        return "#{effective_op} clickhouse" unless statement.is_a?(String)

        sql_verb   = statement.lstrip.split(/\s/, 2).first&.upcase
        table_name = parse_table(statement).last if table_name.nil?

        if sql_verb && table_name
          "#{sql_verb} #{table_name}"
        elsif sql_verb
          "#{sql_verb} clickhouse"
        else
          "#{effective_op} clickhouse"
        end
      end

      # Returns [db_name, table_name] extracted from the SQL statement.
      # db_name is the schema prefix (e.g. "mailgun_analytics"), nil when absent.
      # table_name is the bare table (e.g. "mailgun_events"), nil when not found.
      def parse_table(statement)
        return [nil, nil] unless statement.is_a?(String)

        qualified = statement.match(/(?:\bFROM\b|\bINTO\b|\bUPDATE\b)\s+([\w.]+)/i)&.captures&.first
        return [nil, nil] unless qualified

        parts = qualified.split('.')
        parts.size > 1 ? [parts[0..-2].join('.'), parts.last] : [nil, parts.first]
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

          reentrancy_key = RailsOtelContext::Adapters::Clickhouse::REENTRANCY_KEY

          methods.each do |method_name|
            method_op = RailsOtelContext::Adapters::Clickhouse::METHOD_OP_ALIAS
                        .fetch(method_name.to_s.upcase, method_name.to_s.upcase)
                        .freeze

            define_method(method_name) do |*args, **kwargs, &block|
              return super(*args, **kwargs, &block) if Thread.current[reentrancy_key]

              Thread.current[reentrancy_key] = true
              begin
                site      = mod.call_site_for_app
                statement = args.first.is_a?(String) ? args.first : nil

                # Avoid a second regex scan: pass pre-parsed table_name to span_name_for,
                # and reuse db_name for the db.name attribute.
                db_name, table_name = RailsOtelContext::Adapters::Clickhouse.parse_table(statement)
                sql_verb  = statement ? statement.lstrip.split(/\s/, 2).first&.upcase || method_op : method_op
                span_name = RailsOtelContext::Adapters::Clickhouse.span_name_for(
                  statement, method_op, table_name: table_name
                )

                tracer = OpenTelemetry.tracer_provider.tracer('rails-otel-context-clickhouse')
                tracer.in_span(span_name, kind: :client) do |span|
                  span.set_attribute('db.system',    'clickhouse')
                  span.set_attribute('db.operation', sql_verb)
                  span.set_attribute('db.statement', statement)   if statement
                  span.set_attribute('db.name',      db_name)     if db_name
                  span.set_attribute('db.sql.table', table_name)  if table_name

                  result = super(*args, **kwargs, &block)
                  mod.apply_call_site_to_span(span, site)

                  # ClickHouse spans don't fire sql.active_record notifications, so
                  # CallContextProcessor#apply_db_context never runs for them.
                  # Apply the span_name_formatter here with a synthetic AR-shaped context
                  # built from code.namespace/code.function set by apply_call_site_to_span.
                  formatter = RailsOtelContext.configuration.span_name_formatter
                  code_ns   = formatter && span.respond_to?(:attributes) &&
                              span.attributes['code.namespace']
                  if code_ns
                    fn = span.attributes['code.function']
                    ar_ctx = { model_name: code_ns, method_name: fn, scope_name: nil,
                               code_namespace: code_ns, code_function: fn }
                    new_name = formatter.call(span_name, ar_ctx)
                    if new_name && new_name != span_name
                      span.set_attribute('l9.orig.name', span_name)
                      span.name = new_name
                    end
                  end

                  result
                end
              ensure
                Thread.current[reentrancy_key] = false
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
