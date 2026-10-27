# frozen_string_literal: true

require "erb"

module QubeRails
  # One plain v2 request (QubeRails::Request.queue) for one of your records, on one connection.
  # Written before it's sent; its webhook URL is QUBE_WEBHOOK_URL/requests/<id>.
  #
  # state: "queued", "retryable", "response_received", "error", "timed_out", "discarded", or
  # "failed" (QuBe Sync refused the queue, or params raised). ended_at is set once it's over:
  # every page answered, or a final error.
  class QueuedRequest < ApplicationRecord
    self.table_name = "qube_requests"

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :queued_requests
    belongs_to :record, polymorphic: true
    has_many :deliveries, class_name: "QubeRails::RequestDelivery", foreign_key: :request_id,
                          inverse_of: :queued_request, dependent: :delete_all

    JSONCoder.serialize(self, :params, :error)

    # Set by Request.queue when it returned this row rather than queueing another. Not saved.
    attr_writer :reused

    def reused?
      @reused == true
    end

    def self.latest_for(record, operation)
      type, id = key_for(record)
      where(record_type: type, record_id: id, operation: operation.to_s)
        .order(created_at: :desc, id: :desc).first
    end

    # Ended requests older than older_than (at least a day, as Run.prunable).
    def self.prunable(older_than:)
      cutoff = [older_than, 1.day].max.ago
      where.not(ended_at: nil).where("ended_at < ?", cutoff)
    end

    def ended?
      !ended_at.nil?
    end

    # Every page answered.
    def done?
      ended? && state == "response_received"
    end

    def webhook_url
      "#{QubeRails.config.webhook_url}/requests/#{ERB::Util.url_encode(id.to_s)}"
    end

    # Sends a queue QuBe Sync never confirmed again: same params and Idempotency-Key.
    def retry_queue!
      request_class = QubeRails.config.operation_class(operation_slug)
      raise UnknownOperation, "QuBe Sync: no operation has the slug #{operation_slug.inspect}" unless request_class

      request_class.retry_queue(self)
    end

    def operation_slug
      self[:operation]
    end
  end
end
