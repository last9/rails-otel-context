# frozen_string_literal: true

require_relative 'test_helper'

class ActiveRecordContextTest < Minitest::Test
  def setup
    # Mock ActiveRecord::Base for testing
    return if defined?(::ActiveRecord::Base)

    Object.const_set(:ActiveRecord, Module.new)
    ActiveRecord.const_set(:Base, Class.new)
  end

  def test_extract_returns_nil_without_activerecord
    # Temporarily remove ActiveRecord
    ar_backup = Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord)

    context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')
    assert_nil context
  ensure
    Object.const_set(:ActiveRecord, ar_backup) if ar_backup
  end

  def test_extract_returns_nil_without_caller_location_support
    original_method = Thread.method(:respond_to?)
    Thread.define_singleton_method(:respond_to?) do |method|
      method == :each_caller_location ? false : original_method.call(method)
    end

    context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')
    assert_nil context
  ensure
    Thread.singleton_class.send(:remove_method, :respond_to?)
    Thread.define_singleton_method(:respond_to?, original_method)
  end

  def test_extract_finds_model_from_label_pattern
    # Create a mock User model
    user_class = Class.new(ActiveRecord::Base)
    Object.const_set(:User, user_class)

    with_mock_caller_location('User.find', '/app/controllers/users_controller.rb', 10) do
      context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')

      assert_equal 'User', context[:model_name]
      assert_equal 'find', context[:method_name]
    end
  ensure
    Object.send(:remove_const, :User) if defined?(::User)
  end

  def test_extract_finds_model_with_hash_method_notation
    # Create a mock Product model
    product_class = Class.new(ActiveRecord::Base)
    Object.const_set(:Product, product_class)

    with_mock_caller_location('Product#save', '/app/models/product.rb', 25) do
      context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')

      assert_equal 'Product', context[:model_name]
      assert_equal 'save', context[:method_name]
    end
  ensure
    Object.send(:remove_const, :Product) if defined?(::Product)
  end

  def test_extract_infers_model_from_file_path
    # Create a mock Order model
    order_class = Class.new(ActiveRecord::Base)
    Object.const_set(:Order, order_class)

    with_mock_caller_location('some_method', '/app/models/order.rb', 15) do
      context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')

      assert_equal 'Order', context[:model_name]
    end
  ensure
    Object.send(:remove_const, :Order) if defined?(::Order)
  end

  def test_extract_returns_nil_for_non_activerecord_classes
    # Create a non-ActiveRecord class
    Object.const_set(:RegularClass, Class.new)

    with_mock_caller_location('RegularClass.method', '/app/lib/regular.rb', 5) do
      context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')

      assert_nil context
    end
  ensure
    Object.send(:remove_const, :RegularClass) if defined?(::RegularClass)
  end

  def test_extract_handles_nameerror_gracefully
    with_mock_caller_location('NonExistent.find', '/app/controllers/some_controller.rb', 20) do
      context = RailsOtelGoodies::ActiveRecordContext.extract(app_root: '/app')

      assert_nil context
    end
  end

  private

  def with_mock_caller_location(label, path, lineno)
    location = OpenStruct.new(
      label: label,
      absolute_path: path,
      path: path,
      lineno: lineno
    )

    thread_singleton = Thread.singleton_class
    had_original = Thread.respond_to?(:each_caller_location)

    if had_original
      thread_singleton.alias_method :__ar_context_original_each_caller_location, :each_caller_location
    end

    thread_singleton.define_method(:each_caller_location) { |&block| block.call(location) }

    yield
  ensure
    return unless thread_singleton

    if had_original
      thread_singleton.alias_method :each_caller_location, :__ar_context_original_each_caller_location
      thread_singleton.remove_method :__ar_context_original_each_caller_location
    else
      thread_singleton.remove_method :each_caller_location
    end
  end
end
