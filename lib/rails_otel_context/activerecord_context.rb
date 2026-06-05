# frozen_string_literal: true

module RailsOtelContext
  # Extracts ActiveRecord model name, method, and scope from sql.active_record
  # notifications and scope instrumentation.
  #
  # Two mechanisms work together:
  # 1. sql.active_record subscriber — captures model name + AR operation type
  #    (e.g., "Transaction Load") at query time via payload[:name].
  # 2. Scope tracking — wraps scope-generated methods to store the scope name
  #    on the Relation object, then captures it at materialization time via
  #    Relation#exec_queries. This handles lazy scopes like
  #    Transaction.recent_completed.to_a where the scope method returns before
  #    SQL fires.
  module ActiveRecordContext # rubocop:disable Metrics/ModuleLength
    THREAD_KEY              = :_rails_otel_ctx_ar
    SCOPE_THREAD_KEY        = :_rails_otel_ctx_scope
    PENDING_PREPARE_KEY     = :_rails_otel_ctx_pending_prepare_spans
    DB_SLOW_ATTR            = 'db.slow'
    private_constant :THREAD_KEY, :SCOPE_THREAD_KEY, :PENDING_PREPARE_KEY

    # Frozen regex — only the verb regex remains; table extraction uses index+slice.
    SQL_VERB_RE = /\A(\w+)/i
    private_constant :SQL_VERB_RE

    # Keywords for table extraction — frozen literals searched with index+slice.
    # Rails-generated SQL uses uppercase keywords, covering counter caches and touch_later.
    KW_UPDATE = 'UPDATE '
    KW_INTO   = 'INTO '
    KW_FROM   = 'FROM '
    private_constant :KW_UPDATE, :KW_INTO, :KW_FROM

    # Byte values used in extract_table_after for delimiter detection.
    BYTE_BACKTICK = 96  # `
    BYTE_DQUOTE   = 34  # "
    BYTE_SQUOTE   = 39  # '
    BYTE_SPACE    = 32  # (space)
    BYTE_COMMA    = 44  # ,
    private_constant :BYTE_BACKTICK, :BYTE_DQUOTE, :BYTE_SQUOTE, :BYTE_SPACE, :BYTE_COMMA

    # Tracks class methods (def self.name) that return an AR::Relation so their
    # name is captured as code.activerecord.scope, complementing ScopeNameTracking
    # which only handles the scope macro. Uses singleton_method_added to intercept
    # methods after definition and source_location to skip Rails/gem internals.
    module ClassMethodScopeTracking
      def singleton_method_added(name)
        super

        # Internal aliases created below (and by ScopeNameTracking) re-trigger
        # this hook; wrapping them would route calls back through the wrapper
        # and break receiver dispatch.
        return if name.to_s.start_with?('__otel')

        @_otel_wrapped_class_methods ||= {}
        return if @_otel_wrapped_class_methods[name]

        app_root = RailsOtelContext::ActiveRecordContext.app_root
        return unless app_root

        begin
          loc = method(name).source_location
        rescue NameError
          return
        end
        loc_path = File.expand_path(loc[0])
        return unless loc_path.start_with?(app_root)
        return if loc_path.include?('/gems/')

        # Mark before define_singleton_method to prevent re-entrancy for this name
        @_otel_wrapped_class_methods[name] = true
        name_str   = name.to_s.freeze
        alias_name = :"__otel_cm_orig_#{name}"
        # Alias instead of capturing a bound Method so inherited class methods
        # keep self = the actual receiver (see ScopeNameTracking).
        singleton_class.alias_method(alias_name, name)

        define_singleton_method(name) do |*args, **kwargs, &blk|
          result = send(alias_name, *args, **kwargs, &blk)
          if defined?(::ActiveRecord::Relation) && result.is_a?(::ActiveRecord::Relation)
            result.instance_variable_set(:@_otel_scope_name, name_str)
          end
          result
        end
      rescue StandardError
        nil
      end
    end

    # Subscriber for sql.active_record notifications.
    class Subscriber
      def start(_name, _id, payload)
        ar_name = payload[:name]
        return if ar_name == 'SCHEMA' || ar_name&.start_with?('CACHE')

        ctx = if ar_name.nil? || ar_name == 'SQL'
                ActiveRecordContext.parse_sql_context(payload[:sql])
              else
                ActiveRecordContext.parse_ar_name(ar_name)
              end
        return unless ctx

        # Include scope name if one was captured by RelationScopeCapture
        scope = Thread.current[SCOPE_THREAD_KEY]
        ctx[:scope_name] = scope if scope

        query_key = ctx[:query_key]
        counts = (Thread.current[RequestContext::QUERY_COUNT_KEY] ||= {})
        count = (counts[query_key] = (counts[query_key] || 0) + 1)
        ctx[:query_count] = count if count > 1

        ctx[:async] = true if payload[:async]
        Thread.current[THREAD_KEY] = ctx

        return unless defined?(OpenTelemetry::Trace)

        # Enrich the current span directly. When OTel instruments via driver-level
        # prepend (Trilogy, PG, Mysql2), the span is created BEFORE this notification
        # fires, so CallContextProcessor#on_start sees nil AR context. Applying here
        # fixes those spans after the fact.
        ActiveRecordContext.apply_to_span(OpenTelemetry::Trace.current_span, ctx)

        # Retroactively enrich any PREPARE spans that finished before this notification
        # fired. PG's prepared-statement flow sends PREPARE then EXECUTE as separate wire
        # operations; the PREPARE span finishes before sql.active_record starts, so it
        # never sees AR context. CallContextProcessor#on_finish stashes those spans here.
        pending = Thread.current[PENDING_PREPARE_KEY]
        return unless pending

        pending.each { |s| ActiveRecordContext.retroactively_apply_to_span(s, ctx) }
        Thread.current[PENDING_PREPARE_KEY] = nil
      end

      def finish(_name, _id, _payload)
      ensure
        Thread.current[THREAD_KEY] = nil
        Thread.current[PENDING_PREPARE_KEY] = nil # clear any leftovers from skipped notifications
      end
    end

    # Wraps scope-generated class methods to store the scope name on the Relation.
    module ScopeNameTracking
      def scope(name, body, &)
        super

        # Guard against double-wrapping on class reload in development
        @_otel_wrapped_scopes ||= {}
        return if @_otel_wrapped_scopes[name]

        name_str   = name.to_s.freeze
        alias_name = :"__otel_scope_orig_#{name}"
        # Alias instead of capturing a bound Method: a bound Method locks self
        # to the defining class, so inherited scopes would run with self =
        # parent and re-evaluate default_scope in the wrong class context.
        # send(alias_name) dispatches with self = the actual receiver.
        singleton_class.alias_method(alias_name, name)
        define_singleton_method(name) do |*args, **kwargs, &blk|
          relation = send(alias_name, *args, **kwargs, &blk)
          if relation.is_a?(::ActiveRecord::Relation)
            relation.instance_variable_set(:@_otel_scope_name, name_str)
          end
          relation
        end
        @_otel_wrapped_scopes[name] = true
      end
    end

    # Captures scope name from Relation at SQL materialization time.
    module RelationScopeCapture
      def exec_queries(&)
        scope_name = instance_variable_get(:@_otel_scope_name)
        Thread.current[SCOPE_THREAD_KEY] = scope_name if scope_name
        super
      ensure
        Thread.current[SCOPE_THREAD_KEY] = nil
      end
    end

    module_function

    def install!(app_root: nil)
      @app_root = File.expand_path(app_root.to_s) if app_root

      return unless defined?(::ActiveSupport::Notifications)
      return unless defined?(::ActiveRecord::Base)

      ActiveSupport::Notifications.subscribe('sql.active_record', Subscriber.new)
      ::ActiveRecord::Base.extend(ScopeNameTracking)
      ::ActiveRecord::Base.extend(ClassMethodScopeTracking)
      ::ActiveRecord::Relation.prepend(RelationScopeCapture)
    end

    def app_root
      @app_root
    end

    def current
      Thread.current[THREAD_KEY]
    end

    def clear!
      Thread.current[THREAD_KEY]          = nil
      Thread.current[SCOPE_THREAD_KEY]    = nil
      Thread.current[PENDING_PREPARE_KEY] = nil
    end

    # Called from CallContextProcessor#on_finish when a PREPARE span finishes
    # before its sql.active_record notification. Stashed spans are flushed by
    # Subscriber#start when the notification fires.
    def stash_prepare_span(span)
      (Thread.current[PENDING_PREPARE_KEY] ||= []) << span
    end

    # Test helpers: set AR context directly for unit tests.
    def stub_context(context)
      Thread.current[THREAD_KEY] = context
    end

    def stub_scope(scope_name)
      Thread.current[SCOPE_THREAD_KEY] = scope_name
    end

    # Retroactively applies AR context to a finished span (e.g. PREPARE spans that
    # finished before sql.active_record fired). Uses direct @attributes mutation
    # because span.recording? is false — set_attribute would be a no-op.
    def retroactively_apply_to_span(span, ctx)
      attrs = span.instance_variable_get(:@attributes)
      return unless attrs.respond_to?(:store)

      attrs.store('code.activerecord.model',  ctx[:model_name])  if ctx[:model_name]
      attrs.store('code.activerecord.method', ctx[:method_name]) if ctx[:method_name]
      attrs.store('code.activerecord.scope',  ctx[:scope_name])  if ctx[:scope_name]

      formatter = RailsOtelContext.configuration.span_name_formatter
      return unless formatter && span.respond_to?(:name) && attrs.key?('db.system')

      ar_ctx = ctx.dup
      ar_ctx[:code_namespace] = attrs['code.namespace']
      ar_ctx[:code_function]  = attrs['code.function']

      original_name = span.name
      new_name = formatter.call(original_name, ar_ctx)
      return unless new_name && new_name != original_name

      attrs.store('l9.orig.name', original_name)
      span.instance_variable_set(:@name, new_name)
    rescue StandardError
      nil
    end

    # Applies AR context directly to a span. Used by Subscriber#start to enrich spans
    # created by driver-level OTel instrumentation (Trilogy, PG) before our notification
    # subscriber runs. Also reads code.namespace/code.function already set by
    # CallContextProcessor#on_start so the span_name_formatter has full context.
    def apply_to_span(span, ctx)
      return unless span.context.valid?

      span.set_attribute('code.activerecord.model', ctx[:model_name]) if ctx[:model_name]
      span.set_attribute('code.activerecord.method', ctx[:method_name]) if ctx[:method_name]
      span.set_attribute('code.activerecord.scope', ctx[:scope_name]) if ctx[:scope_name]
      span.set_attribute('db.query_count', ctx[:query_count]) if ctx[:query_count]
      span.set_attribute('db.async', true) if ctx[:async]

      formatter = RailsOtelContext.configuration.span_name_formatter
      return unless formatter
      return unless span.respond_to?(:attributes) && span.attributes&.key?('db.system')

      # Dup deferred to here: set_attribute calls above need only the original ctx keys.
      # The formatter may inspect code.namespace/code.function already on the span.
      ar_ctx = ctx.dup
      if span.respond_to?(:attributes)
        ar_ctx[:code_namespace] = span.attributes['code.namespace']
        ar_ctx[:code_function]  = span.attributes['code.function']
      end

      original_name = span.name
      new_name = formatter.call(original_name, ar_ctx)
      return unless new_name && new_name != original_name && span.respond_to?(:name=)

      span.set_attribute('l9.orig.name', original_name)
      span.name = new_name
    rescue StandardError
      nil
    end

    # Parses "Transaction Load" → { model_name: "Transaction", method_name: "Load" }
    # Uses index+byteslice instead of split to avoid allocating the intermediate Array
    # and two String copies — saves 1 alloc (Array) vs split which returns Array+Strings
    # but with frozen_string_literal the slice shares storage on MRI 3.2+.
    def parse_ar_name(name)
      return nil unless name

      idx = name.index(' ')
      return nil unless idx

      model_name  = name[0, idx]
      method_name = name[idx + 1, name.length]

      return nil if model_name == 'ActiveRecord'

      { model_name: model_name, method_name: method_name,
        query_key: "#{model_name}.#{method_name}".freeze }
    end

    # Parses raw SQL (payload[:name] == "SQL") to extract model context.
    # Used for counter cache updates, touch_later, and connection.execute calls
    # that fire sql.active_record with name="SQL" rather than "Model Method".
    #
    # Returns nil when the table cannot be mapped to a known AR model, so callers
    # fall through to the existing skip path.
    def parse_sql_context(sql)
      return nil unless sql

      verb = sql[SQL_VERB_RE, 1]&.capitalize
      return nil unless verb

      keyword = case verb
                when 'Update'          then KW_UPDATE
                when 'Insert'          then KW_INTO
                when 'Delete', 'Select' then KW_FROM
                end
      return nil unless keyword

      table      = extract_table_after(sql, keyword)
      model_name = table ? ar_table_model_map[table] : nil

      # Fall back to the virtual "SQL" model when the table cannot be resolved
      # (e.g. SELECT SLEEP(0.2), SELECT 1, raw DDL). This lets the span-name
      # formatter produce "SQL.Select" / "SQL.Update" for tab-group purposes
      # instead of leaving the span unnamed.
      model_name ||= 'SQL'

      { model_name: model_name, method_name: verb,
        query_key: "#{model_name}.#{verb}".freeze }
    end

    # Extracts a table name from +sql+ starting after +keyword+.
    # Skips one optional leading quote character (` " '), reads word chars until
    # the next delimiter (space, quote, comma). Returns nil when keyword not found.
    # Saves 1 alloc vs regex: index()+slice allocates only the result String.
    def extract_table_after(sql, keyword)
      idx = sql.index(keyword)
      return nil unless idx

      start = idx + keyword.length
      first = sql.getbyte(start)
      start += 1 if first == BYTE_BACKTICK || first == BYTE_DQUOTE || first == BYTE_SQUOTE # rubocop:disable Style/MultipleComparison

      stop = start
      stop += 1 while stop < sql.length &&
                      (b = sql.getbyte(stop)) != BYTE_SPACE &&
                      b != BYTE_BACKTICK && b != BYTE_DQUOTE && b != BYTE_SQUOTE && b != BYTE_COMMA

      stop > start ? sql[start, stop - start] : nil
    end

    # Lazy table_name → model_name index. Built on first use after all models are
    # loaded (eager_load! in production). In development, call reset_ar_table_model_map!
    # after a code reload to get a fresh index.
    def ar_table_model_map
      @ar_table_model_map ||= begin
        next_map = {}
        if defined?(::ActiveRecord::Base)
          ::ActiveRecord::Base.descendants.each do |m|
            model_name = begin
              m.name
            rescue StandardError
              next
            end
            next unless model_name
            # Skip STI subclasses — they share the parent's table_name.
            # Without this guard, AdminUser < User would overwrite users → User
            # with users → AdminUser in the map, giving wrong model names on
            # SQL-named spans (counter caches, update_all).
            next unless m.base_class == m

            table = begin
              m.table_name
            rescue StandardError
              next
            end
            next unless table

            next_map[table] = model_name
          end
        end
        next_map
      end
    end

    def reset_ar_table_model_map!
      @ar_table_model_map = nil
    end
  end
end
