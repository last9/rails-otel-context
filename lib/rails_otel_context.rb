# frozen_string_literal: true

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
require 'rails_otel_context/allocation_delta_processor'
require 'rails_otel_context/memory_recorder'
require 'rails_otel_context/process_sampler'
require 'rails_otel_context/body_capture'
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

    # Full installation: registers all Rails hooks (AR adapters, around_action,
    # around_perform) and the CallContextProcessor. Safe to call from a
    # config/initializers file when the gem is loaded with require: false:
    #
    #   # config/initializers/opentelemetry.rb
    #   return unless ENV['ENABLE_OTLP']
    #   require 'rails_otel_context'
    #   RailsOtelContext.configure { |c| ... }
    #   RailsOtelContext.install!
    #
    # The Railtie calls this automatically via after_initialize, so apps that
    # let Bundler auto-require the gem do not need to call it explicitly.
    # Safe to call multiple times — idempotent.
    def install!(app_root: nil)
      app_root ||= Rails.root if defined?(Rails)
      register_hooks!(app_root) unless @hooks_installed
      install_processor!
    end

    # Registers CallContextProcessor with the OTel tracer_provider.
    # Called automatically by install!. Call this manually only when the OTel
    # SDK is configured after install! has already run (rare):
    #
    #   RailsOtelContext.install!          # hooks up AR/request context
    #   OpenTelemetry::SDK.configure { … } # SDK configured later
    #   RailsOtelContext.install_processor! # add processor to the now-real provider
    #
    # Safe to call multiple times — idempotent.
    def install_processor!
      return if @processor_installed
      return unless defined?(Rails) && Rails.root
      return unless OpenTelemetry.tracer_provider.respond_to?(:add_span_processor)

      @processor_installed = true
      OpenTelemetry.tracer_provider.add_span_processor(
        RailsOtelContext::CallContextProcessor.new(app_root: Rails.root)
      )

      RailsOtelContext::AllocationDeltaProcessor.install! if configuration.capture_allocations
      RailsOtelContext::ProcessSampler.start(interval_sec: configuration.process_sampler_interval_sec)
    end

    # Returns the OTel Meter this gem uses for its own instruments, or nil
    # when the host app has not configured a meter provider. Shared by
    # MemoryRecorder and ProcessSampler — there should be one Meter per
    # library, not per file.
    def meter
      return nil unless defined?(OpenTelemetry) && OpenTelemetry.respond_to?(:meter_provider)

      provider = OpenTelemetry.meter_provider
      return nil unless provider.respond_to?(:meter)

      provider.meter(MemoryRecorder::INSTRUMENTATION_NAME, version: VERSION)
    rescue StandardError
      nil
    end

    private

    def register_hooks!(app_root)
      @hooks_installed = true
      install_active_record_hook(app_root)
      install_controller_hook
      install_active_job_hook
    end

    def install_active_record_hook(app_root)
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: app_root, config: RailsOtelContext.configuration)
        RailsOtelContext::ActiveRecordContext.install!(app_root: app_root)
        RailsOtelContext::ActiveRecordContext.ar_table_model_map
      end
    end

    def install_controller_hook
      hook = proc do
        around_action do |_controller, block|
          RailsOtelContext::RequestContext.set(controller: self.class.name, action: action_name)
          snap = RailsOtelContext::MemoryRecorder.snapshot if RailsOtelContext.configuration.capture_memory_metrics
          block.call
        ensure
          if snap
            RailsOtelContext::MemoryRecorder.record_request(snap, controller: self.class.name,
                                                                  action: action_name)
          end
          RailsOtelContext::RequestContext.clear!
        end
      end
      ActiveSupport.on_load(:action_controller, &hook)
      ActiveSupport.on_load(:action_controller_api, &hook)
    end

    def install_active_job_hook
      ActiveSupport.on_load(:active_job) do
        around_perform do |job, block|
          RailsOtelContext::RequestContext.set_job(job_class: self.class.name)
          snap = RailsOtelContext::MemoryRecorder.snapshot if RailsOtelContext.configuration.capture_memory_metrics
          block.call
        ensure
          if snap
            queue = job.queue_name if job.respond_to?(:queue_name)
            RailsOtelContext::MemoryRecorder.record_job(snap, job_class: self.class.name, queue: queue)
          end
          RailsOtelContext::RequestContext.clear_job!
        end
      end
    end

    public

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
