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
  # dropped connection) stays "starting", for retry_start!.
  class Run < ApplicationRecord
    self.table_name = "qube_runs"

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :runs
    belongs_to :record, polymorphic: true

    JSONCoder.serialize(self, :input, :error, :question, :links)

    ENDED_STATES = %w[completed failed cancelled].freeze

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
    def ended?
      ENDED_STATES.include?(state)
    end

    def failed?
      state == "failed"
    end

    # Cancelled by your app (state "cancelled"), or a chart that ended on its own "cancelled"
    # outcome (the app chose to stop): neither is a success.
    def cancelled?
      state == "cancelled" || (state == "completed" && outcome == "cancelled")
    end

    # How long a start may go unconfirmed before the status says so and offers to send it again.
    UNCONFIRMED_AFTER_SECONDS = 60

    # A start QuBe Sync hasn't confirmed for a minute: send it again with retry_start!.
    def unconfirmed?
      state == "starting" && created_at && created_at < Time.now - UNCONFIRMED_AFTER_SECONDS
    end

    # Where it stands, in one plain sentence for a person: "Added to QuickBooks", "Done",
    # "Failed: <message>", "Cancelled: <reason>", "Waiting for your answer", "Starting", "Not
    # confirmed by QuBe Sync yet" or "Running".
    def summary_text
      return "Cancelled: #{cancel_reason_text}" if cancelled?

      case state
      when "starting"
        unconfirmed? ? "Not confirmed by QuBe Sync yet" : "Starting"
      when "completed"
        case outcome.to_s
        when "added" then "Added to QuickBooks"
        when "", "completed" then "Done"
        else "Done: #{humanize(outcome)}"
        end
      when "failed"
        message = error_message
        message ? "Failed: #{message}" : "Failed"
      when "awaiting_input" then "Waiting for your answer"
      else "Running"
      end
    end

    # Why it was cancelled: the reason it carried, else what a cancelled outcome means.
    def cancel_reason_text
      reason = cancel_reason.to_s.strip
      reason.empty? ? "your app chose to stop" : reason
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
      return "it couldn't be started" if outcome.nil? && ended_at.nil?

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
