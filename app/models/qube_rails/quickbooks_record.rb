# frozen_string_literal: true

module QubeRails
  # A QuickBooks record your app knows on one connection: its kind ("customer", "invoice"...),
  # its ListID or TxnID (qb_id), its EditSequence and its name, and which of your records it
  # stands for, if any. Unique by connection, kind and qb_id, and by connection, kind and your
  # record. Written through Connection#link.
  class QuickbooksRecord < ApplicationRecord
    self.table_name = "qube_quickbooks_records"

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :quickbooks_records
    belongs_to :record, polymorphic: true, optional: true
  end
end
