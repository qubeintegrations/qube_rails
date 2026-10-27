# frozen_string_literal: true

module QuickbooksDesktop
  class CreateInvoice < QubeRails::Operation
    WORKFLOW = "add_transaction"
    SLUG = "create_invoice"

    def self.find_record(id)
      Invoice.find_by(id: id)
    end

    # What each handler was called with, for the examples.
    def self.calls
      @calls ||= []
    end

    def input
      without_nils({ operation: "invoice.create", params: { ref_number: record.number, memo: nil } })
    end

    def notification(event)
      self.class.calls << [:notification, event.delivery_id]
    end

    def ended(event)
      self.class.calls << [:ended, event.outcome, run.id, connection.id]
      record.update!(status: "sent")
      txn = event.dig("output", "record") || {}
      connection.link(record, kind: "invoice", qb_id: txn["txn_id"], name: txn["ref_number"]) if txn["txn_id"]
    end

    def failed(event)
      self.class.calls << [:failed, event.event]
      record.update!(status: "failed")
    end
  end
end
