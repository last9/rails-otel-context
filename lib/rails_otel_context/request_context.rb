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
    CONTROLLER_KEY  = :_rails_otel_ctx_controller
    ACTION_KEY      = :_rails_otel_ctx_action
    JOB_KEY         = :_rails_otel_ctx_job
    JOB_LATENCY_KEY = :_rails_otel_ctx_job_latency
    QUERY_COUNT_KEY = :_rails_otel_ctx_qcount

    class << self
      def set(controller:, action:)
        Thread.current[CONTROLLER_KEY]  = controller
        Thread.current[ACTION_KEY]      = action
        Thread.current[QUERY_COUNT_KEY] = nil
      end

      def set_job(job_class:, queue_latency_ms: nil)
        Thread.current[JOB_KEY]         = job_class
        Thread.current[JOB_LATENCY_KEY] = queue_latency_ms
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

      def queue_latency_ms
        Thread.current[JOB_LATENCY_KEY]
      end

      def clear!
        Thread.current[CONTROLLER_KEY]  = nil
        Thread.current[ACTION_KEY]      = nil
        Thread.current[JOB_KEY]         = nil
        Thread.current[JOB_LATENCY_KEY] = nil
        Thread.current[QUERY_COUNT_KEY] = nil
      end

      def clear_job!
        Thread.current[JOB_KEY]         = nil
        Thread.current[JOB_LATENCY_KEY] = nil
        Thread.current[QUERY_COUNT_KEY] = nil
      end
    end
  end
end
