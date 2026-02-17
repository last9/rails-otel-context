# frozen_string_literal: true

module RailsOtelContext
  module ActiveRecordContext
    module_function

    # Extracts ActiveRecord model name and method from the call stack
    # Returns a hash with :model_name and :method_name, or nil if not found
    def extract(app_root:)
      return nil unless defined?(::ActiveRecord::Base)
      return nil unless Thread.respond_to?(:each_caller_location)

      model_name = nil
      method_name = nil
      found_app_code = false

      Thread.each_caller_location do |location|
        path = location.absolute_path || location.path
        next unless path

        # Skip gem code
        next if path.include?('/gems/')

        # Check if this is ActiveRecord::Base or a subclass
        # We do this by parsing the label which contains class and method info
        label = location.label
        next unless label

        # Look for patterns like:
        # - "User.find"
        # - "Product#save"
        # - "Order::find_by_sql"
        # - Instance methods: "block in find"

        # Try to extract model name from label
        if label =~ /^([A-Z][a-zA-Z0-9_]*)(\.|\#|::)/
          potential_model = ::Regexp.last_match(1)

          # Check if this is actually an ActiveRecord model
          begin
            klass = Object.const_get(potential_model)
            if klass.is_a?(Class) && klass < ::ActiveRecord::Base
              model_name ||= potential_model
              # Extract method name after the delimiter
              method_name ||= label.split(/[.\#:]/, 2).last&.split(/\s/, 2)&.first
            end
          rescue NameError
            # Not a valid constant, skip
          end
        end

        # Check if we're in app code
        if path.start_with?(app_root.to_s)
          found_app_code = true

          # Try to infer model from file path (e.g., app/models/user.rb)
          if !model_name && path.include?('/app/models/')
            filename = File.basename(path, '.rb')
            # Convert snake_case to CamelCase
            potential_model = filename.split('_').map(&:capitalize).join
            begin
              klass = Object.const_get(potential_model)
              model_name ||= potential_model if klass.is_a?(Class) && klass < ::ActiveRecord::Base
            rescue NameError
              # Not a valid model
            end
          end
        end

        # If we found both model and method, or we've gone past app code, stop
        break if (model_name && method_name) || (found_app_code && model_name)
      end

      return nil unless model_name

      {
        model_name: model_name,
        method_name: method_name
      }
    end
  end
end
