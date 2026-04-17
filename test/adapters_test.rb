# frozen_string_literal: true

require 'test_helper'

class AdaptersTest < Minitest::Test
  def test_rails_otel_context_shim_loads
    # lib/rails/otel/context.rb is a require shim — loading it should not raise.
    assert_silent { require 'rails/otel/context' }
    assert defined?(RailsOtelContext)
  end

  def test_install_delegates_to_each_adapter
    called = []
    app_root = Dir.pwd

    RailsOtelContext::Adapters::PG.stub(:install!, ->(**_) { called << :PG }) do
      RailsOtelContext::Adapters::Mysql2.stub(:install!, ->(**_) { called << :Mysql2 }) do
        RailsOtelContext::Adapters::Trilogy.stub(:install!, ->(**_) { called << :Trilogy }) do
          RailsOtelContext::Adapters::Redis.stub(:install!, ->(**_) { called << :Redis }) do
            RailsOtelContext::Adapters::Clickhouse.stub(:install!, ->(**_) { called << :Clickhouse }) do
              RailsOtelContext::Adapters::ConnectionPool.stub(:install!, -> { called << :ConnectionPool }) do
                RailsOtelContext.configure do |c|
                  c.redis_source_enabled            = true
                  c.clickhouse_enabled              = true
                  c.connection_pool_tracing_enabled = true
                end
                RailsOtelContext::Adapters.install!(app_root: app_root)
              end
            end
          end
        end
      end
    end

    assert_includes called, :PG
    assert_includes called, :Mysql2
    assert_includes called, :Trilogy
    assert_includes called, :Redis
    assert_includes called, :Clickhouse
    assert_includes called, :ConnectionPool
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_install_skips_redis_when_disabled
    called = []
    RailsOtelContext::Adapters::Redis.stub(:install!, ->(**_) { called << :Redis }) do
      RailsOtelContext.configure { |c| c.redis_source_enabled = false }
      RailsOtelContext::Adapters.install!(app_root: Dir.pwd)
    end
    refute_includes called, :Redis
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_install_skips_clickhouse_when_disabled
    called = []
    RailsOtelContext::Adapters::Clickhouse.stub(:install!, ->(**_) { called << :Clickhouse }) do
      RailsOtelContext.configure { |c| c.clickhouse_enabled = false }
      RailsOtelContext::Adapters.install!(app_root: Dir.pwd)
    end
    refute_includes called, :Clickhouse
  ensure
    RailsOtelContext.reset_configuration!
  end

  def test_install_skips_connection_pool_when_disabled
    called = []
    RailsOtelContext::Adapters::ConnectionPool.stub(:install!, -> { called << :ConnectionPool }) do
      RailsOtelContext.configure { |c| c.connection_pool_tracing_enabled = false }
      RailsOtelContext::Adapters.install!(app_root: Dir.pwd)
    end
    refute_includes called, :ConnectionPool
  ensure
    RailsOtelContext.reset_configuration!
  end
end
