# frozen_string_literal: true

require 'rails_otel_context/adapters'

module RailsOtelContext
  class Railtie < Rails::Railtie
    initializer 'rails_otel_context.configure' do
      RailsOtelContext.apply_env_configuration!
    end

    initializer 'rails_otel_context.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelContext::Adapters.install!(app_root: Rails.root, config: RailsOtelContext.configuration)
      end
    end
  end
end
