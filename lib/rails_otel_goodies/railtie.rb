# frozen_string_literal: true

require 'rails_otel_goodies/adapters'

module RailsOtelGoodies
  class Railtie < Rails::Railtie
    initializer 'otel_ruby_goodies.configure' do
      RailsOtelGoodies.apply_env_configuration!
    end

    initializer 'otel_ruby_goodies.install_adapters' do
      ActiveSupport.on_load(:active_record) do
        RailsOtelGoodies::Adapters.install!(app_root: Rails.root, config: RailsOtelGoodies.configuration)
      end
    end
  end
end
