# frozen_string_literal: true

module QubeRails
  # A QuickBooks record your app knows on one connection: its kind ("customer", "item_service",
  # "invoice"...), its list family (list), its ListID or TxnID (qb_id), its EditSequence and its
  # name, and which of your records it stands for, if any. Written through Connection#link.
  #
  # QuickBooks makes a ListID unique within a list family, not within one kind (verified on
  # QuickBooks Enterprise 24.0): customers, vendors, employees and other names share one counter,
  # every item type shares another, and each other list (accounts, classes, terms...) has its
  # own, while the same counter value turns up in several families. So a row is unique by
  # connection, family and qb_id, and by connection, kind and your record (one contact can be
  # both a customer and a vendor, as two QuickBooks names).
  #
  # A row with stale_since is the old company file's, after connection.company_file_changed, until
  # QubeRails::LinkCheck looks it up on the new file; one with missing_since wasn't there; one with
  # review_since was, under another name (review_name), and waits for Connection#confirm_link or
  # #reject_link. None of them is used: every reader takes current.
  class QuickbooksRecord < ApplicationRecord
    self.table_name = "qube_quickbooks_records"

    NAME_KINDS = %w[customer vendor employee other_name].freeze

    belongs_to :connection, class_name: "QubeRails::Connection", inverse_of: :quickbooks_records
    belongs_to :record, polymorphic: true, optional: true

    before_validation { self.list = self.class.family_for(kind) }

    scope :current, -> { where(stale_since: nil, missing_since: nil, review_since: nil) }
    scope :stale, -> { where.not(stale_since: nil) }
    scope :missing, -> { where.not(missing_since: nil) }
    scope :under_review, -> { where.not(review_since: nil) }

    def stale?
      !stale_since.nil?
    end

    def missing?
      !missing_since.nil?
    end

    def under_review?
      !review_since.nil?
    end

    # The list family a kind's ids are unique within: "name" for customers, vendors, employees
    # and other names; "item" for "item" and every item_* kind; for anything else (an account, a
    # class, a transaction, a kind this version doesn't know) the kind itself. TxnIDs are taken as
    # unique per transaction type until QuickBooks shows otherwise.
    def self.family_for(kind)
      kind = kind.to_s
      return "name" if NAME_KINDS.include?(kind)
      return "item" if kind == "item" || kind.start_with?("item_")

      kind
    end
  end
end
