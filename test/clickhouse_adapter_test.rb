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

  private

  def select_all_client(app_root: Dir.pwd)
    patch = RailsOtelContext::Adapters::Clickhouse.send(:build_patch_module, [:select_all])
    patch.configure(app_root: app_root)
    klass = Class.new { def select_all(_sql) = [] }
    klass.prepend(patch)
    klass.new
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
