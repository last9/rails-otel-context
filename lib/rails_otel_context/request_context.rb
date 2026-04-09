# frozen_string_literal: true

module RailsOtelContext
  # Thread-local storage for request/job-scoped context propagated to all spans.
  # Uses raw Thread.current — no object allocation, no mutex, ~5ns per read/write.
  #
  # Controller lifecycle:
  #   1. Railtie's around_action sets controller + action at request start
  #   2. CallContextProcessor reads them on every child span's on_start
  #   3. around_action's ensure block clears them when the request ends
  #
  # Job lifecycle:
  #   1. Railtie's around_perform sets job at job start
  #   2. CallContextProcessor reads it on every child span's on_start
  #   3. around_perform's ensure block clears it when the job ends
  #
  # Thread safety: each Puma/Sidekiq thread owns its slot — no sharing, no contention.
  module RequestContext
    CONTROLLER_KEY   = :_rails_otel_ctx_controller
    ACTION_KEY       = :_rails_otel_ctx_action
    JOB_KEY          = :_rails_otel_ctx_job
    QUERY_COUNT_KEY  = :_rails_otel_ctx_qcount
    VIEW_STACK_KEY   = :_rails_otel_ctx_view_stack

    class << self
      def set(controller:, action:)
        Thread.current[CONTROLLER_KEY]  = controller
        Thread.current[ACTION_KEY]      = action
        Thread.current[QUERY_COUNT_KEY] = nil
      end

      def set_job(job_class:)
        Thread.current[JOB_KEY]         = job_class
        Thread.current[QUERY_COUNT_KEY] = nil
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

      def job
        Thread.current[JOB_KEY]
      end

      # Returns the identifier of the innermost template/partial currently rendering,
      # or nil when no view rendering is in progress.
      def view_template
        stack = Thread.current[VIEW_STACK_KEY]
        stack&.last
      end

      def push_view_template(identifier)
        stack = Thread.current[VIEW_STACK_KEY] ||= []
        stack.push(identifier.to_s)
      end

      def pop_view_template
        stack = Thread.current[VIEW_STACK_KEY]
        stack&.pop
      end

      def clear!
        Thread.current[CONTROLLER_KEY]  = nil
        Thread.current[ACTION_KEY]      = nil
        Thread.current[JOB_KEY]         = nil
        Thread.current[QUERY_COUNT_KEY] = nil
        Thread.current[VIEW_STACK_KEY]  = nil
      end

      def clear_job!
        Thread.current[JOB_KEY]         = nil
        Thread.current[QUERY_COUNT_KEY] = nil
      end
    end
  end
end
