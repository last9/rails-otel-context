# frozen_string_literal: true

# Example: Customizing span names with ActiveRecord context
#
# Place this in config/initializers/rails_otel_context.rb

RailsOtelContext.configure do |config|
  # Simple formatter: "User.find" instead of "SELECT postgres.users"
  config.span_name_formatter = lambda do |original_name, ar_context|
    model = ar_context[:model_name]
    method = ar_context[:method_name]

    if model && method
      "#{model}.#{method}"
    else
      original_name
    end
  end

  # Advanced formatter: Include operation type
  # config.span_name_formatter = lambda do |original_name, ar_context|
  #   model = ar_context[:model_name]
  #   method = ar_context[:method_name]
  #
  #   if model && method
  #     operation = case method
  #                 when /find/, /where/, /select/ then 'SELECT'
  #                 when /create/, /insert/ then 'INSERT'
  #                 when /update/, /save/ then 'UPDATE'
  #                 when /delete/, /destroy/ then 'DELETE'
  #                 else 'QUERY'
  #                 end
  #     "#{operation} #{model}.#{method}"
  #   else
  #     original_name
  #   end
  # end

  # Defensive formatter: Handle nil cases
  # config.span_name_formatter = lambda do |original_name, ar_context|
  #   return original_name unless ar_context
  #
  #   model = ar_context[:model_name]
  #   method = ar_context[:method_name]
  #
  #   return original_name unless model || method
  #
  #   parts = []
  #   parts << model if model
  #   parts << method if method
  #   parts.join('.')
  # end
end
