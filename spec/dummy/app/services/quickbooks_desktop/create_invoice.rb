# frozen_string_literal: true

module QuickbooksDesktop
  class CreateInvoice < QubeRails::Operation
    WORKFLOW = "add_transaction"
    SLUG = "create_invoice"

    def self.find_record(id)
      Invoice.find(id)
    end

    # What each handler was called with, for the examples.
    def self.calls
      @calls ||= []
    end

    def input
      { operation: "invoice.create", params: { ref_number: record.number } }
    end

    def notification(event)
      self.class.calls << [:notification, event.delivery_id]
    end

    def ended(event)
      self.class.calls << [:ended, event.outcome]
      record.update!(status: "sent", txn_id: event.dig("output", "record", "txn_id"))
    end

    def failed(event)
      self.class.calls << [:failed, event.event]
      record.update!(status: "failed")
    end
  end
end
