# frozen_string_literal: true

require_relative 'test_helper'
require 'active_record'

# Integration tests for adapter install! methods.
#
# Each adapter guards on a gem constant (e.g. defined?(::PG::Connection)).
# Tests that require a gem that isn't installed skip automatically.
# Tests that don't need the real gem define a minimal stub class, install
# the adapter, then verify: (a) the patch module is prepended, and
# (b) the patched method propagates FrameContext correctly.
class AdapterInstallIntegrationTest < Minitest::Test
  include CallerLocationHelpers

  APP_ROOT = File.expand_path('fixtures', __dir__)

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Temporarily defines a nested constant path and yields, removing all
  # added constants on exit.  E.g. stub_const(PG: { Connection: klass })
  # defines ::PG and ::PG::Connection for the block duration.
  def with_stub_consts(tree, parent = Object, &block)
    created = []
    nested  = false

    tree.each do |name, value|
      if value.is_a?(Hash)
        nested = true
        if parent.const_defined?(name, false)
          with_stub_consts(value, parent.const_get(name, false), &block)
        else
          mod = Module.new
          parent.const_set(name, mod)
          created << [parent, name]
          with_stub_consts(value, mod, &block)
        end
        break
      else
        next if parent.const_defined?(name, false)

        parent.const_set(name, value)
        created << [parent, name]
      end
    end

    yield unless nested
  ensure
    created.reverse_each { |p, n| p.send(:remove_const, n) if p.const_defined?(n, false) }
  end

  # ── PG adapter ───────────────────────────────────────────────────────────

  def test_pg_install_skips_when_pg_not_defined
    # Real PG likely not installed in test env; this verifies the early-return guard.
    skip 'PG already defined' if defined?(::PG::Connection)
    assert_nil RailsOtelContext::Adapters::PG.install!(app_root: APP_ROOT)
  end

  def test_pg_install_prepends_patch_module_to_connection
    skip 'PG already defined (would conflict)' if defined?(::PG::Connection)

    exec_methods = %i[exec exec_params]

    pg_connection_class = Class.new do
      exec_methods.each { |m| define_method(m) { |*| :real_result } }
    end

    pg_constants_mod = Module.new do
      const_set(:EXEC_ISH_METHODS,          exec_methods)
      const_set(:EXEC_PREPARED_ISH_METHODS, [])
    end

    with_stub_consts({ PG: { Constants: pg_constants_mod, Connection: pg_connection_class } }) do
      RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
      RailsOtelContext::Adapters::PG.install!(app_root: APP_ROOT)
      assert ::PG::Connection.ancestors.include?(RailsOtelContext::Adapters::PG.instance_variable_get(:@patch_module)),
             'PG::Connection must have patch module in ancestors after install!'
    end
  ensure
    RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
  end

  def test_pg_install_is_idempotent
    skip 'PG already defined (would conflict)' if defined?(::PG::Connection)

    exec_methods  = %i[exec]
    pg_conn_class = Class.new { define_method(:exec) { |*| :ok } }
    pg_consts_mod = Module.new do
      const_set(:EXEC_ISH_METHODS,          exec_methods)
      const_set(:EXEC_PREPARED_ISH_METHODS, [])
    end

    with_stub_consts({ PG: { Constants: pg_consts_mod, Connection: pg_conn_class } }) do
      RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
      RailsOtelContext::Adapters::PG.install!(app_root: APP_ROOT)
      ancestors_before = ::PG::Connection.ancestors.dup
      RailsOtelContext::Adapters::PG.install!(app_root: APP_ROOT)
      assert_equal ancestors_before, ::PG::Connection.ancestors,
                   'Second install! must not modify ancestors'
    end
  ensure
    RailsOtelContext::Adapters::PG.instance_variable_set(:@patch_module, nil)
  end

  # ── MySQL2 adapter ───────────────────────────────────────────────────────

  def test_mysql2_install_skips_when_not_defined
    skip 'Mysql2 already defined' if defined?(::Mysql2::Client)
    assert_nil RailsOtelContext::Adapters::Mysql2.install!(app_root: APP_ROOT)
  end

  def test_mysql2_install_prepends_patch_module
    skip 'Mysql2 already defined (would conflict)' if defined?(::Mysql2::Client)

    mysql2_client = Class.new do
      def query(_sql) = :result
      def prepare(_sql) = :stmt
    end

    with_stub_consts({ Mysql2: { Client: mysql2_client } }) do
      RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
      RailsOtelContext::Adapters::Mysql2.install!(app_root: APP_ROOT)
      assert ::Mysql2::Client.ancestors.include?(RailsOtelContext::Adapters::Mysql2.instance_variable_get(:@patch_module)),
             'Mysql2::Client must have patch module prepended'
    end
  ensure
    RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
  end

  def test_mysql2_patched_query_sets_frame_context
    skip 'Mysql2 already defined (would conflict)' if defined?(::Mysql2::Client)

    captured_frame = nil
    mysql2_client  = Class.new do
      define_method(:query) do |_sql|
        captured_frame = RailsOtelContext::FrameContext.current
        :result
      end
    end

    with_stub_consts({ Mysql2: { Client: mysql2_client } }) do
      RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
      RailsOtelContext::Adapters::Mysql2.install!(app_root: APP_ROOT)

      abs = File.join(APP_ROOT, 'app/services/order_service.rb')
      loc = OpenStruct.new(absolute_path: abs, path: nil, lineno: 13, label: 'OrderService#create')

      with_multiple_caller_locations([loc]) do
        ::Mysql2::Client.new.query('SELECT 1')
      end
    end

    refute_nil captured_frame
    assert_equal 'OrderService', captured_frame[:class_name]
    assert_equal 'create',       captured_frame[:method_name]
  ensure
    RailsOtelContext::Adapters::Mysql2.instance_variable_set(:@patch_module, nil)
    RailsOtelContext::FrameContext.clear!
  end

  # ── Redis adapter ────────────────────────────────────────────────────────

  def test_redis_install_skips_when_not_defined
    skip 'RedisClient already defined' if defined?(::RedisClient::Middlewares)
    assert_nil RailsOtelContext::Adapters::Redis.install!(app_root: APP_ROOT)
  end

  def test_redis_install_prepends_patch_module
    skip 'RedisClient already defined (would conflict)' if defined?(::RedisClient::Middlewares)

    redis_middlewares = Class.new do
      def call(_command, _config, &block) = block&.call || :ok
      def call_pipelined(_commands, _config, &block) = block&.call || :ok
    end
    otel_redis = Module.new do
      def self.with_attributes(_attrs) = yield
    end

    with_stub_consts({ RedisClient: { Middlewares: redis_middlewares } }) do
      with_stub_consts({ OpenTelemetry: { Instrumentation: { Redis: otel_redis } } }) do
        RailsOtelContext::Adapters::Redis.instance_variable_set(:@patch_module, nil)
        RailsOtelContext::Adapters::Redis.install!(app_root: APP_ROOT)
        assert ::RedisClient::Middlewares.ancestors.include?(RailsOtelContext::Adapters::Redis.instance_variable_get(:@patch_module)),
               'RedisClient::Middlewares must have patch module prepended'
      end
    end
  ensure
    RailsOtelContext::Adapters::Redis.instance_variable_set(:@patch_module, nil)
  end

  # ── ConnectionPool adapter ────────────────────────────────────────────────

  def test_connection_pool_install_prepends_patch_module
    # ActiveRecord is always available in this project (it's a dependency).
    return skip 'AR::ConnectionPool not defined' unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool)

    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
    RailsOtelContext::Adapters::ConnectionPool.install!
    patch = RailsOtelContext::Adapters::ConnectionPool.instance_variable_get(:@patch_module)
    assert ::ActiveRecord::ConnectionAdapters::ConnectionPool.ancestors.include?(patch),
           'ConnectionPool must have patch module prepended'
  ensure
    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
  end

  def test_connection_pool_install_is_idempotent
    return skip 'AR::ConnectionPool not defined' unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool)

    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
    RailsOtelContext::Adapters::ConnectionPool.install!
    before = ::ActiveRecord::ConnectionAdapters::ConnectionPool.ancestors.dup
    RailsOtelContext::Adapters::ConnectionPool.install!
    assert_equal before, ::ActiveRecord::ConnectionAdapters::ConnectionPool.ancestors
  ensure
    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
  end

  # ── ClickHouse adapter (real gem if available) ────────────────────────────

  def test_clickhouse_install_with_real_gem
    begin
      require 'click_house'
    rescue LoadError
      skip 'click_house gem not installed'
    end

    RailsOtelContext::Adapters::Clickhouse.instance_variable_set(:@patch_modules, nil)
    RailsOtelContext::Adapters::Clickhouse.install!(app_root: APP_ROOT)

    klass = ::ClickHouse::Connection
    installed = klass.ancestors.any? do |a|
      a.is_a?(Module) && !a.is_a?(Class) &&
        a.respond_to?(:app_root) && a.app_root == APP_ROOT.to_s
    end
    assert installed, 'ClickHouse::Connection must have configured patch module in ancestors'
  ensure
    RailsOtelContext::Adapters::Clickhouse.instance_variable_set(:@patch_modules, nil)
  end
end
