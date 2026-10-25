# frozen_string_literal: true

require "erb"

module QubeRails
  # The customer's connection's own events, which QuBe Sync POSTs to the connection's webhook
  # URL: QUBE_WEBHOOK_URL/connection/<account id>, which onboarding (POST /quickbooks/connect)
  # sets when they click Connect. The webhook job hands each one to your connection class (a
  # subclass of this, named by config.connection), with the account found again.
  #   connection.connected        the Web Connector checked in: QuickBooks is connected
  #   connection.setup_cancelled  they chose "Cancel setup" on the setup page
  #   connection.stalled          requests are stuck; see stall_reason
  #   connection.resumed          after a stall, they're being taken again
  #
  # The setup ends on the QuickBooks computer, which usually isn't signed in to your app, so
  # nothing comes back to it there: connection.connected, signed by QuBe Sync, is how your app
  # knows. A simulated connection is connected as it's made, so its connection.connected can come
  # before create_connection returns: onboarding saves the id as soon as it has it.
  #
  # The account keeps the connection's id and the last event's revision, in qube_connection_id
  # (a string) and qube_connection_revision (an integer) columns:
  #   add_column :accounts, :qube_connection_id, :string
  #   add_column :accounts, :qube_connection_revision, :integer
  # Override saved_connection_id, save_connection_id, saved_revision and save_revision to keep
  # them elsewhere.
  class ConnectionEvents
    # Your account, by the id in the connection's webhook URL.
    def self.find_record(id)
      raise NotImplementedError, "#{name}.find_record(#{id.inspect}) isn't written yet"
    end

    attr_reader :account

    def initialize(account)
      @account = account
    end

    # Where this account's connection's events go: QUBE_WEBHOOK_URL, then connection and the
    # account's id.
    def webhook_url
      QubeRails.connection_webhook_url(account.id)
    end

    # One of the connection's webhooks, from the webhook job, as the qube_sync gem parsed it (a
    # ConnectionEvent). Deliveries come at least once and, from a queue with more than one
    # worker, in any order:
    # - an event whose connection isn't the one saved on the account (a signed body posted to
    #   another account's URL) is logged and skipped;
    # - any other is applied only when its revision is newer than the last one applied, so a
    #   retried connection.stalled that comes after its connection.resumed is skipped.
    # It holds the account's row lock while it does (with_lock, which reads the account again),
    # so two workers never apply its events at once.
    def handle(event)
      account.with_lock { apply(event) }
    end

    # What your app does with each: until you fill them in, each logs.

    # QuickBooks is connected: mark the account connected, and start syncing.
    def connected(event)
      log_event(event)
    end

    # They cancelled the setup: offer Connect QuickBooks Desktop again.
    def setup_cancelled(event)
      log_event(event)
    end

    # Your requests are waiting and QuickBooks hasn't been reached. Show the customer, and tell
    # them what the event's stall_reason says:
    # - "not_checking_in": the Web Connector isn't calling in. Turn on the QuickBooks computer,
    #   and check the Web Connector runs.
    # - "quickbooks_unavailable": it is calling in and can't reach QuickBooks. Open QuickBooks
    #   with the company file.
    # A stall can send this again with a new reason (the computer was turned on, and QuickBooks
    # isn't open yet): show the newest. resumed clears it.
    def stalled(event)
      log_event(event)
    end

    # Clear what stalled showed, whichever its reason.
    def resumed(event)
      log_event(event)
    end

    # The connection id kept on the account, or nil before it first connects. Every run starts
    # on it: QuickbooksDesktop::CreateInvoice.start(invoice, connection.saved_connection_id).
    def saved_connection_id
      id = account.qube_connection_id
      id.to_s.empty? ? nil : id
    end

    # Keeps a new connection's id on the account, and forgets the last connection's revision,
    # since each connection's revisions start again at 1.
    def save_connection_id(connection_id)
      account.update_columns(qube_connection_id: connection_id, qube_connection_revision: nil)
    end

    def saved_revision
      account.qube_connection_revision
    end

    def save_revision(revision)
      account.update_columns(qube_connection_revision: revision)
    end

    private

    # Only a connection event carries a connection: any other event posted to this URL is
    # skipped as not its connection.
    def apply(event)
      connection_id = event.type == "connection" ? event.connection_id : nil
      unless connection_id && connection_id == saved_connection_id
        QubeRails.logger.warn("QuBe Sync: account #{account.id} skipped #{event.event} for " \
                              "#{connection_id.inspect}: not its connection")
        return
      end

      # Applied already, or older than what was.
      return unless event.newer_than?(saved_revision)

      if event.connected?
        connected(event)
      elsif event.setup_cancelled?
        setup_cancelled(event)
      elsif event.stalled?
        stalled(event)
      elsif event.resumed?
        resumed(event)
      else
        log_event(event)
      end
      save_revision(event.revision)
    end

    # All a handler does until you fill it in.
    def log_event(event)
      line = "QuBe Sync: account #{account.id}: #{event["event"]} (revision #{event["revision"]})"
      if event["event"] == "connection.stalled"
        QubeRails.logger.warn(line)
      else
        QubeRails.logger.info(line)
      end
    end
  end
end
