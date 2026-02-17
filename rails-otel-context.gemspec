# frozen_string_literal: true

require_relative 'lib/rails_otel_context/version'

Gem::Specification.new do |spec|
  spec.name = 'rails-otel-context'
  spec.version = RailsOtelContext::VERSION
  spec.authors = ['Last9']
  spec.email = ['engineering@last9.io']

  spec.summary = 'Production helpers for OpenTelemetry Ruby instrumentations in Rails.'
  spec.description = 'Rails-specific OpenTelemetry enhancements for source location tracking and database instrumentation. Maintained by Last9.'
  spec.homepage = 'https://github.com/last9/rails-otel-context'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'README.md', 'LICENSE*']
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'opentelemetry-api', '>= 1.0'
  spec.add_dependency 'railties', '>= 7.0'
  spec.add_dependency 'activerecord', '>= 7.0'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
