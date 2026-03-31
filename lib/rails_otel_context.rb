# frozen_string_literal: true

# rails-otel-context is a Rails-specific gem
# Skip Rails check in test environment to allow unit testing
unless defined?(Rails) || ENV['RAILS_OTEL_CONTEXT_TEST']
  raise LoadError, 'rails-otel-context requires Rails. This gem is designed for Rails applications only.'
end

require 'rails_otel_context/version'
require 'rails_otel_context/configuration'
require 'rails_otel_context/source_location'
require 'rails_otel_context/activerecord_context'
require 'rails_otel_context/adapters'
require 'rails_otel_context/request_context'
require 'rails_otel_context/frame_context'
require 'rails_otel_context/call_context_processor'
require 'rails_otel_context/railtie' if defined?(Rails::Railtie)

module RailsOtelContext
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # Registers CallContextProcessor with the OTel tracer_provider.
    # Called automatically by the Railtie after_initialize. Call this manually
    # when OpenTelemetry::SDK.configure runs after Rails boot (e.g. in a custom
    # after_initialize block):
    #
    #   OpenTelemetry::SDK.configure { |c| c.use_all() }
    #   RailsOtelContext.install_processor!
    #
    # Safe to call multiple times — idempotent.
    def install_processor!
      return if @processor_installed
      return unless defined?(Rails) && Rails.root
      return unless OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)

      @processor_installed = true
      processor = RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
      OpenTelemetry.tracer_provider.add_span_processor(processor)
    end

    # Convenience delegates to FrameContext — see FrameContext for full docs.
    def with_frame(class_name:, method_name:, &block)
      FrameContext.with_frame(class_name: class_name, method_name: method_name, &block)
    end

    def push_frame(class_name:, method_name:)
      FrameContext.push(class_name: class_name, method_name: method_name)
    end

    def pop_frame
      FrameContext.pop
    end
  end
end
