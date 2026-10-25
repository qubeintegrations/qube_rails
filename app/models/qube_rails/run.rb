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
  # question partial. A start that raised leaves state "failed" and no qube_run_id.
  class Run < ApplicationRecord
    self.table_name = "qube_runs"

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :runs
    belongs_to :record, polymorphic: true

    JSONCoder.serialize(self, :question, :links)

    # record's newest run of operation, or nil: the one whose question the partial shows.
    def self.latest_for(record, operation)
      type, id = key_for(record)
      where(record_type: type, record_id: id, operation: operation.to_s)
        .order(created_at: :desc, id: :desc).first
    end

    def webhook_url
      "#{QubeRails.config.webhook_url}/runs/#{ERB::Util.url_encode(id.to_s)}"
    end

    # The question it's asking, as its webhook's prompt had it, or nil.
    def open_question
      question.is_a?(Hash) ? question : nil
    end
  end
end
