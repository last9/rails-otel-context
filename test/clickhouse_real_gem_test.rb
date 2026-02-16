# frozen_string_literal: true

require_relative 'test_helper'

class ClickhouseRealGemTest < Minitest::Test
  def setup
    RailsOtelGoodies::Adapters::Clickhouse.instance_variable_set(:@patch_modules, nil)
  end

  def test_real_click_house_connection_is_patchable
    require 'click_house'

    klass = ::ClickHouse::Connection
    methods = RailsOtelGoodies::Adapters::Clickhouse::CANDIDATE_METHODS.select do |method_name|
      klass.method_defined?(method_name)
    end

    assert_includes methods, :execute

    patch_module = RailsOtelGoodies::Adapters::Clickhouse.patch_module_for(klass, methods)
    refute klass.ancestors.include?(patch_module)

    RailsOtelGoodies::Adapters::Clickhouse.install!(app_root: Dir.pwd, threshold_ms: 200.0)

    assert klass.ancestors.include?(patch_module)
  end
end
