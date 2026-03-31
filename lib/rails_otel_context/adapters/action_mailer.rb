# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    # Instruments ActionMailer deliveries with OTel spans.
    #
    # Subscribes to the +deliver.action_mailer+ ActiveSupport notification and
    # creates a span for each email delivery. The span carries:
    #   - +mail.mailer+    — mailer class name (e.g. "UserMailer")
    #   - +mail.action+    — mailer action / message key
    #   - +mail.to+        — recipient address(es), comma-joined (opt-in via config)
    #   - +rails.controller+ / +rails.job+ — inherited from RequestContext
    #
    # Perf: the subscriber fires once per delivery (not per span), so overhead is
    # limited to one AS::Notifications callback + one OTel span creation per email.
    module ActionMailer
      TRACER_NAME = 'rails_otel_context.action_mailer'

      module_function

      def install!
        return unless defined?(::ActionMailer::Base)
        return unless defined?(::ActiveSupport::Notifications)
        return unless defined?(::OpenTelemetry)

        ::ActiveSupport::Notifications.subscribe('deliver.action_mailer') do |*args|
          event = ::ActiveSupport::Notifications::Event.new(*args)
          on_deliver(event)
        end
      end

      def on_deliver(event)
        payload   = event.payload
        mailer    = payload[:mailer].to_s
        action    = (payload[:action] || payload[:message_id] || '').to_s

        tracer = ::OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
        tracer.in_span("#{mailer}##{action}", kind: :internal) do |span|
          span.set_attribute('mail.mailer', mailer) unless mailer.empty?
          span.set_attribute('mail.action', action) unless action.empty?

          to = Array(payload[:to]).join(', ')
          span.set_attribute('mail.to', to) unless to.empty?

          duration_ms = (event.duration * 1).round(2)
          span.set_attribute('mail.duration_ms', duration_ms)
        end
      rescue StandardError
        nil
      end
    end
  end
end
