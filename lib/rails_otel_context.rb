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
  end
end
