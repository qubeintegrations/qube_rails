# frozen_string_literal: true

require "json"
require "openssl"
require "stringio"

# The settings every example starts from, a log it can read, and signed webhook bodies.
module QubeRailsHelpers
  SECRET = "whsec_test_secret"
  API_KEY = "qube_test_api_key"
  BASE_URL = "https://qube.example"
  WEBHOOK_URL = "https://app.example/webhooks/qube"
  VECTORS = JSON.parse(File.read(File.expand_path("../fixtures/webhook_test_vectors.json", __dir__)))

  def configure_qube_rails
    QubeRails.reset!
    QubeRails.configure do |config|
      config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
      config.connection = "QuickbooksDesktop::Connection"
      config.current_account = ->(controller) { controller.current_account }
      config.authorize_question = ->(controller, record, _operation) { record.account_id == controller.current_account.id }
      config.dedupe = QubeRails::CacheDedupe.new(ActiveSupport::Cache::MemoryStore.new)
      config.api_key = API_KEY
      config.base_url = BASE_URL
      config.webhook_secret = SECRET
      config.webhook_url = WEBHOOK_URL
    end
  end

  def log_output
    @log_io.string
  end

  # The header QuBe Sync sends for body, signed now (or at t) with secret.
  def signature(body, secret: SECRET, t: Time.now.to_i)
    "t=#{t},v1=#{OpenSSL::HMAC.hexdigest("sha256", secret, "#{t}.#{body}")}"
  end

  # A body from the server's webhook test vectors, by its name, with changes merged in.
  def vector_body(name, changes = {})
    entry = VECTORS.fetch("events").find { |e| e["name"] == name } || raise("no vector #{name}")
    JSON.generate(JSON.parse(entry["body"]).merge(changes))
  end

  def api_url(path)
    "#{BASE_URL}/api/v2#{path}"
  end

  def json_data(data)
    { status: 200, body: JSON.generate("data" => data), headers: { "Content-Type" => "application/json" } }
  end
end

RSpec.configure do |config|
  config.include QubeRailsHelpers

  config.before do
    configure_qube_rails
    @log_io = StringIO.new
    @saved_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log_io).tap do |logger|
      logger.formatter = proc { |severity, _time, _progname, message| "#{severity} #{message}\n" }
    end
    QuickbooksDesktop::CreateInvoice.calls.clear
    QuickbooksDesktop::Connection.calls.clear
  end

  config.after do
    Rails.logger = @saved_logger
  end
end
