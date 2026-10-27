# frozen_string_literal: true

module QubeRails
  # Where a record stands, as the run status partials render it: the override contract, kept
  # stable across versions (README, "Styling"). status is QubeRails::SyncStatus's (:not_sent,
  # :sending, :needs_answer, :in_quickbooks, :done, :failed, :cancelled); state the latest run's
  # ("starting", "running", "awaiting_input", "completed", "failed" or "cancelled"), or nil.
  # summary is a few words for the pill; reason, why it failed or was cancelled, as a sentence
  # below it; detail, what to do about a failure.
  class RunStatusView
    attr_reader :status, :state, :summary, :reason, :detail, :quiet_text, :retry_url, :redeliver_url, :error, :stall,
                :stall_text

    # The stall reasons with words of their own (status.stalled.<reason>); any other is "other".
    STALL_REASONS = %w[not_checking_in quickbooks_unavailable].freeze

    # From a QubeRails::SyncStatus. urls answers retry_start_path(run) and redeliver_path(run):
    # the engine's route proxy (qube_rails) in a view. connection is the one the status is about
    # (else the latest run's): while it's stalled, a status waiting on QuickBooks (:sending) says
    # why (stall, stall_text) and offers no redelivery, since the cause is known.
    def self.from_sync(sync, urls, error: nil, connection: nil)
      run = sync.run
      state = run && (run.cancelled? ? "cancelled" : run.state)
      reason = run && (sync.failed? || run.cancelled?) ? run.reason_text : nil
      detail = sync.failed? && run ? run.error_detail : nil
      connection ||= run && run.connection
      stall = sync.status == :sending ? stall_of(connection) : nil
      stuck = run && !stall ? run.looks_stuck? : false
      new(status: sync.status, state: state,
          summary: stall ? QubeRails.t("status.waiting_for_quickbooks") : sync.summary_text, reason: reason, detail: detail,
          quiet_text: stuck ? QubeRails.t("status.quiet") : nil,
          retry_url: sync.unconfirmed? ? urls.retry_start_path(run) : nil,
          redeliver_url: stuck ? urls.redeliver_path(run) : nil, error: error, stall: stall)
    end

    # A stalled connection's reason as a Symbol (:other when it gives none), or nil.
    def self.stall_of(connection)
      return nil unless connection && connection.status == "stalled"

      reason = connection.stall_reason.to_s
      reason.empty? ? :other : reason.to_sym
    end

    def initialize(status:, state: nil, summary: nil, reason: nil, detail: nil, quiet_text: nil, retry_url: nil,
                   redeliver_url: nil, error: nil, stall: nil)
      @status = status.to_sym
      @state = state
      @summary = summary
      @reason = reason
      @detail = detail
      @quiet_text = quiet_text
      @retry_url = retry_url
      @redeliver_url = redeliver_url
      @error = error
      @stall = stall
      @stall_text = stall && QubeRails.t("status.stalled.#{STALL_REASONS.include?(stall.to_s) ? stall : "other"}")
    end

    # Nothing is shown before the record is sent (the error aside).
    def visible?
      status != :not_sent
    end

    # The qube- classes on the status element: qube-sync-<status>, qube-run-<state>, and
    # qube-connection-stalled while it waits on a stalled connection.
    def css_class
      ["qube-run-status", "qube-sync-#{status}", state && "qube-run-#{state}", stall && "qube-connection-stalled"]
        .compact.join(" ")
    end
  end
end
