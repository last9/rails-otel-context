# frozen_string_literal: true

module RailsOtelContext
  # Shared helper for finding the first app-code source location in the call stack.
  # Used by all DB adapters to attach source file/line to query spans.
  module SourceLocation
    def source_location_for_app
      return unless Thread.respond_to?(:each_caller_location)

      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path&.start_with?(app_root)
        next if path.include?('/gems/')

        return [path.delete_prefix("#{app_root}/"), location.lineno]
      end

      nil
    end

    def apply_source_to_span(span, source)
      return unless source

      span.set_attribute('code.filepath', source[0])
      span.set_attribute('code.lineno', source[1])
    end
  end
end
