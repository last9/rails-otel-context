# frozen_string_literal: true

# Simulates an app-code service that calls a DB client.
# Used by integration tests to exercise the real call stack
# (no Thread.each_caller_location stubs) and verify that
# call_site_for_app finds this frame through with_call_site_frame.
class OrderService
  def initialize(client)
    @client = client
  end

  def create
    @client.query('INSERT INTO orders (status) VALUES (?)')
  end
end
