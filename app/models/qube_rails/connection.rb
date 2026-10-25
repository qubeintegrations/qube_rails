# frozen_string_literal: true

require "erb"

module QubeRails
  # One QuickBooks Desktop connection: a company file on a customer's computer, reached through
  # the Web Connector. Its owner is the account (or shop, or whatever your app's customer is)
  # that connected it, and an owner can have any number: two company files, or a new file after
  # a reconnect.
  #
  # qube_id is QuBe Sync's id for it, nil until QuBe Sync answers the create. status is
  # "pending" until the setup ends, then "connected", "setup_cancelled" or "stalled" (with
  # stall_reason), kept up to date by its own webhooks (QubeRails::ConnectionEvents). revision
  # is the last of those applied.
  #
  # The QuickBooks ids your app learns are kept against it, by kind (link, qb_id_for,
  # find_linked), since a ListID or TxnID is unique only within one list of one company file.
  class Connection < ApplicationRecord
    self.table_name = "qube_connections"

    STATUSES = %w[pending connected setup_cancelled stalled].freeze

    belongs_to :owner, polymorphic: true
    has_many :runs, class_name: "QubeRails::Run", inverse_of: :connection
    has_many :quickbooks_records, class_name: "QubeRails::QuickbooksRecord", inverse_of: :connection

    validates :status, inclusion: { in: STATUSES }

    # The connections owner has, whatever its key's type.
    def self.owned_by(owner)
      type, id = key_for(owner)
      where(owner_type: type, owner_id: id)
    end

    # Where its events go: QUBE_WEBHOOK_URL/connections/<id>.
    def webhook_url
      "#{QubeRails.config.webhook_url}/connections/#{ERB::Util.url_encode(id.to_s)}"
    end

    def connected?
      status == "connected"
    end

    # Keeps record's QuickBooks id for kind ("invoice", "customer", "item_service"...) on this
    # connection, with its EditSequence and its name (FullName, or RefNumber), and returns the
    # row. A record has one id per kind, so linking it again replaces its id. An id already
    # linked to another of your records moves to this one, and that's logged: the same QuickBooks
    # record can stand for one of yours at a time.
    def link(record, kind:, qb_id:, edit_sequence: nil, name: nil)
      kind = kind.to_s
      qb_id = qb_id.to_s
      raise ArgumentError, "link needs a qb_id" if qb_id.empty?

      type, id = self.class.key_for(record)
      attempts = 0
      begin
        # A savepoint, so a unique-key race inside a caller's transaction (the job's row lock)
        # can be retried.
        transaction(requires_new: true) do
          taken = quickbooks_records.lock.find_by(kind: kind, qb_id: qb_id)
          mine = quickbooks_records.lock.find_by(kind: kind, record_type: type, record_id: id)
          if taken && mine && taken.id != mine.id
            QubeRails.logger.info("QuBe Sync: connection #{self.id}: #{type} #{id}'s #{kind} " \
                                  "#{mine.qb_id} replaced by #{qb_id}")
            mine.destroy!
          end
          if taken && taken.record_id && [taken.record_type, taken.record_id] != [type, id]
            QubeRails.logger.warn("QuBe Sync: connection #{self.id}: #{kind} #{qb_id} moved from " \
                                  "#{taken.record_type} #{taken.record_id} to #{type} #{id}")
          end
          row = taken || mine || quickbooks_records.build(kind: kind)
          row.assign_attributes(qb_id: qb_id, record_type: type, record_id: id)
          row.edit_sequence = edit_sequence unless edit_sequence.nil?
          row.name = name unless name.nil?
          row.save!
          row
        end
      rescue ActiveRecord::RecordNotUnique
        # Another worker linked the same record or id at the same moment: once more, now it's
        # there to find.
        attempts += 1
        retry if attempts < 2
        raise
      end
    end

    # record's QuickBooks id for kind on this connection, or nil.
    def qb_id_for(record, kind:)
      type, id = self.class.key_for(record)
      quickbooks_records.where(kind: kind.to_s, record_type: type, record_id: id).limit(1).pluck(:qb_id).first
    end

    # Your record linked to that QuickBooks id, or nil.
    def find_linked(kind, qb_id)
      row = quickbooks_record(kind, qb_id)
      row && row.record
    end

    # The row for that QuickBooks id (with its edit_sequence and name), or nil.
    def quickbooks_record(kind, qb_id)
      quickbooks_records.find_by(kind: kind.to_s, qb_id: qb_id.to_s)
    end
  end
end
