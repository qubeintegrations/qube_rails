# frozen_string_literal: true

require "erb"
require "qube_rails/version"
require "qube_rails/backend"
require "qube_rails/configuration"
require "qube_rails/cache_dedupe"
require "qube_rails/database_dedupe"
require "qube_rails/json_coder"
require "qube_rails/operation"
require "qube_rails/request"
require "qube_rails/sync_status"
require "qube_rails/connection_events"

# QuBe Sync's Rails engine: the code that's the same in every Rails app's integration. Your app
# keeps its own: config/initializers/qube_rails.rb (QubeRails.configure), an operation class per
# way it starts a workflow (QubeRails::Operation), its class for a connection's events
# (QubeRails::ConnectionEvents), and `mount QubeRails::Engine => "/"` in config/routes.rb. The
# engine's own tables (qube_connections, qube_runs, qube_quickbooks_records) keep every
# connection, every run and every QuickBooks id, so your tables need no QuBe columns.
module QubeRails
  # A run whose operation none of config.operations has any more (taken out after it started).
  class UnknownOperation < StandardError; end

  # A connection's event came before the row's qube_id was saved (create_connection hadn't
  # returned yet, or its update hadn't committed: a simulated connection sends
  # connection.connected at once). The job raises it so the queue retries once it's there.
  class NotReady < StandardError; end

  # Operation.start was given a connection QuBe Sync hasn't made yet (no qube_id): the customer
  # hasn't finished onboarding, or QuBe Sync didn't answer it.
  class NotConnected < ArgumentError; end

  # An operation's input has no value for a reference QuickBooks requires (an invoice's
  # customer_ref): the record has no QuickBooks link on the run's connection and no name to look
  # it up by. The kit's mapped operations raise it from input, so the start fails, before anything
  # is sent, saying which reference and which record.
  class MissingReference < ArgumentError; end

  # Seconds after an event before a record's pages are told to refresh once more.
  REFRESH_AGAIN = 5

  class << self
    def config
      @config ||= Configuration.new
    end

    # In config/initializers/qube_rails.rb:
    #   QubeRails.configure do |config|
    #     config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
    #     config.connection_events = "QuickbooksDesktop::ConnectionEvents"
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

    # Runs one verified delivery. kind is "run" (QUBE_WEBHOOK_URL/runs/<id>): the run's
    # operation finds its record and handles the event (QubeRails::Operation#handle); or
    # "connection" (QUBE_WEBHOOK_URL/connections/<id>): your config.connection_events class
    # handles it for that connection; or "request" (QUBE_WEBHOOK_URL/requests/<id>): the request's
    # class handles it (QubeRails::Request#handle). QubeRails::WebhookJob calls it; so does your own queue's
    # worker when config.enqueue hands deliveries elsewhere.
    #
    # body is the delivery's raw body, which the webhook endpoint verified: parsed into its typed
    # event here, and not verified again, since a job can run after its timestamp's 5 minutes are
    # up.
    def run(kind, id, body)
      event = Backend.parse(body)
      case kind.to_s
      when "run" then run_event(id, event)
      when "connection" then connection_event(id, event)
      when "request" then request_event(id, event)
      else raise ArgumentError, "QuBe Sync: a delivery is for a run, a connection or a request, not #{kind.inspect}"
      end
    end

    # Tells the pages showing record's runs to refresh: the engine's partials subscribe with
    # turbo_stream_from(record, :qube_rails). Only in an app with turbo-rails 2 (Turbo 8 page
    # refreshes) and Action Cable; otherwise nothing. Once now, and once more REFRESH_AGAIN
    # later (QubeRails::RefreshJob), for a page that was still loading the first time. A
    # broadcast that fails is logged: the event is applied either way, and a reload shows it.
    def broadcast_refresh(record)
      return unless refresh_broadcasts?

      broadcast_refresh_now(record)
      QubeRails::RefreshJob.set(wait: REFRESH_AGAIN).perform_later(record)
    rescue StandardError => e
      logger.warn("QuBe Sync: couldn't tell the page for #{record.class.name} #{record.id} to refresh again " \
                  "(#{e.class})")
    end

    def broadcast_refresh_now(record)
      return unless refresh_broadcasts?

      Turbo::StreamsChannel.broadcast_refresh_to(record, :qube_rails)
    rescue StandardError => e
      logger.warn("QuBe Sync: couldn't tell the page for #{record.class.name} #{record.id} to refresh " \
                  "(#{e.class})")
    end

    def refresh_broadcasts?
      defined?(Turbo::StreamsChannel) && Turbo::StreamsChannel.respond_to?(:broadcast_refresh_to)
    end

    def logger
      Rails.logger
    end

    # A run, connection or record that isn't there is dropped with a warning, not raised: the
    # endpoint answered 404 unless the row existed, and the app saves a record before its run's
    # row, so by the time a job runs, a missing one was deleted, and retrying would never
    # succeed. An operation taken out of config.operations raises (UnknownOperation): putting it
    # back and retrying does.
    def run_event(id, event)
      run = Run.find_by(id: id)
      return dropped("run #{id} isn't there", event) unless run

      operation = config.operation_class(run.operation)
      raise UnknownOperation, "QuBe Sync: no operation has the slug #{run.operation.inspect}" unless operation

      record = find_run_record(operation, run)
      return dropped("run #{run.id}'s #{run.record_type} #{run.record_id} isn't there", event) unless record

      operation.new(record, run).handle(event)
    end

    def request_event(id, event)
      row = QueuedRequest.find_by(id: id)
      return dropped("request #{id} isn't there", event) unless row

      request_class = config.operation_class(row.operation)
      raise UnknownOperation, "QuBe Sync: no operation has the slug #{row.operation.inspect}" unless request_class

      record = find_run_record(request_class, row)
      return dropped("request #{row.id}'s #{row.record_type} #{row.record_id} isn't there", event) unless record

      request_class.new(record, row).handle(event)
    end

    def connection_event(id, event)
      connection = Connection.find_by(id: id)
      return dropped("connection #{id} isn't there", event) unless connection

      config.connection_events_class.new(connection).handle(event)
    end

    def find_run_record(operation, run)
      operation.record_for(run)
    rescue ActiveRecord::RecordNotFound # a find_record written with find
      nil
    end

    def dropped(why, event)
      logger.warn("QuBe Sync: dropped #{event.event || event.type}: #{why} (deleted since, so it can't be applied)")
      nil
    end

    # Forgets the settings and the client: for tests.
    def reset!
      @config = nil
      @client = nil
    end
  end
end

require "qube_rails/engine" if defined?(Rails::Engine)
