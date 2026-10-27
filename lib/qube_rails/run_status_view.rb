# frozen_string_literal: true

module QubeRails
  # Where a record stands, as the run status partials render it: the override contract, kept
  # stable across versions (README, "Styling"). status is QubeRails::SyncStatus's (:not_sent,
  # :sending, :needs_answer, :in_quickbooks, :done, :failed, :cancelled); state the latest run's
  # ("starting", "running", "awaiting_input", "completed", "failed" or "cancelled"), or nil.
  class RunStatusView
    QUIET_TEXT = "No news from QuBe Sync about it for a while."

    attr_reader :status, :state, :summary, :detail, :quiet_text, :retry_url, :redeliver_url, :error

    # From a QubeRails::SyncStatus. urls answers retry_start_path(run) and redeliver_path(run):
    # the engine's route proxy (qube_rails) in a view.
    def self.from_sync(sync, urls, error: nil)
      run = sync.run
      state = run && (run.cancelled? ? "cancelled" : run.state)
      detail = sync.failed? && run ? run.error_detail : nil
      stuck = run ? run.looks_stuck? : false
      new(status: sync.status, state: state, summary: sync.summary_text, detail: detail,
          quiet_text: stuck ? QUIET_TEXT : nil,
          retry_url: sync.unconfirmed? ? urls.retry_start_path(run) : nil,
          redeliver_url: stuck ? urls.redeliver_path(run) : nil, error: error)
    end

    def initialize(status:, state: nil, summary: nil, detail: nil, quiet_text: nil, retry_url: nil,
                   redeliver_url: nil, error: nil)
      @status = status.to_sym
      @state = state
      @summary = summary
      @detail = detail
      @quiet_text = quiet_text
      @retry_url = retry_url
      @redeliver_url = redeliver_url
      @error = error
    end

    # Nothing is shown before the record is sent (the error aside).
    def visible?
      status != :not_sent
    end

    # The qube- classes on the status element: qube-sync-<status> and qube-run-<state>.
    def css_class
      ["qube-run-status", "qube-sync-#{status}", state && "qube-run-#{state}"].compact.join(" ")
    end
  end
end
