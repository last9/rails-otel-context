# frozen_string_literal: true

module RailsOtelContext
  module Adapters
    # Tracks the innermost template/partial currently rendering on this thread
    # so CallContextProcessor can attach rails.view.template to all child spans
    # (DB queries, Redis calls, etc.) fired during view rendering.
    #
    # Uses the start/finish subscriber protocol so we get both edges of the
    # render lifecycle — unlike the block form of subscribe which only fires
    # after the render is complete.
    #
    # Nested partials are handled via a stack: when a partial starts it is
    # pushed; when it finishes the parent template is restored automatically.
    module ActionView
      EVENTS = %w[render_template.action_view render_partial.action_view].freeze

      def self.install!
        return unless defined?(::ActionView)
        return unless defined?(::ActiveSupport::Notifications)

        subscriber = Subscriber.new
        EVENTS.each do |event|
          ::ActiveSupport::Notifications.notifier.subscribe(event, subscriber)
        end
      end

      class Subscriber
        def start(_name, _id, payload)
          identifier = (payload[:identifier] || '').to_s
          RailsOtelContext::RequestContext.push_view_template(identifier)
        rescue StandardError
          nil
        end

        def finish(_name, _id, _payload)
          RailsOtelContext::RequestContext.pop_view_template
        rescue StandardError
          nil
        end
      end
    end
  end
end
