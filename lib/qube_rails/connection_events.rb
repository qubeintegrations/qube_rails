# frozen_string_literal: true

module QubeRails
  # A connection's own events, which QuBe Sync POSTs to the connection's webhook URL,
  # QUBE_WEBHOOK_URL/connections/<connection id>, set when onboarding makes it. The webhook job
  # applies each to the connection row (status, stall_reason, revision) and then hands it to
  # your class (a subclass of this, named by config.connection_events), which sees the
  # connection and its owner:
  #   connection.connected        the Web Connector checked in: QuickBooks is connected
  #   connection.setup_cancelled  they chose "Cancel setup" on the setup page
  #   connection.stalled          requests are stuck; see stall_reason
  #   connection.resumed          after a stall, they're being taken again
  #
  # The setup ends on the QuickBooks computer, which usually isn't signed in to your app, so
  # nothing comes back to it there: connection.connected, signed by QuBe Sync, is how your app
  # knows. connection.status already says so when your handler runs.
  class ConnectionEvents
    # The status each event leaves the connection in.
    STATUS = {
      "connection.connected" => "connected",
      "connection.setup_cancelled" => "setup_cancelled",
      "connection.stalled" => "stalled",
      "connection.resumed" => "connected"
    }.freeze

    attr_reader :connection

    def initialize(connection)
      @connection = connection
    end

    # The account (or whatever your app's customer is) that connected it.
    def owner
      connection.owner
    end

    # One of the connection's webhooks, from the webhook job, as the qube_sync gem parsed it (a
    # ConnectionEvent). Deliveries come at least once and, from a queue with more than one
    # worker, in any order:
    # - an event whose connection isn't this row's qube_id (a signed body posted to another
    #   connection's URL) is logged and skipped;
    # - any other is applied only when its revision is newer than the last one applied, so a
    #   retried connection.stalled that comes after its connection.resumed is skipped.
    # It holds the connection row's lock while it does, so two workers never apply its events at
    # once, and what your handler writes is saved with the revision or not at all.
    #
    # A row with no qube_id yet can't be checked: its id is adopted from QuBe Sync when one of the
    # app's connections there has this row's webhook URL (a create that landed but whose id
    # wasn't saved yet), and otherwise QubeRails::NotReady is raised, so the queue retries it.
    def handle(event)
      if connection.qube_id.to_s.empty?
        connection.adopt_qube_connection
        if connection.qube_id.to_s.empty?
          raise NotReady, "QuBe Sync: connection #{connection.id} has no qube_id yet; #{event.event} waits for it"
        end
      end

      applied = connection.with_lock { apply(event) }
      refresh_pages if applied && (event.stalled? || event.resumed?)
    end

    # What your app does with each: until you fill them in, each logs.

    # QuickBooks is connected: show the connection as connected, and start syncing.
    def connected(event)
      log_event(event)
    end

    # They cancelled the setup: offer Connect QuickBooks Desktop again.
    def setup_cancelled(event)
      log_event(event)
    end

    # Your requests are waiting and QuickBooks hasn't been reached. Show the customer, and tell
    # them what the event's stall_reason (and connection.stall_reason) says:
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

    # The account disconnected it (DELETE quickbooks/connections/:id): delete your rows that
    # point at it. Runs in the transaction that deletes it, before its runs and links go.
    def disconnected; end

    private

    # Only a connection event carries a connection: any other event posted to this URL is
    # skipped as not its connection.
    def apply(event)
      connection_id = event.type == "connection" ? event.connection_id : nil
      unless this_connection?(connection_id)
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id} skipped #{event.event} for " \
                              "#{connection_id.inspect}: not this connection")
        return false
      end

      # Applied already, or older than what was.
      return false unless event.newer_than?(connection.revision)

      status = STATUS[event.event]
      if status
        connection.status = status
        connection.stall_reason = event.stalled? ? event.stall_reason : nil
      end
      connection.revision = event.revision

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
      connection.save!
      true
    end

    # At most this many records' pages are told to refresh when the connection stalls or resumes.
    REFRESH_LIMIT = 200

    # A stall or a resume changes what the run status says on the pages of the records with a run
    # still going on this connection: tell them to refresh, after the change is committed (by the
    # connection's runs index, at most REFRESH_LIMIT records).
    def refresh_pages
      return unless QubeRails.refresh_broadcasts?

      going = connection.runs.where.not(state: Run::ENDED_STATES).distinct.limit(REFRESH_LIMIT)
                        .pluck(:record_type, :record_id)
      going.each do |type, id|
        model = type.safe_constantize
        record = model.respond_to?(:find_by) ? model.find_by(model.primary_key => id) : nil
        QubeRails.broadcast_refresh(record) if record
      end
    rescue StandardError => e
      QubeRails.logger.warn("QuBe Sync: couldn't tell connection #{connection.id}'s pages to refresh (#{e.class})")
    end

    # All a handler does until you fill it in.
    def log_event(event)
      line = "QuBe Sync: connection #{connection.id}: #{event["event"]} (revision #{event["revision"]})"
      if event["event"] == "connection.stalled"
        QubeRails.logger.warn(line)
      else
        QubeRails.logger.info(line)
      end
    end

    # The event is about this connection: its connection_id is the one QuBe Sync made it.
    def this_connection?(connection_id)
      !connection_id.nil? && connection_id == connection.qube_id
    end
  end
end
