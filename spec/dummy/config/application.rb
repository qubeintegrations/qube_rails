# frozen_string_literal: true

require "logger"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"

require "qube_rails"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.active_job.queue_adapter = :test
    config.secret_key_base = "dummy-secret-key-base-for-tests-only"
    config.hosts.clear if config.respond_to?(:hosts)
    config.logger = Logger.new(nil)
    config.active_record.maintain_test_schema = false if config.active_record.respond_to?(:maintain_test_schema=)
  end
end
