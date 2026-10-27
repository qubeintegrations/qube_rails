# frozen_string_literal: true

module QubeRails
  # A request webhook the handler has taken, by page_request_id:state, written in the handler's
  # transaction. Deleted with its request.
  class RequestDelivery < ApplicationRecord
    self.table_name = "qube_request_deliveries"

    belongs_to :queued_request, class_name: "QubeRails::QueuedRequest", foreign_key: :request_id,
                                inverse_of: :deliveries
  end
end
