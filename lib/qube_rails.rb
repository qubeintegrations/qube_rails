# frozen_string_literal: true

require "erb"
require "qube_rails/version"
require "qube_rails/backend"
require "qube_rails/configuration"
require "qube_rails/cache_dedupe"
require "qube_rails/operation"
require "qube_rails/connection_events"

# QuBe Sync's Rails engine: the code that's the same in every Rails app's integration. Your app
# keeps its own: config/initializers/qube_rails.rb (QubeRails.configure), an operation class per
# way it starts a workflow (QubeRails::Operation), its connection class
# (QubeRails::ConnectionEvents), and `mount QubeRails::Engine => "/"` in config/routes.rb.
module QubeRails
  # A webhook job for a slug none of the operations has (the endpoint answers those 404, so this
  # is a job enqueued before an operation was taken out of config.operations).
  class UnknownOperation < StandardError; end

  # find_record found nothing for a webhook's record id. The job raises it so your queue retries:
  # the record may not be committed yet, or the webhook URL names a record since deleted.
  class RecordMissing < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    # In config/initializers/qube_rails.rb:
    #   QubeRails.configure do |config|
    #     config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
    #     config.connection = "QuickbooksDesktop::Connection"
    #     ...
    #   end
    def configure
      yield config
      @client = nil
      config
    end

    # QuBe Sync's API, through the qube_sync gem (QubeSync::Client): create_connection,
    # start_run, answer, search, get_run, cancel_run, queue and the rest. A non-2xx answer raises
    # QubeSync::APIError (status, code, message, body).
    def client
      @client ||= Backend.client(api_key: config.api_key, base_url: config.base_url,
                                 on_retry: method(:log_retry))
    end

    # A call QuBe Sync didn't answer, sent again (safe calls only, within 60 seconds).
    def log_retry(info)
      why = info[:status] || (info[:error] && info[:error].class)
      logger.warn("QuBe Sync: retrying #{info[:method]} #{info[:url]} (#{why}) " \
                  "in #{info[:delay].to_f.round(1)} s")
    end

    # Where a connection's own events go: QUBE_WEBHOOK_URL, then connection and the id of the
    # account that keeps it (your connection class takes them).
    def connection_webhook_url(account_id)
      "#{config.webhook_url}/#{Configuration::CONNECTION_SLUG}/" \
        "#{ERB::Util.url_encode(account_id.to_s)}"
    end

    # Runs one verified delivery: the class its URL's slug names finds its record and handles the
    # event (QubeRails::Operation#handle, or your connection class's). QubeRails::WebhookJob calls
    # it; so does your own queue's worker when config.enqueue hands deliveries elsewhere.
    #
    # body is the delivery's raw body, which the webhook endpoint verified: parsed into its typed
    # event here, and not verified again, since a job can run after its timestamp's 5 minutes are
    # up.
    def run(operation, record_id, body)
      handler = config.handler_for(operation)
      raise UnknownOperation, "QuBe Sync: no operation has the slug #{operation.inspect}" unless handler

      event = Backend.parse(body)
      record = handler.find_record(record_id)
      raise RecordMissing, "QuBe Sync: #{handler.name}.find_record(#{record_id.inspect}) found nothing" unless record

      handler.new(record).handle(event)
    end

    def logger
      Rails.logger
    end

    # Forgets the settings and the client: for tests.
    def reset!
      @config = nil
      @client = nil
    end
  end
end

require "qube_rails/engine" if defined?(Rails::Engine)
