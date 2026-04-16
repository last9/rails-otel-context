# frozen_string_literal: true

require_relative 'test_helper'
require 'ostruct'

class ClickhouseAdapterTest < Minitest::Test
  include CallerLocationHelpers
  include SpanHelpers

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::Clickhouse.instance_variable_set(:@patch_modules, nil)
  end

  def test_query_creates_span_with_source_attributes
    patch = RailsOtelContext::Adapters::Clickhouse.send(:build_patch_module, [:query])
    patch.configure(app_root: Dir.pwd)

    client_class = Class.new do
      def query(_sql)
        :ok
      end
    end
    client_class.prepend(patch)

    with_thread_source('/app/services/warehouse.rb', 14, label: 'WarehouseService#load') do
      with_tracer_spy do |calls|
        result = client_class.new.query('SELECT 1')
        assert_equal :ok, result
        assert_equal 1, calls.size
        span = calls[0]
        assert_equal 'SELECT clickhouse', span[:name] # sql verb extracted, no FROM table
        assert_equal :client, span[:kind]
        assert_equal 'clickhouse', span[:attributes]['db.system']
        assert_equal 'SELECT', span[:attributes]['db.operation']
        assert_equal 'SELECT 1', span[:attributes]['db.statement']
        assert_equal 'WarehouseService', span[:attributes]['code.namespace']
        assert_equal 'load',                         span[:attributes]['code.function']
        assert_equal 'app/services/warehouse.rb',    span[:attributes]['code.filepath']
        assert_equal 14,                             span[:attributes]['code.lineno']
      end
    end
  end

  # click_house gem v2.x uses select_all / select_one / select_value instead of query/select.
  # Verify the alias map normalises SELECT_ALL → SELECT so span names stay readable.
  def test_select_all_normalized_to_select_verb
    with_thread_source('/app/services/warehouse.rb', 22, label: 'WarehouseService#fetch') do
      with_tracer_spy do |calls|
        select_all_client.select_all('SELECT name FROM system.tables LIMIT 5')
        span = calls[0]
        assert_equal 'SELECT tables', span[:name]
        assert_equal 'clickhouse',    span[:attributes]['db.system']
        assert_equal 'SELECT',        span[:attributes]['db.operation']
      end
    end
  end

  def test_select_all_no_table_falls_back_to_select_clickhouse
    with_tracer_spy do |calls|
      select_all_client.select_all('SELECT 1')
      span = calls[0]
      assert_equal 'SELECT clickhouse', span[:name]
      assert_equal 'SELECT',            span[:attributes]['db.operation']
    end
  end

  def test_query_omits_source_attributes_when_no_app_source
    patch = RailsOtelContext::Adapters::Clickhouse.send(:build_patch_module, [:query])
    patch.configure(app_root: '/unlikely/root')

    client_class = Class.new do
      def query(_sql)
        :ok
      end
    end
    client_class.prepend(patch)

    with_tracer_spy do |calls|
      client_class.new.query('SELECT 1')
      span = calls[0]
      refute span[:attributes].key?('code.filepath')
      refute span[:attributes].key?('code.lineno')
    end
  end

  # ── select_one ────────────────────────────────────────────────────────────

  def test_select_one_normalized_to_select_verb
    with_thread_source('/app/services/warehouse.rb', 5, label: 'WarehouseService#find') do
      with_tracer_spy do |calls|
        select_one_client.select_one('SELECT name FROM system.tables LIMIT 1')
        span = calls[0]
        assert_equal 'SELECT tables', span[:name]
        assert_equal 'SELECT',        span[:attributes]['db.operation']
        assert_equal 'clickhouse',    span[:attributes]['db.system']
      end
    end
  end

  def test_select_one_no_table_falls_back
    with_tracer_spy do |calls|
      select_one_client.select_one('SELECT 1')
      span = calls[0]
      assert_equal 'SELECT clickhouse', span[:name]
    end
  end

  # ── select_value ──────────────────────────────────────────────────────────

  def test_select_value_normalized_to_select_verb
    with_tracer_spy do |calls|
      select_value_client.select_value('SELECT count() FROM events')
      span = calls[0]
      assert_equal 'SELECT events', span[:name]
      assert_equal 'SELECT',        span[:attributes]['db.operation']
    end
  end

  # ── execute ───────────────────────────────────────────────────────────────

  def test_execute_insert_sql_produces_insert_span
    with_tracer_spy do |calls|
      execute_client.execute('INSERT INTO events FORMAT JSONEachRow', '{"id":1}')
      span = calls[0]
      assert_equal 'INSERT events',  span[:name]
      assert_equal 'INSERT',         span[:attributes]['db.operation']
      assert_equal 'clickhouse',     span[:attributes]['db.system']
      assert_equal 'INSERT INTO events FORMAT JSONEachRow', span[:attributes]['db.statement']
    end
  end

  def test_execute_forwards_keyword_args_without_argument_error
    # Regression for https://github.com/last9/rails-otel-context/issues/28:
    # the patch must forward **kwargs so methods with keyword params don't
    # receive them as a stray positional Hash.
    patch = RailsOtelContext::Adapters::Clickhouse.send(:build_patch_module, [:execute])
    patch.configure(app_root: Dir.pwd)

    received_kwargs = nil
    klass = Class.new do
      define_method(:execute) do |_sql, _body = nil, database: nil, params: {}|
        received_kwargs = { database: database, params: params }
        :ok
      end
    end
    klass.prepend(patch)

    with_tracer_spy do
      result = klass.new.execute('SELECT 1', nil, database: 'analytics', params: { max_rows: 100 })
      assert_equal :ok, result
      refute_nil received_kwargs, 'execute stub was never called'
      assert_equal 'analytics',        received_kwargs[:database]
      assert_equal({ max_rows: 100 },  received_kwargs[:params])
    end
  end

  def test_execute_select_sql
    with_tracer_spy do |calls|
      execute_client.execute('SELECT 1')
      span = calls[0]
      assert_equal 'SELECT clickhouse', span[:name]
      assert_equal 'SELECT',            span[:attributes]['db.operation']
    end
  end

  # ── command ───────────────────────────────────────────────────────────────

  def test_command_uses_method_op_as_span_name
    with_tracer_spy do |calls|
      command_client.command('OPTIMIZE TABLE events FINAL')
      span = calls[0]
      assert_equal 'OPTIMIZE clickhouse', span[:name]
      assert_equal 'OPTIMIZE',            span[:attributes]['db.operation']
      assert_equal 'clickhouse',          span[:attributes]['db.system']
    end
  end

  private

  def build_client(method_name, app_root: Dir.pwd, &stub)
    patch = RailsOtelContext::Adapters::Clickhouse.send(:build_patch_module, [method_name])
    patch.configure(app_root: app_root)
    klass = Class.new
    klass.define_method(method_name, stub)
    klass.prepend(patch)
    klass.new
  end

  def select_all_client(app_root: Dir.pwd)
    build_client(:select_all, app_root: app_root) { |_sql| [] }
  end

  def select_one_client(app_root: Dir.pwd)
    build_client(:select_one, app_root: app_root) { |_sql| nil }
  end

  def select_value_client(app_root: Dir.pwd)
    build_client(:select_value, app_root: app_root) { |_sql| nil }
  end

  def execute_client(app_root: Dir.pwd)
    build_client(:execute, app_root: app_root) { |_sql, _body = nil, **_kwargs| :ok }
  end

  def command_client(app_root: Dir.pwd)
    build_client(:command, app_root: app_root) { |_sql| :ok }
  end

  def with_tracer_spy
    calls = []
    fake_tracer = Class.new do
      def initialize(calls)
        @calls = calls
      end

      def in_span(name, kind: nil)
        span = FakeSpan.new
        @calls << { name: name, kind: kind, attributes: span.attributes }
        yield span
      end
    end.new(calls)

    fake_provider = Class.new do
      def initialize(tracer)
        @tracer = tracer
      end

      def tracer(_name)
        @tracer
      end
    end.new(fake_tracer)

    singleton = OpenTelemetry.singleton_class
    singleton.class_eval do
      alias_method :__rails_otel_context_original_tracer_provider, :tracer_provider
      define_method(:tracer_provider) { fake_provider }
    end

    yield calls
  ensure
    singleton.class_eval do
      alias_method :tracer_provider, :__rails_otel_context_original_tracer_provider
      remove_method :__rails_otel_context_original_tracer_provider
    end
  end
end
