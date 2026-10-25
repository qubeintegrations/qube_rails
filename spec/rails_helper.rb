# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
%w[QUBE_API_KEY QUBE_URL QUBE_WEBHOOK_SECRET QUBE_WEBHOOK_URL].each { |name| ENV.delete(name) }

require_relative "dummy/config/environment"
require "rspec/rails"
require "webmock/rspec"

ActiveRecord::Migration.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActiveJob::TestHelper
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"
end
