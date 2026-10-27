# frozen_string_literal: true

module QubeRails
  # Where one of your records stands with QuickBooks on one connection, for one operation,
  # worked out from what the engine already keeps: the record's runs (qube_runs) and its
  # QuickBooks link (qube_quickbooks_records). Nothing is stored for it, so it can't go stale,
  # and your tables need no status column.
  #
  #   status = connection.sync_status(invoice, operation: "create_invoice")
  #   status.status    # => :not_sent, :sending, :needs_answer, :in_quickbooks, :done, :failed or
  #                    #    :cancelled
  #   status.qb_id     # the record's QuickBooks id on this connection, when it's linked
  #   status.error     # a failed run's error ({ "message" => ..., ... }), else nil
  #   status.retry?    # whether starting it again makes sense
  #
  # Per connection: an invoice can be in one company file and not another.
  #
  # The run and the link can disagree (a record linked earlier, with a new run since), so the
  # newest word wins, in this order:
  # 1. the latest run hasn't ended: :sending (starting or running, an unconfirmed start too:
  #    unconfirmed? says so) or :needs_answer (awaiting input), whatever the link says;
  # 2. the latest run failed or was cancelled after the link was made (or there's no link):
  #    :failed or :cancelled;
  # 3. the record is linked: :in_quickbooks, always with its qb_id;
  # 4. the latest run completed and linked nothing (an operation that doesn't link its record):
  #    :done, which a start may follow, since nothing in QuickBooks stands for the record;
  # 5. neither: :not_sent.
  class SyncStatus
    STATUSES = %i[not_sent sending needs_answer in_quickbooks done failed cancelled].freeze

    attr_reader :status, :run, :link

    # record's status on connection for operation (its SLUG).
    def self.for(connection, record, operation:)
      run = QubeRails::Run.where(connection: connection).latest_for(record, operation)
      type, id = QubeRails::ApplicationRecord.key_for(record)
      link = connection.quickbooks_records.where(record_type: type, record_id: id)
                       .order(updated_at: :desc, id: :desc).first
      new(status_of(run, link), run, link)
    end

    # record's status on the connection its latest run of operation went out on: what a record's
    # page shows when it doesn't say which connection. :not_sent when it has no run.
    def self.latest(record, operation:)
      run = QubeRails::Run.latest_for(record, operation)
      return new(:not_sent, nil, nil) unless run

      self.for(run.connection, record, operation: operation)
    end

    def self.status_of(run, link)
      return in_flight(run) if run && !run.ended?
      return stopped(run) if stopped_since_link?(run, link)
      return :in_quickbooks if link
      return :done if run&.state == "completed"

      :not_sent
    end
    private_class_method :status_of

    def self.in_flight(run)
      run.state == "awaiting_input" ? :needs_answer : :sending
    end
    private_class_method :in_flight

    def self.stopped(run)
      run.cancelled? ? :cancelled : :failed
    end
    private_class_method :stopped

    # The latest run failed or was cancelled, and the link (if any) is older than its end.
    def self.stopped_since_link?(run, link)
      return false unless run && (run.failed? || run.cancelled?)

      link.nil? || link.updated_at <= (run.ended_at || run.updated_at)
    end
    private_class_method :stopped_since_link?

    def initialize(status, run, link)
      @status = status
      @run = run
      @link = link
    end

    STATUSES.each do |name|
      define_method(:"#{name}?") { status == name }
    end

    # The record's QuickBooks id on this connection, when it's linked.
    def qb_id
      link&.qb_id
    end

    # A failed run's error, as its event carried it.
    def error
      run&.error if failed?
    end

    # A start QuBe Sync hasn't confirmed for a minute: run.retry_start! sends it again.
    def unconfirmed?
      sending? && run.unconfirmed?
    end

    # Whether starting the operation again makes sense: after a failure or a cancellation, unless
    # the record is in QuickBooks on this connection anyway (an add sent again would add it twice).
    # Not while a run is going: a start then returns that run.
    def retry?
      (failed? || cancelled?) && link.nil?
    end

    # Where it stands, in one plain sentence for a person (the run's, QubeRails::Run#summary_text,
    # when a run says it), or nil when it hasn't been sent.
    def summary_text
      return nil if not_sent?
      return QubeRails.t("status.in_quickbooks") if in_quickbooks? && run&.state != "completed"

      run.summary_text
    end

    def to_s
      status.to_s
    end
  end
end
