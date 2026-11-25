# frozen_string_literal: true

module QubeRails
  # Checks a connection's stale links (the old company file's, after
  # connection.company_file_changed) against the file it opens now, once it's connected: a plain
  # request per kind, querying up to BATCH of its ids (ListID or TxnID). An id found there is kept
  # (current again, with the answer's EditSequence and name), renamed or not; one not found is
  # kept as missing (unused) until the next company file change checks it again. README, "A
  # different company file".
  #
  # Its record is the connection, and its slug "qube_rails.check_links:<kind>", so it needs no
  # entry in config.operations. The stale rows are its state: a check that's queued again (a second
  # connected, a retried webhook) asks only about what is still stale.
  class LinkCheck < Request
    SLUG_PREFIX = "qube_rails.check_links:"
    BATCH = 50

    # Which id each kind's query takes, when the qube_sync gem's Operations::INDEX can't say (an
    # older gem, or the inline backend). A kind in neither is never queried: it stays stale.
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
    # whose check is still going keeps it. Returns the requests.
    def self.start(connection)
      return [] unless connection.connected? && !connection.qube_id.to_s.empty?

      connection.stale_links.distinct.pluck(:kind).sort.filter_map do |kind|
        self.for(kind).queue(connection, connection)
      rescue Backend::APIError => e
        raise unless e.status.between?(400, 499)

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
      return nil unless id_key

      super(connection, connection)
    end

    def self.kind_links(connection)
      connection.stale_links.where(kind: self::KIND)
    end

    def self.id_key
      LinkCheck.id_param(self::KIND)
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

    # The answer settles each id it asked about that's still stale, unless it's unsure.
    def answered(event)
      @settled = settle(event)
    end

    # Every page is in (one: a query by id isn't paged): the app hears, and the next batch goes.
    def done
      result = @settled
      return unless result

      @next = true
      QubeRails.logger.info("QuBe Sync: connection #{connection.id}: #{self.class::KIND} links checked: " \
                            "#{result[:relinked].size} found (#{result[:renamed].size} renamed), " \
                            "#{result[:missing].size} missing")
      QubeRails.config.connection_events_class.new(connection).links_checked(
        kind: self.class::KIND, found: result[:relinked].size, relinked: result[:relinked],
        renamed: result[:renamed], missing: result[:missing], stale_left: connection.stale_links.count
      )
    end

    # The links stay stale, unused: the connection's next event (or check_stale_links) asks again.
    def failed(event)
      log_event(event)
    end

    def handle(event)
      super
      self.class.queue(connection, connection) if @next
    end

    private

    # nil when the answer isn't one it can trust (an error, rows it didn't ask for, an odd shape):
    # nothing is settled, and the links stay stale.
    def settle(event)
      key = self.class.id_key
      asked = Array((queued_request.params || {})[key]).map(&:to_s)
      found = found_rows(event, key, asked)
      return nil unless found

      answer = event.response_json
      # QuickBooks answers 500 when an id isn't there, and may leave out the ones that are.
      unsure = asked.size > 1 && answer.dig("warning", "code").to_s == "500"
      result = { relinked: [], renamed: [], missing: [] }
      now = Time.now
      asked.each do |qb_id|
        link = self.class.kind_links(connection).find_by(qb_id: qb_id)
        next unless link # settled already: a redelivery, or linked again by a run since

        record = found[qb_id]
        if record
          keep(link, record, result)
        elsif unsure
          link.update!(check_alone: true)
        else
          link.update!(stale_since: nil, missing_since: now, check_alone: false)
          result[:missing] << link
        end
      end
      result
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

    # Found means kept: current again, with what the answer says now. A new name is reported.
    def keep(link, record, result)
      theirs = self.class.id_key == "txn_id" ? record["ref_number"] : record["full_name"] || record["name"]
      old_name = link.name
      if !old_name.to_s.empty? && !theirs.to_s.empty? && normal(old_name) != normal(theirs)
        result[:renamed] << { link: link, record: link.record, old_name: old_name, new_name: theirs }
      end
      link.update!(stale_since: nil, missing_since: nil, check_alone: false,
                   edit_sequence: record["edit_sequence"] || link.edit_sequence,
                   name: theirs.to_s.empty? ? old_name : theirs)
      result[:relinked] << link
    end

    def normal(name)
      name.to_s.strip.squeeze(" ").downcase
    end
  end
end
