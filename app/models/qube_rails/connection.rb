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
  # The QuickBooks ids your app learns are kept against it, by list family (link, qb_id_for,
  # find_linked), since a ListID is unique only within one list family of one company file.
  class Connection < ApplicationRecord
    self.table_name = "qube_connections"

    # The ones that have never connected, newest first: what Connect sends back through setup
    # rather than making another.
    scope :never_connected, -> { where(status: %w[pending setup_cancelled]).order(created_at: :desc, id: :desc) }

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

    # For a row without a qube_id: QuBe Sync's connection whose webhook URL is this row's, when a
    # create landed but its id was never saved (it didn't commit, or the process died between the
    # call and the save). Saves and returns the id, or nil when there's none, so a second
    # connection is never made for one row.
    def adopt_qube_connection
      return qube_id unless qube_id.to_s.empty?

      found = Array(QubeRails.client.list_connections).find do |made|
        made.is_a?(Hash) && made["webhook_url"].to_s.chomp("/") == webhook_url
      end
      return nil unless found && !found["id"].to_s.empty?

      QubeRails.logger.info("QuBe Sync: connection #{id} adopted QuBe Sync's connection #{found["id"]}, " \
                            "made for it before its id was saved")
      update!(qube_id: found["id"])
      qube_id
    end

    # Keeps record's QuickBooks id for kind ("invoice", "customer", "item_service"...) on this
    # connection, with its EditSequence and its name (FullName, or RefNumber), and returns the
    # row. A record has one id per kind, so linking it again replaces its id. An id already linked
    # in that kind's family (QuickbooksRecord.family_for) to another of your records moves to this
    # one, and that's logged: the same QuickBooks record can stand for one of yours at a time. The
    # same record and id linked with another kind of the family (an item converted from service
    # to non-inventory) changes the row's kind.
    def link(record, kind:, qb_id:, edit_sequence: nil, name: nil)
      kind = kind.to_s
      qb_id = qb_id.to_s
      raise ArgumentError, "link needs a qb_id" if qb_id.empty?

      family = QuickbooksRecord.family_for(kind)
      type, id = self.class.key_for(record)
      attempts = 0
      begin
        # A savepoint, so a unique-key race inside a caller's transaction (the job's row lock)
        # can be retried.
        transaction(requires_new: true) do
          taken = quickbooks_records.lock.find_by(list: family, qb_id: qb_id)
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
          row = taken || mine || quickbooks_records.build
          row.assign_attributes(kind: kind, qb_id: qb_id, record_type: type, record_id: id)
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

    # record's QuickBooks id for kind on this connection, or nil: its link of that kind, else,
    # outside the name family, its one link in that kind's family (an item linked as
    # item_service, asked for as item or item_non_inventory). In the name family each kind is its
    # own QuickBooks record (a customer and a vendor are two names), so a customer's id is never
    # handed out as a vendor's. Raises ArgumentError when the family has several and none is that
    # kind.
    def qb_id_for(record, kind:)
      type, id = self.class.key_for(record)
      mine = quickbooks_records.where(record_type: type, record_id: id)
      exact = mine.where(kind: kind.to_s).limit(1).pluck(:qb_id).first
      family = QuickbooksRecord.family_for(kind)
      return exact if exact || family == "name"

      row = only_one(mine.where(list: family), "#{type} #{id}'s #{kind}")
      row && row.qb_id
    end

    # Your record linked to that QuickBooks id, or nil.
    def find_linked(qb_id, kind: nil)
      row = quickbooks_record(qb_id, kind: kind)
      row && row.record
    end

    # The row for that QuickBooks id (with its kind, edit_sequence and name), or nil. With a kind,
    # it's looked up in that kind's family; without one, in every family, and an id found in more
    # than one (the same counter value is a customer and an account) raises ArgumentError, so the
    # caller says which kind it means.
    def quickbooks_record(qb_id, kind: nil)
      rows = quickbooks_records.where(qb_id: qb_id.to_s)
      return rows.find_by(list: QuickbooksRecord.family_for(kind)) if kind

      only_one(rows, "QuickBooks id #{qb_id}")
    end

    private

    def only_one(scope, what)
      rows = scope.limit(2).to_a
      if rows.size > 1
        kinds = scope.pluck(:kind).sort.join(", ")
        raise ArgumentError, "QuBe Sync: #{what} is linked as more than one kind (#{kinds}): pass kind:"
      end
      rows.first
    end
  end
end
