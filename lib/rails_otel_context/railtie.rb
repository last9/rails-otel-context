# frozen_string_literal: true

require 'rails_otel_context/adapters'
require 'rails_otel_context/call_context_processor'

module RailsOtelContext
  class Railtie < Rails::Railtie
    initializer 'rails_otel_context.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: Rails.root, config: RailsOtelContext.configuration)
        RailsOtelContext::ActiveRecordContext.install!(app_root: Rails.root)
      end
    end

    # Runs after config/initializers/ so the OTel SDK tracer_provider is already configured.
    config.after_initialize do
      if OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)
        processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
        OpenTelemetry.tracer_provider.add_span_processor(processor)
      end
    end

    # Push the controller class + action name as the active frame for every
    # controller action. Replaces the O(stack-depth) walk with a O(1) thread-local
    # read for every span created during the action. Always-on — no config gate.
    initializer 'rails_otel_context.install_frame_context' do
      ActiveSupport.on_load(:action_controller) do
        around_action do |_controller, block|
          RailsOtelContext::FrameContext.with_frame(
            class_name: self.class.name,
            method_name: action_name
          ) { block.call }
        end
      end
    end

    # Install request context capture on ActionController when it loads.
    # Uses around_action with ensure for leak-proof cleanup on exceptions.
    initializer 'rails_otel_context.install_request_context' do
      ActiveSupport.on_load(:action_controller) do
        if RailsOtelContext.configuration.request_context_enabled
          around_action do |_controller, block|
            RailsOtelContext::RequestContext.set(
              controller: self.class.name,
              action: action_name
            )
            block.call
          ensure
            RailsOtelContext::RequestContext.clear!
          end
        end
      end
    end
  end
end
