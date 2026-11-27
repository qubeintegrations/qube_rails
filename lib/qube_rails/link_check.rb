# frozen_string_literal: true

module QubeRails
  # Checks a connection's stale links (the old company file's, after
  # connection.company_file_changed) against the file it opens now, once it's connected: a plain
  # request per kind, querying up to BATCH of its ids (ListID or TxnID). An id found there with the
  # same name is kept (current again, with the answer's EditSequence); one found under another name
  # waits for the app's review (Connection#confirm_link / #reject_link); one not found is kept as
  # missing. A kind that can't be looked up by id is kept as missing when the check starts. All are
  # checked again on the next company file change. README, "A different company file".
  #
  # Its record is the connection, and its slug "qube_rails.check_links:<kind>", so it needs no
  # entry in config.operations. The stale rows are its state: a check that's queued again (a second
  # connected, a retried webhook) asks only about what is still stale.
  class LinkCheck < Request
    SLUG_PREFIX = "qube_rails.check_links:"
    BATCH = 50
    # How long after a check ended (or a queue got no answer) a held record queues it again.
    RETRY_AFTER = 5 * 60

    # Which id each kind's query takes, when the qube_sync gem's Operations::INDEX can't say (an
    # older gem, or the inline backend). A kind in neither is never queried: it's kept as missing.
    TXN_KINDS = %w[
      ar_refund_credit_card bill bill_payment_check bill_payment_credit_card build_assembly charge check
      credit_card_charge credit_card_credit credit_memo deposit estimate inventory_adjustment invoice
      item_receipt journal_entry paycheck payroll_liability_adjustment payroll_liability_check
      payroll_prior_payment payroll_year_to_date_adjustment purchase_order receive_payment sales_order
      sales_receipt sales_tax_payment_check time_tracking transaction transfer transfer_inventory
      vehicle_mileage vendor_credit
    ].freeze
    LIST_KINDS = %w[
      account billing_rate class currency customer customer_msg customer_type date_driven_terms employee
      entity inventory_site item item_discount item_fixed_asset item_group item_inventory
      item_inventory_assembly item_non_inventory item_other_charge item_payment item_sales_tax
      item_sales_tax_group item_service item_sites item_subtotal job_type lead other_name payment_method
      payroll_item payroll_item_non_wage payroll_item_wage price_level sales_rep sales_tax_code
      ship_method standard_terms terms to_do unit_of_measure_set vehicle vendor vendor_type
      workers_comp_code
    ].freeze

    # "list_id" or "txn_id": what kind's query looks records up by, from the gem's INDEX when it
    # says, else the lists above; nil for a kind that can't be looked up by id.
    def self.id_param(kind)
      entry = defined?(QubeSync::Operations::INDEX) ? QubeSync::Operations::INDEX["#{kind}.query"] : nil
      return entry[:id_param] if entry&.key?(:id_param)
      return "txn_id" if TXN_KINDS.include?(kind.to_s)

      LIST_KINDS.include?(kind.to_s) ? "list_id" : nil
    end

    # Queues a check for each kind with stale links, when the connection is connected; a kind
    # whose check is still going keeps it. A kind with no id to query is settled as missing at once.
    # Returns the requests.
    def self.start(connection)
      return [] unless connection.connected? && !connection.qube_id.to_s.empty?

      kinds = connection.stale_links.distinct.pluck(:kind).sort
      unqueryable, queryable = kinds.partition { |kind| id_param(kind).nil? }
      unqueryable.each { |kind| settle_unqueryable(connection, kind) }
      queryable.filter_map do |kind|
        self.for(kind).queue(connection, connection)
      rescue Backend::APIError => e
        raise unless e.status.between?(400, 499)

        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: couldn't check its #{kind} links (#{e.status})")
        nil
      end
    end

    # From Connection#wait_for_link_check!, for a held record's stale kinds: queues a kind's check
    # again when its last one ended (or its queue got no answer) more than RETRY_AFTER ago, or it
    # has none. Errors are logged: the caller still raises LinkBeingChecked.
    def self.revive(connection, kinds)
      return unless connection.connected? && !connection.qube_id.to_s.empty?

      kinds.each do |kind|
        if id_param(kind).nil?
          settle_unqueryable(connection, kind)
          next
        end
        check = self.for(kind)
        last = QubeRails::QueuedRequest.where(connection: connection).latest_for(connection, check::SLUG)
        next unless last.nil? || dormant?(last)

        last.touch if last && !last.ended? # the back-off counts from this try
        check.queue(connection, connection)
      rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: couldn't queue its #{kind} link check " \
                              "again (#{e.class})")
      end
    end

    def self.dormant?(row)
      since = row.ended? ? row.ended_at : (row.qube_id.nil? ? row.updated_at : nil)
      !since.nil? && since < Time.now - RETRY_AFTER
    end
    private_class_method :dormant?

    # Links of a kind no query can look up: kept as missing, and reported like a checked batch.
    def self.settle_unqueryable(connection, kind)
      links = connection.transaction do
        rows = connection.stale_links.where(kind: kind).lock.to_a
        now = Time.now
        rows.each { |link| link.update!(stale_since: nil, missing_since: now) }
      end
      return if links.empty?

      report(connection, kind, relinked: [], review: [], missing: links)
    end
    private_class_method :settle_unqueryable

    def self.report(connection, kind, result)
      found = result[:relinked].size + result[:review].size
      QubeRails.logger.info("QuBe Sync: connection #{connection.id}: #{kind} links checked: " \
                            "#{found} found (#{result[:review].size} to review), " \
                            "#{result[:missing].size} missing")
      QubeRails.config.connection_events_class.new(connection).links_checked(
        kind: kind, found: found, relinked: result[:relinked], review: result[:review],
        missing: result[:missing], stale_left: connection.stale_links.count
      )
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
      return nil unless id_key

      super(connection, connection)
    end

    def self.kind_links(connection)
      connection.stale_links.where(kind: self::KIND)
    end

    def self.id_key
      LinkCheck.id_param(self::KIND)
    end

    # The ids asked about: up to BATCH of the kind's stale links.
    def params
      ids = self.class.kind_links(connection).order(:id).limit(BATCH).pluck(:qb_id)
      { self.class.id_key.to_sym => ids }
    end

    def connection
      queued_request.connection
    end

    # The answer settles each id it asked about that's still stale.
    def answered(event)
      @settled = settle(event)
    end

    # Every page is in (one: a query by id isn't paged): the app hears, and the next batch goes.
    def done
      result = @settled
      # An answer from the old file: ask the new one.
      @next = true if result.nil? && from_old_file?
      return unless result

      @next = true
      LinkCheck.report(connection, self.class::KIND, result)
    end

    # The links stay stale, unused: a held record queues the check again after RETRY_AFTER (revive).
    def failed(event)
      log_event(event)
    end

    # A next batch that can't be queued now is queued again by revive.
    def handle(event)
      super
      return unless @next

      begin
        self.class.queue(connection, connection)
      rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: couldn't queue its next " \
                              "#{self.class::KIND} link check (#{e.class})")
      end
    end

    private

    # nil when the answer isn't one it can trust (an error, rows it didn't ask for, an odd shape, or
    # an answer from a file the connection has switched from): nothing is settled.
    def settle(event)
      if from_old_file?
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: #{self.class::KIND} link check " \
                              "#{queued_request.id} was queued before its company file changed; nothing settled")
        return nil
      end

      key = self.class.id_key
      asked = Array((queued_request.params || {})[key]).map(&:to_s)
      found = found_rows(event, key, asked)
      return nil unless found

      # A missing id makes QuickBooks warn 500, naming only the first one, but every id it has
      # still comes back: one not in the answer isn't in the file.
      result = { relinked: [], review: [], missing: [] }
      now = Time.now
      asked.each do |qb_id|
        link = self.class.kind_links(connection).find_by(qb_id: qb_id)
        next unless link # settled already: a redelivery, or linked again by a run since

        record = found[qb_id]
        if record
          keep(link, record, result)
        else
          link.update!(stale_since: nil, missing_since: now)
          result[:missing] << link
        end
      end
      result
    end

    def from_old_file?
      changed_at = connection.company_file_changed_at
      !changed_at.nil? && queued_request.created_at < changed_at
    end

    def found_rows(event, key, asked)
      answer = event.response_json
      data = answer.is_a?(Hash) && answer["status"] == "success" ? answer["data"] : nil
      rows = data.nil? ? [] : Array(data)
      unless data.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && asked.include?(row[key].to_s) }
        QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: #{self.class::KIND} link check " \
                              "answered unexpectedly; nothing settled, its links stay stale")
        return nil
      end

      rows.to_h { |row| [row[key].to_s, row] }
    end

    # An id is stamped with its record's creation time, so finding it only says the files share an
    # origin. The same name (or no name kept) keeps it; another name may be a repurposed record.
    def keep(link, record, result)
      theirs = self.class.id_key == "txn_id" ? record["ref_number"] : record["full_name"] || record["name"]
      if link.name.nil? || normal(link.name) == normal(theirs)
        link.update!(stale_since: nil, missing_since: nil,
                     edit_sequence: record["edit_sequence"] || link.edit_sequence)
        result[:relinked] << link
      else
        link.update!(stale_since: nil, review_since: Time.now, review_name: theirs.to_s,
                     edit_sequence: record["edit_sequence"] || link.edit_sequence)
        result[:review] << { link: link, record: link.record, old_name: link.name, new_name: theirs.to_s }
      end
    end

    def normal(name)
      name.to_s.strip.squeeze(" ").downcase
    end
  end
end
