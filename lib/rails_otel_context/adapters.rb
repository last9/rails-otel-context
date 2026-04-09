# frozen_string_literal: true

require 'rails_otel_context/adapters/pg'
require 'rails_otel_context/adapters/mysql2'
require 'rails_otel_context/adapters/trilogy'
require 'rails_otel_context/adapters/redis'
require 'rails_otel_context/adapters/clickhouse'
require 'rails_otel_context/adapters/action_mailer'

module RailsOtelContext
  module Adapters
    module_function

    def install!(app_root:, config: RailsOtelContext.configuration)
      PG.install!(app_root: app_root)
      Mysql2.install!(app_root: app_root)
      Trilogy.install!(app_root: app_root)
      Redis.install!(app_root: app_root) if config.redis_source_enabled
      Clickhouse.install!(app_root: app_root) if config.clickhouse_enabled
      ActionMailer.install!
    end
  end
end
