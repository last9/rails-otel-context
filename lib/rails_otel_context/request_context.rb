# frozen_string_literal: true

module RailsOtelContext
  # Thread-local storage for request-scoped context that gets propagated
  # to all spans within a request. Uses raw Thread.current for minimal overhead —
  # no object allocation, no mutex, ~5ns per read/write.
  #
  # Lifecycle:
  #   1. Railtie's around_action sets controller + action at request start
  #   2. CallContextProcessor reads them on every child span's on_start
  #   3. around_action's ensure block clears them when the request ends
  #
  # Thread safety: each Puma thread has its own slot — no sharing, no contention.
  module RequestContext
    CONTROLLER_KEY = :_rails_otel_ctx_controller
    ACTION_KEY     = :_rails_otel_ctx_action

    class << self
      def set(controller:, action:)
        Thread.current[CONTROLLER_KEY] = controller
        Thread.current[ACTION_KEY]     = action
      end

      # Returns [controller, action] in a single Thread.current access.
      def fetch
        t = Thread.current
        [t[CONTROLLER_KEY], t[ACTION_KEY]]
      end

      def controller
        Thread.current[CONTROLLER_KEY]
      end

      def action
        Thread.current[ACTION_KEY]
      end

      def clear!
        Thread.current[CONTROLLER_KEY] = nil
        Thread.current[ACTION_KEY]     = nil
      end
    end
  end
end
