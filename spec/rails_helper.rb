# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
%w[QUBE_API_KEY QUBE_URL QUBE_WEBHOOK_SECRET QUBE_WEBHOOK_URL].each { |name| ENV.delete(name) }

require_relative "dummy/config/environment"
require "rspec/rails"
require "webmock/rspec"

ActiveRecord::Migration.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)
# The engine's own migration, as `qube_rails:install:migrations` copies it into an app.
Dir[File.expand_path("../db/migrate/*.rb", __dir__)].sort.each { |file| load file }
CreateQubeTables.new.migrate(:up)
AddQubeSyncStatusIndexes.new.migrate(:up)
CreateQubeSyncMarks.new.migrate(:up)
CreateQubeRequests.new.migrate(:up)
AddQubeConnectionTypeAndRunHeadline.new.migrate(:up)

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActiveJob::TestHelper
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"
end
