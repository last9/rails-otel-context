# frozen_string_literal: true

require_relative 'test_helper'

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

class FakePoolSpan
  attr_reader :name, :attributes, :finished, :exception_recorded

  def initialize(name)
    @name = name
    @attributes = {}
    @finished = false
    @exception_recorded = false
  end

  def set_attribute(key, value)
    @attributes[key] = value
  end

  def record_exception(_err)
    @exception_recorded = true
  end

  def status=(_status); end

  def finish
    @finished = true
  end
end

class FakePoolTracer
  attr_reader :spans

  def initialize
    @spans = []
  end

  def in_span(name, **_opts)
    span = FakePoolSpan.new(name)
    @spans << span
    result = yield span
    span.finish
    result
  rescue StandardError => e
    span.record_exception(e)
    span.finish
    raise
  end
end

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

class ConnectionPoolAdapterTest < Minitest::Test
  DEFAULT_STAT = { size: 5, connections: 1, busy: 1, dead: 0, idle: 4, waiting: 0, checkout_timeout: 5 }.freeze

  def setup
    RailsOtelContext.reset_configuration!
    RailsOtelContext::Adapters::ConnectionPool.instance_variable_set(:@patch_module, nil)
  end

  # -- span name --

  def test_creates_span_named_active_record_connection_checkout
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT)
      assert_equal 1, tracer.spans.size
      assert_equal RailsOtelContext::Adapters::ConnectionPool.const_get(:SPAN_NAME), tracer.spans.first.name
    end
  end

  # -- pool stat attributes --

  def test_sets_db_pool_size
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT.merge(size: 15))
      assert_equal 15, tracer.spans.first.attributes['db.pool.size']
    end
  end

  def test_sets_db_pool_busy
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT.merge(busy: 13))
      assert_equal 13, tracer.spans.first.attributes['db.pool.busy']
    end
  end

  def test_sets_db_pool_idle
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT.merge(idle: 2))
      assert_equal 2, tracer.spans.first.attributes['db.pool.idle']
    end
  end

  def test_sets_db_pool_waiting
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT.merge(waiting: 3))
      assert_equal 3, tracer.spans.first.attributes['db.pool.waiting']
    end
  end

  # -- passthrough --

  def test_returns_the_checkout_result
    with_fake_tracer do |_tracer|
      result = pool_checkout(stat: DEFAULT_STAT, connection: :my_conn)
      assert_equal :my_conn, result
    end
  end

  def test_span_is_finished_on_success
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT)
      assert tracer.spans.first.finished, 'span must be finished after checkout'
    end
  end

  # -- pinned connection fast path --

  def test_skips_span_when_pinned_connection_is_set
    with_fake_tracer do |tracer|
      pool_checkout(stat: DEFAULT_STAT, pinned_connection: :pinned)
      assert_empty tracer.spans, 'no span should be created for pinned connection'
    end
  end

  def test_pinned_connection_still_returns_checkout_result
    with_fake_tracer do |_tracer|
      result = pool_checkout(stat: DEFAULT_STAT, pinned_connection: :pinned, connection: :conn)
      assert_equal :conn, result
    end
  end

  # -- exception handling --

  def test_reraises_checkout_exception
    with_fake_tracer do |_tracer|
      assert_raises(RuntimeError) do
        pool_checkout(stat: DEFAULT_STAT, raise_error: RuntimeError.new('timeout'))
      end
    end
  end

  def test_span_is_finished_when_checkout_raises
    with_fake_tracer do |tracer|
      assert_raises(RuntimeError) do
        pool_checkout(stat: DEFAULT_STAT, raise_error: RuntimeError.new('timeout'))
      end
      assert tracer.spans.first.finished, 'span must be finished even when checkout raises'
    end
  end

  def test_exception_is_recorded_on_span_when_checkout_raises
    with_fake_tracer do |tracer|
      assert_raises(RuntimeError) do
        pool_checkout(stat: DEFAULT_STAT, raise_error: RuntimeError.new('timeout'))
      end
      assert tracer.spans.first.exception_recorded, 'exception must be recorded on span'
    end
  end

  # -- configuration --

  def test_default_connection_pool_tracing_enabled_is_false
    assert_equal false, RailsOtelContext.configuration.connection_pool_tracing_enabled
  end

  def test_connection_pool_tracing_enabled_can_be_set
    RailsOtelContext.configure { |c| c.connection_pool_tracing_enabled = true }
    assert_equal true, RailsOtelContext.configuration.connection_pool_tracing_enabled
  end

  private

  # Builds a fresh pool class per call (avoids cross-test prepend interference),
  # prepends the patch module, and calls checkout.
  def pool_checkout(stat:, connection: :conn, pinned_connection: nil, raise_error: nil)
    # Renamed to pool_* so define_method blocks can close over them as locals.
    # Method parameters are not accessible inside Class.new / define_method closures
    # without this explicit capture step.
    pool_stat       = stat
    pool_connection = connection
    pool_raise      = raise_error

    klass = Class.new do
      def initialize(pinned)
        @checkout_timeout  = 5
        @pinned_connection = pinned
      end
    end

    klass.define_method(:checkout) do |_timeout = @checkout_timeout|
      raise pool_raise if pool_raise

      pool_connection
    end

    klass.define_method(:stat) { pool_stat }

    patch = RailsOtelContext::Adapters::ConnectionPool.send(:patch_module_for)
    klass.prepend(patch)

    klass.new(pinned_connection).checkout
  end

  def with_fake_tracer
    tracer   = FakePoolTracer.new
    provider = Object.new
    provider.define_singleton_method(:tracer) { |_name| tracer }

    singleton = OpenTelemetry.singleton_class
    singleton.alias_method(:__orig_tracer_provider, :tracer_provider)
    singleton.define_method(:tracer_provider) { provider }

    yield tracer
  ensure
    singleton.alias_method(:tracer_provider, :__orig_tracer_provider)
    singleton.remove_method(:__orig_tracer_provider)
  end
end
