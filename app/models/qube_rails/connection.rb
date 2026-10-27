# frozen_string_literal: true

require "erb"
require "time"

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
    has_many :queued_requests, class_name: "QubeRails::QueuedRequest", inverse_of: :connection
    has_many :quickbooks_records, class_name: "QubeRails::QuickbooksRecord", inverse_of: :connection

    validates :status, inclusion: { in: STATUSES }

    # The connections owner has, whatever its key's type.
    # The row, with its runs (and their notifications), its requests and its QuickBooks links: a connection
    # QuBe Sync no longer has. ConnectionsController#destroy deletes QuBe Sync's first.
    def disconnect!
      transaction do
        QubeRails.config.connection_events_class.new(self).disconnected
        runs.find_each(&:destroy!)
        QubeRails::QueuedRequest.where(connection_id: id).delete_all # its deliveries cascade
        QubeRails::QuickbooksRecord.where(connection_id: id).delete_all
        destroy!
      end
    end

    # When its last completed run of workflow started (nil before one): a sync's next since.
    def last_synced_at(workflow)
      QubeRails::SyncMark.find_by(connection_id: id, workflow: workflow.to_s)&.started_at
    end

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

    # Stalled because the Web Connector isn't checking in (the QuickBooks computer is off, or
    # the Web Connector closed), rather than because it can't open QuickBooks.
    def not_checking_in?
      status == "stalled" && stall_reason == "not_checking_in"
    end

    # Clock difference allowed between this app and QuBe Sync.
    CLOCK_SKEW_SECONDS = 5 * 60

    # For a row without a qube_id: QuBe Sync's connection made for it, when a create landed but
    # its id was never saved (it didn't commit, or the process died between the call and the
    # save). Saves and returns the id, or nil, so a second connection is never made for one row.
    #
    # It lists the app's connections (GET /api/v2/connections, which isn't paged) and adopts one
    # only when exactly one has this row's webhook URL, is unclaimed (it has never connected, or
    # it's simulated: a simulated connection connects as it's made), was made at or after this row
    # (its created_at), and has the row's name when the row has one. So a row id used again (MySQL 5.7 after a restart, a restored database) never takes
    # an old connection. A connection with no created_at (a server from before v2 sent it) is
    # never adopted. The listing only runs for a row without an id, which is rare.
    def adopt_qube_connection
      return qube_id unless qube_id.to_s.empty?

      listed = Array(QubeRails.client.list_connections).select { |made| made.is_a?(Hash) }
      if listed.any? { |made| made["created_at"].to_s.empty? && same_url?(made) }
        QubeRails.logger.warn("QuBe Sync: connection #{id}: QuBe Sync's connections carry no created_at, so " \
                              "none is adopted; a new one is made instead")
      end
      candidates = listed.select { |made| made_for_this_row?(made) }
      if candidates.size > 1
        QubeRails.logger.warn("QuBe Sync: connection #{id} has no qube_id and #{candidates.size} of QuBe Sync's " \
                              "connections could be its; adopted none")
        return nil
      end
      found = candidates.first
      return nil unless found

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
          if replaced?(mine, by: taken)
            QubeRails.logger.info("QuBe Sync: connection #{self.id}: #{type} #{id}'s #{kind} " \
                                  "#{mine.qb_id} replaced by #{qb_id}")
            mine.destroy!
          end
          if moved?(taken, to: [type, id])
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

    # Where record stands with QuickBooks on this connection for operation (its SLUG): a
    # QubeRails::SyncStatus, worked out from its runs and its link, never stored.
    def sync_status(record, operation:)
      SyncStatus.for(self, record, operation: operation)
    end

    # Your records in scope (a model or a relation) with a QuickBooks link on this connection, or
    # without one: for list pages and filters, one query each. They join on
    # qube_quickbooks_records' record index, by your table's primary key as text.
    def in_quickbooks(scope)
      scope.where(linked_here(scope))
    end

    def not_in_quickbooks(scope)
      scope.where.not(linked_here(scope))
    end

    # Your records in scope whose run of operation on this connection is waiting for your user's
    # answer, or still on its way (starting or running): their latest run, since a start returns
    # the run that hasn't ended rather than starting another.
    def needing_answer(scope, operation:)
      scope.where(run_here(scope, operation, %w[awaiting_input]))
    end

    def sending(scope, operation:)
      scope.where(run_here(scope, operation, %w[starting running]))
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

    # The record's own link is a different row from the one holding this qb_id, so it gives way.
    def replaced?(mine, by:)
      !mine.nil? && !by.nil? && by.id != mine.id
    end

    # This qb_id was linked to another of your records.
    def moved?(taken, to:)
      !taken.nil? && !taken.record_id.nil? && [taken.record_type, taken.record_id] != to
    end

    def same_url?(made)
      made["webhook_url"].to_s.chomp("/") == webhook_url
    end

    def made_for_this_row?(made)
      return false if made["id"].to_s.empty?
      return false unless same_url?(made)
      return false unless unclaimed?(made)
      return false unless name.to_s.empty? || made["name"] == name

      made_at = parse_time(made["created_at"])
      return false unless made_at && created_at

      made_at >= created_at - CLOCK_SKEW_SECONDS
    end

    # Nobody can have set it up: it has never connected, or it's simulated and connected itself
    # when it was made. Either way, only the lost answer to the create carried its setup link.
    def unclaimed?(made)
      made["last_connected_at"].nil? || made["type"] == "simulated"
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # EXISTS a link on this connection for each row of scope's table.
    def linked_here(scope)
      model = scope.all.klass
      QuickbooksRecord.where(connection_id: id, record_type: model.base_class.name)
                      .where("qube_quickbooks_records.record_id = #{id_as_text(model, QuickbooksRecord)}")
                      .arel.exists
    end

    # EXISTS a run of operation on this connection, in one of states, for each row of scope's
    # table.
    def run_here(scope, operation, states)
      model = scope.all.klass
      Run.where(connection_id: id, operation: operation.to_s, record_type: model.base_class.name,
                state: states)
         .where("qube_runs.record_id = #{id_as_text(model, Run)}")
         .arel.exists
    end

    # The app's primary key as the text the engine keeps ids as (integer or UUID alike), to
    # compare with engine_model's record_id. Elsewhere a VARCHAR, which compares without padding.
    # MySQL casts only to CHAR, in the connection's collation, which can differ from the
    # column's (an "illegal mix of collations"), so it's given the column's.
    def id_as_text(model, engine_model)
      db = model.connection
      column = "#{db.quote_table_name(model.table_name)}.#{db.quote_column_name(model.primary_key)}"
      return "CAST(#{column} AS VARCHAR(255))" unless mysql?(db)

      collation = engine_model.columns_hash["record_id"].collation
      return "CAST(#{column} AS CHAR)" unless collation

      "CONVERT(CAST(#{column} AS CHAR) USING #{collation.split("_").first}) COLLATE #{collation}"
    end

    def mysql?(db)
      db.adapter_name.match?(/mysql|trilogy/i)
    end

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
