# frozen_string_literal: true

module QubeRails
  # Checks a connection's stale links (the old company file's, after
  # connection.company_file_changed) against the file it opens now, once it's connected: a plain
  # request per kind, querying up to BATCH of its ids (ListID or TxnID). A link found there with
  # the name it was kept with (FullName, or a transaction's RefNumber) is current again, with the
  # answer's EditSequence; one not found, or found with another name, is deleted, so its record is
  # matched by name like one never linked. README, "A different company file".
  #
  # Its record is the connection, and its slug "qube_rails.check_links:<kind>", so it needs no
  # entry in config.operations. The stale rows are its state: a check that's queued again (a second
  # connected, a retried webhook) asks only about what is still stale.
  class LinkCheck < Request
    SLUG_PREFIX = "qube_rails.check_links:"
    BATCH = 50

    # The kinds a query by TxnID checks. Every other kind is queried by ListID ("<kind>.query").
    TXN_KINDS = %w[
      ar_refund_credit_card bill bill_payment_check bill_payment_credit_card build_assembly charge check
      credit_card_charge credit_card_credit credit_memo deposit estimate inventory_adjustment invoice
      item_receipt journal_entry paycheck payroll_liability_adjustment payroll_liability_check
      payroll_prior_payment payroll_year_to_date_adjustment purchase_order receive_payment sales_order
      sales_receipt sales_tax_payment_check time_tracking transaction transfer transfer_inventory
      vehicle_mileage vendor_credit
    ].freeze

    # Queues a check for each kind with stale links, when the connection is connected; a kind
    # whose check is still going keeps it. Returns the requests.
    def self.start(connection)
      return [] unless connection.connected? && !connection.qube_id.to_s.empty?

      connection.stale_links.distinct.pluck(:kind).sort.filter_map do |kind|
        self.for(kind).queue(connection, connection)
      rescue Backend::APIError => e
        raise unless e.status.between?(400, 499)

        # QuBe Sync refused it (a kind with no query): its links stay stale, unused.
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: couldn't check its #{kind} links (#{e.status})")
        nil
      end
    end

    # The check for one kind, as its own class (Request keys a request by record and SLUG).
    def self.for(kind)
      kind = kind.to_s
      raise ArgumentError, "QuBe Sync: no kind #{kind.inspect} to check" unless kind.match?(/\A[a-z0-9_]+\z/)

      @kinds ||= {}
      @kinds[kind] ||= Class.new(self) do
        const_set(:KIND, kind)
        const_set(:SLUG, "#{SLUG_PREFIX}#{kind}")
        const_set(:OPERATION, "#{kind}.query")
        def self.name
          "QubeRails::LinkCheck(#{self::KIND})"
        end
      end
    end

    def self.for_slug(slug)
      self.for(slug.to_s.delete_prefix(SLUG_PREFIX))
    end

    def self.queue(_record, connection)
      return nil unless connection.connected? && kind_links(connection).exists?
      return nil unless known_operation?(connection)

      super(connection, connection)
    end

    # A kind with no "<kind>.query" (one your app named itself) can't be checked: its links stay
    # stale, unused, and its records are matched by name when they're next sent.
    def self.known_operation?(connection)
      return true unless defined?(QubeSync::Operations::INDEX)
      return true if QubeSync::Operations::INDEX.key?(self::OPERATION)

      QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: no #{self::OPERATION} to check its #{self::KIND} links")
      false
    end

    def self.kind_links(connection)
      connection.stale_links.where(kind: self::KIND)
    end

    def self.id_key
      TXN_KINDS.include?(self::KIND) ? "txn_id" : "list_id"
    end

    # The ids asked about: one that a batch's answer left unsettled (check_alone) on its own, else
    # up to BATCH.
    def params
      links = self.class.kind_links(connection).order(:id)
      alone = links.where(check_alone: true).limit(1).pluck(:qb_id)
      ids = alone.empty? ? links.where(check_alone: false).limit(BATCH).pluck(:qb_id) : alone
      { self.class.id_key.to_sym => ids }
    end

    def connection
      queued_request.connection
    end

    # The answer settles each id it asked about that's still stale.
    def answered(event)
      result = settle(event)
      QubeRails.logger.info("QuBe Sync: connection #{connection.id}: #{self.class::KIND} links checked: " \
                            "#{result[:relinked]} relinked, #{result[:dropped]} dropped")
      @settled = result
    end

    # Every page is in (one: a query by id isn't paged): the app hears, and the next batch goes.
    def done
      @done = true
      result = @settled || { relinked: 0, dropped: 0 }
      events = QubeRails.config.connection_events_class.new(connection)
      events.links_checked(kind: self.class::KIND, relinked: result[:relinked], dropped: result[:dropped],
                           stale_left: connection.stale_links.count)
    end

    # The links stay stale, unused: the connection's next event (or check_stale_links) asks again.
    def failed(event)
      log_event(event)
    end

    def handle(event)
      super
      self.class.queue(connection, connection) if @done
    end

    private

    def settle(event)
      key = self.class.id_key
      asked = Array((queued_request.params || {})[key])
      answer = event.response_json.is_a?(Hash) ? event.response_json : {}
      found = Array(answer["data"]).select { |row| row.is_a?(Hash) }.to_h { |row| [row[key].to_s, row] }
      # QuickBooks answers 500 when an id isn't there, and may leave out the ones that are.
      unsure = asked.size > 1 && answer.dig("warning", "code").to_s == "500"
      result = { relinked: 0, dropped: 0 }
      asked.each do |qb_id|
        link = self.class.kind_links(connection).find_by(qb_id: qb_id)
        next unless link # settled already: a redelivery, or linked again by a run since

        record = found[qb_id.to_s]
        if record && same_record?(link, record)
          link.update!(stale_since: nil, check_alone: false,
                       edit_sequence: record["edit_sequence"] || link.edit_sequence)
          result[:relinked] += 1
        elsif record.nil? && unsure
          link.update!(check_alone: true)
        else
          link.destroy!
          result[:dropped] += 1
        end
      end
      result
    end

    # The name the link was kept with: a list record's FullName (or Name), a transaction's
    # RefNumber. A link kept without one is taken on its id alone.
    def same_record?(link, record)
      return true if link.name.to_s.empty?

      theirs = self.class.id_key == "txn_id" ? record["ref_number"] : record["full_name"] || record["name"]
      theirs.to_s == link.name.to_s
    end
  end
end
