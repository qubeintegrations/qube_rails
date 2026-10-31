# frozen_string_literal: true

require "erb"

module QubeRails
  # One workflow run, of one operation, for one of your records, on one connection. Written
  # before the run starts (Operation.start), so a webhook that arrives first finds it; its
  # webhook URL is QUBE_WEBHOOK_URL/runs/<id>.
  #
  # reference is new for every run and sent with it, and every event is checked against it and
  # the connection's qube_id. revision is the last event applied; state ("starting", then the
  # run's own: "running", "awaiting_input", "completed", "failed", "cancelled") and outcome are
  # the run's as of that event. question and links are the question it's asking, if any, for the
  # question partial. input is what the run was started with. A start QuBe Sync refused (a 4xx),
  # or whose input raised, leaves state "failed"; one that got no answer (a timeout, a 5xx, a
  # dropped connection) stays "starting", for retry_start!. One refused as realtime_required is
  # "realtime_required", with that error, and isn't ended: retry_start! sends it once upgraded.
  class Run < ApplicationRecord
    self.table_name = "qube_runs"

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :runs
    belongs_to :record, polymorphic: true
    has_many :notifications, class_name: "QubeRails::Notification", dependent: :delete_all

    JSONCoder.serialize(self, :input, :error, :question, :links)

    ENDED_STATES = %w[completed failed cancelled].freeze

    # Set by Operation.start when it returned this run, one that hadn't ended, rather than starting
    # another: the record's run already on its way. Not saved.
    attr_writer :reused

    def reused?
      @reused == true
    end

    # record's newest run of operation, or nil: the one whose question the partial shows.
    def self.latest_for(record, operation)
      type, id = key_for(record)
      where(record_type: type, record_id: id, operation: operation.to_s)
        .order(created_at: :desc, id: :desc).first
    end

    # Sends a start that didn't get an answer again: same reference (the Idempotency-Key),
    # workflow, input and webhook URL, so QuBe Sync answers with the run the first one started,
    # if it did, instead of starting another. See Operation.retry_start.
    def retry_start!
      operation = QubeRails.config.operation_class(operation_slug)
      raise UnknownOperation, "QuBe Sync: no operation has the slug #{operation_slug.inspect}" unless operation

      operation.retry_start(self)
    end

    def webhook_url
      "#{QubeRails.config.webhook_url}/runs/#{ERB::Util.url_encode(id.to_s)}"
    end

    def humanize(word)
      text = word.to_s.tr("_", " ")
      text.empty? ? text : text[0].upcase + text[1..-1]
    end
    private :humanize

    def operation_slug
      self[:operation]
    end

    # Whether it has ended: completed, failed or cancelled.
    # Ended runs older than older_than (at least a day: a late webhook for a deleted run is
    # retried for hours). A run that failed before it started has no ended_at.
    def self.prunable(older_than:)
      cutoff = [older_than, 1.day].max.ago
      where(state: ENDED_STATES).where("COALESCE(ended_at, updated_at) < ?", cutoff)
    end

    def ended?
      ENDED_STATES.include?(state)
    end

    def failed?
      state == "failed"
    end

    # Refused because its connection is standard; retry_start! once it's upgraded.
    def realtime_required?
      state == "realtime_required"
    end

    # Cancelled by your app (state "cancelled"), or a chart that ended on its own "cancelled"
    # outcome (the app chose to stop): neither is a success.
    def cancelled?
      state == "cancelled" || (state == "completed" && outcome == "cancelled")
    end

    # How long a start may go unconfirmed before the status says so and offers to send it again.
    UNCONFIRMED_AFTER_SECONDS = 60

    # How long a confirmed run may go without news before the status offers to have QuBe Sync
    # send its latest event again (QubeRails::RunsController#redeliver).
    QUIET_AFTER_SECONDS = 10 * 60

    # A run QuBe Sync confirmed that hasn't been heard from for QUIET_AFTER_SECONDS: running,
    # or waiting on a question this app never received. Its webhook may have been lost (the app
    # was down longer than QuBe Sync's retries), so the status offers to send it again.
    def looks_stuck?
      quiet_since?(Time.now - QUIET_AFTER_SECONDS) && (state == "running" || question_missing?)
    end

    # A start QuBe Sync hasn't confirmed for a minute: send it again with retry_start!.
    def quiet_since?(time)
      !qube_run_id.to_s.empty? && !ended? && updated_at && updated_at < time
    end
    private :quiet_since?

    def question_missing?
      state == "awaiting_input" && question.nil?
    end
    private :question_missing?

    def unconfirmed?
      state == "starting" && created_at && created_at < Time.now - UNCONFIRMED_AFTER_SECONDS
    end

    # Where it stands, in a few words for a person: "Added to QuickBooks", "Done", "Couldn't
    # sync", "Cancelled", "Needs your answer", "Sending to QuickBooks", "Still waiting for
    # QuickBooks" (a start unconfirmed for a minute) or "Syncing with QuickBooks". Why it failed
    # or was cancelled is reason_text. The words are I18n's, under qube_rails.status.
    def summary_text
      return QubeRails.t("status.cancelled") if cancelled?

      case state
      when "starting"
        QubeRails.t(unconfirmed? ? "status.unconfirmed" : "status.starting")
      when "completed"
        case outcome.to_s
        when "added" then QubeRails.t("status.added")
        when "", "completed" then QubeRails.t("status.done")
        else QubeRails.t("status.done_with", outcome: humanize(outcome))
        end
      when "failed" then QubeRails.t("status.failed")
      when "realtime_required" then error_message.to_s.empty? ? QubeRails.t("status.realtime_required") : error_message
      when "awaiting_input" then QubeRails.t("status.needs_answer")
      else QubeRails.t("status.running")
      end
    end

    # Why it failed (its error message) or was cancelled (the reason it carried), as a sentence,
    # or nil.
    def reason_text
      text = if cancelled? then cancel_reason.to_s.strip
             elsif state == "failed" then error_message.to_s.strip
             end
      return nil if text.nil? || text.empty?

      text = text[0].upcase + text[1..]
      text.match?(/[.!?]\z/) ? text : "#{text}."
    end

    # Why it was cancelled: the reason it carried, else what a cancelled outcome means.
    def cancel_reason_text
      reason = cancel_reason.to_s.strip
      reason.empty? ? QubeRails.t("status.cancel_reason") : reason
    end

    # A failed run's message: its error's own (a sentence, or the message of a code, message and
    # detail), else its outcome in words, or nil.
    def error_message
      text =
        case error
        when String then error
        when Hash then error["message"] || error["detail"]
        end
      text = text.to_s.strip
      return text unless text.empty?
      return QubeRails.t("status.not_started") if outcome.nil? && ended_at.nil?

      outcome.to_s.empty? || outcome == "failed" ? nil : humanize(outcome)
    end

    # The error's detail, when it carries one apart from its message.
    def error_detail
      return nil unless error.is_a?(Hash)

      detail = error["detail"]
      detail = detail.to_s.strip
      detail.empty? || detail == error_message ? nil : detail
    end

    # The question it's asking, as its webhook's prompt had it, or nil.
    def open_question
      question.is_a?(Hash) ? question : nil
    end
  end
end
