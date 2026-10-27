# frozen_string_literal: true

require "securerandom"

module QubeRails
  # One way your app starts a workflow, and what it does with that run's webhooks: subclass it
  # once per operation, in app/services/quickbooks_desktop/, and list it in config.operations by
  # its SLUG.
  #
  #   module QuickbooksDesktop
  #     class CreateInvoice < QubeRails::Operation
  #       WORKFLOW = "add_transaction"
  #       SLUG = "create_invoice"
  #
  #       def input
  #         { operation: "invoice.create", params: { ref_number: record.number } }
  #       end
  #
  #       def ended(event)
  #         txn = event.dig("output", "record") || {}
  #         connection.link(record, kind: "invoice", qb_id: txn["txn_id"],
  #                                 edit_sequence: txn["edit_sequence"], name: txn["ref_number"])
  #       end
  #     end
  #   end
  #
  #   run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)
  #
  # Each run is a row in qube_runs (QubeRails::Run), written before the run starts, and its
  # webhook URL is QUBE_WEBHOOK_URL/runs/<run id>, so the webhook job hands each event back to the
  # same class with the record, the run and its connection found again. Your record's table
  # needs no QuBe columns: the run keeps its reference, revision, state and question, and the
  # QuickBooks ids an ending carries go on the connection (connection.link), keyed by kind.
  class Operation
    # Starts the operation's run for record, one your app has saved, on connection (a
    # QubeRails::Connection the customer has finished onboarding, so it has a qube_id), and
    # returns the run row. The row is written first, with a new reference
    # (<slug>-<record id>-<uuid>) and state "starting", since a webhook can arrive before this
    # returns, and keeps the input it was started with.
    #
    # The reference is also the Idempotency-Key. When QuBe Sync refuses the start (a 4xx: bad
    # input, a workflow that isn't published) or the input raises, the row is marked "failed"
    # and the error raised: nothing was started, and starting again makes a new run. When the
    # start gets no answer (a timeout, a 5xx, a dropped connection) it may have started, so the
    # row stays "starting" and the error is raised: send it again with run.retry_start!, never a
    # new start, or a run that did start runs twice (two invoices).
    #
    # While record's last run of this operation on connection hasn't ended (completed, failed or
    # cancelled), it starts nothing new: it returns that run (run.reused? is true), sending its
    # start again first when QuBe Sync hasn't confirmed it, with the same reference and input. The
    # reference is the Idempotency-Key, so a second click gets the same run back from QuBe Sync,
    # never a second invoice. A new reference is made only once the last run has ended.
    def self.start(record, connection)
      unless made_by_qube_sync?(connection)
        raise NotConnected, "QuBe Sync: #{name}.start needs a connection QuBe Sync has made (one with a " \
                            "qube_id): the customer finishes onboarding first"
      end

      run, input_error = claim_run(record, connection)
      raise input_error if input_error
      return retry_start(run) if run.reused?

      send_start(run, run.input)
    end

    # Sends a start that got no answer again (run.retry_start! calls it): the same reference as
    # the Idempotency-Key, the same workflow, input and webhook URL. QuBe Sync answers a repeat of
    # a start it took with the run that start made (201, Idempotent-Replayed: true) rather than
    # starting another, for as long as that run is kept (60 days after it ends); a start it never
    # took starts now. Returns the run; a run already answered is returned as it is.
    def self.retry_start(run)
      return run if run.qube_run_id
      unless run.state == "starting"
        raise ArgumentError, "QuBe Sync: run #{run.id} is #{run.state}: only a start that got no answer is sent again"
      end

      send_start(run, run.input)
    end

    # The record's run that hasn't ended on connection (reused), or a new row with a new reference
    # and its input, written together under the connection row's lock: two starts of one record at
    # once (a double click) find the same row, so they send the same reference and input. Returns
    # [run, error]: the error an input raised, raised once the lock's transaction has kept the row.
    def self.claim_run(record, connection)
      connection.with_lock do
        going = QubeRails::Run.where(connection: connection).latest_for(record, self::SLUG)
        next [going.tap { |run| run.reused = true }, nil] if going && !going.ended?

        new_run(record, connection)
      end
    end
    private_class_method :claim_run

    # [run, nil], or for an input that raises, the run kept as "failed" (nothing was started) and
    # the error.
    def self.new_run(record, connection)
      run = QubeRails::Run.new(
        connection: connection, operation: self::SLUG, record: record,
        reference: "#{self::SLUG}-#{record.id}-#{SecureRandom.uuid}", state: "starting", revision: 0
      )
      begin
        # As JSON reads it back, so a retry sends exactly what the first start did.
        run.input = JSONCoder.load(JSONCoder.dump(new(record, run).input))
      rescue StandardError, NotImplementedError => e # an input not written yet, too
        run.update!(state: "failed")
        return [run, e]
      end
      run.save!
      [run, nil]
    end
    private_class_method :new_run

    def self.send_start(run, input)
      started =
        begin
          QubeRails.client.start_run(run.connection.qube_id, self::WORKFLOW, input,
                                     reference: run.reference, webhook_url: run.webhook_url)
        rescue Backend::APIError => e
          mark_failed(run) if refused?(e)
          raise
        end
      record_start(run, started.is_a?(Hash) ? started : {})
      run
    end
    private_class_method :send_start

    # A 4xx: nothing started. But 409, the Idempotency-Key in use by another call still in flight
    # (the other click of a double click): that start may land, so the run stays "starting".
    def self.refused?(error)
      error.status.between?(400, 499) && error.status != 409
    end
    private_class_method :refused?

    def self.mark_failed(run)
      run.update_columns(state: "failed", updated_at: Time.now)
    end
    private_class_method :mark_failed

    # The run's id, links and state from QuBe Sync's answer. Its webhooks may have come first, so
    # the state is taken only while the row still says "starting".
    def self.record_start(run, started)
      links = started["links"].is_a?(Hash) ? started["links"] : {}
      run.with_lock do
        run.qube_run_id = started["id"]
        run.run_url = links["run"]
        run.cancel_url = links["cancel"]
        run.state = started["state"] if run.state == "starting" && started["state"]
        run.save!
      end
    end
    private_class_method :record_start

    # A QubeRails::Connection QuBe Sync has made: one with a qube_id.
    def self.made_by_qube_sync?(connection)
      connection.is_a?(QubeRails::Connection) && !connection.qube_id.to_s.empty?
    end
    private_class_method :made_by_qube_sync?

    # Your record, by the id its run keeps (a String). Leave it out and the run finds it by its
    # record_type (run.record); write it to load what input and the handlers read with it:
    #   def self.find_record(id)
    #     Invoice.includes(lines: :item).find(id)
    #   end
    def self.find_record(id)
      raise NotImplementedError, "#{name}.find_record(#{id.inspect}) isn't written: leave it out to " \
                                 "find the record by the run's record_type"
    end

    # The run's record: find_record when the operation writes one, else the run's own lookup.
    def self.record_for(run)
      if method(:find_record).owner == QubeRails::Operation.singleton_class
        run.record
      else
        find_record(run.record_id)
      end
    end

    attr_reader :record, :run

    def initialize(record, run)
      @record = record
      @run = run
    end

    # The connection the run is on (a QubeRails::Connection): where the QuickBooks ids an ending
    # carries are kept (connection.link), and where the ones the input names are read
    # (connection.qb_id_for).
    def connection
      run.connection
    end

    # When this connection's last completed run of WORKFLOW started (nil before one): an
    # incremental sync's since.
    def last_synced_at
      connection.last_synced_at(self.class::WORKFLOW)
    end

    # The run's input, from the record. Each operation says how. It returns a Hash; with typed
    # workflow starts (`bin/rails g qube_rails:workflows`, which writes app/qube/qube_workflows.rb),
    # it can return the workflow's own input method's, whose operation bodies are typed and
    # documented as the operation's params:
    #   def input
    #     QubeWorkflows::AddTransaction.invoice_input({ customer_ref: quickbooks_ref(...), ... })
    #   end
    # whose RBS type is QubeWorkflows::AddTransaction::invoice_input (the workflow's module, then
    # <branch>_input, or input for a workflow whose input has no branches).
    def input
      raise NotImplementedError, "#{self.class.name}#input isn't written yet"
    end

    # One of the run's webhooks, from the webhook job, as the qube_sync gem parsed it: a
    # WorkflowRunEvent or a NotificationEvent. Deliveries come at least once and, from a queue
    # with more than one worker, in any order:
    # - an event whose reference isn't the run's, or whose connection_id isn't its connection's
    #   qube_id (a signed body posted to another run's URL), is logged and skipped;
    # - a notification is taken once, by its delivery_id (in qube_notifications, with what the
    #   handler writes; the dedupe setting);
    # - any other event is applied only when its revision is newer than the last one applied.
    # It holds the run row's lock while it does (with_lock, which reads it again), so two workers
    # never apply one run's events at once, and what a handler writes is saved with the revision
    # or not at all.
    #
    # Once an event has changed the run, pages showing record's run (the engine's partials) are
    # told to refresh (QubeRails.broadcast_refresh), so a new question or an ending shows without
    # a reload in an app with turbo-rails.
    def handle(event)
      before = run.revision
      run.with_lock { apply(event) }
      QubeRails.broadcast_refresh(record) unless run.revision == before
    end

    # A question the run asks: kept whole on the run, with its links (where to answer it, and
    # where a record field searches), for the question partial (qube_rails/_question) to show on
    # the record's page. Your user's choice answers it, through the question routes: nothing here
    # picks one, and the run waits for as long as it takes. A newer event that isn't a question
    # forgets it.
    def question(event)
      prompt = event.prompt
      return unless prompt # answered already: this delivery was a retry

      links = event.links || {}
      run.question = prompt
      run.links = { "decisions" => links["decisions"], "search" => links["search"] }
    end

    # What an operation does with the rest of its run's events: each operation says, and until it
    # does, each logs. The engine has already kept every ending on the run (state, outcome, error,
    # cancel_reason, ended_at: the qube_rails/run_status partial shows it), so these are for your
    # own records: an invoice marked sent, a sync's last-finished time.
    def notification(event)
      log_event(event)
    end

    def ended(event)
      log_event(event)
    end

    def failed(event)
      log_event(event)
    end

    # How the input refers to one of your records in QuickBooks: { list_id: } when it's linked on
    # this run's connection (connection.qb_id_for), else { full_name: name }, or nil when there's
    # neither. Refer by id where you can: a name can match another record, or none after a
    # rename.
    #   customer_ref: quickbooks_ref(record.customer, kind: "customer", name: record.customer&.name)
    def quickbooks_ref(app_record, kind:, name: nil)
      list_id = app_record && connection.qb_id_for(app_record, kind: kind)
      return { list_id: list_id } if list_id
      return nil if name.nil? || name.to_s.empty?

      { full_name: name }
    end

    # Links each QuickBooks record an ending carries (event.output["references"], keyed by the
    # input's path: "customer_ref", "invoice_line_add.0.item_ref") to the record of yours your
    # block returns for it, on this run's connection, so the next run refers to it by id. The
    # block gets the path and the entry (kind, outcome and record: the record's own list as
    # "type", with list_id, edit_sequence and full_name) and returns your record, or nil to skip
    # it. An entry with no record (not found, or not reached before a cancel) is skipped. Works on
    # an added ending and on a cancelled one, which can carry some. Returns the rows linked.
    #   link_references(event) do |path, entry|
    #     record.customer if path == "customer_ref"
    #   end
    def link_references(event)
      output = event["output"]
      references = output.is_a?(Hash) ? output["references"] : nil
      return [] unless references.is_a?(Hash)

      references.each_with_object([]) do |(path, entry), linked|
        next unless entry.is_a?(Hash) && entry["record"].is_a?(Hash)

        found = entry["record"]
        next if found["list_id"].to_s.empty?

        app_record = yield(path, entry)
        next unless app_record

        kind = found["type"].to_s.empty? ? entry["kind"] : found["type"]
        linked << connection.link(app_record, kind: kind, qb_id: found["list_id"],
                                              edit_sequence: found["edit_sequence"], name: found["full_name"])
      end
    end

    # After your user's choice is in: the question is forgotten, unless the run has asked another
    # since (its token is the question's own).
    def answered(token)
      run.with_lock do
        question = run.open_question
        if question && question["token"] == token
          run.question = nil
          run.links = nil
          run.save!
        end
      end
    end

    private

    # Only a run's events and its notifications carry a reference: any other event posted to this
    # URL is skipped with the rest that aren't this run's.
    def apply(event)
      unless this_run?(event)
        QubeRails.logger.warn("QuBe Sync: #{self.class.name} run #{run.id} skipped #{event.event} for " \
                              "#{event.reference.inspect} on #{event["connection_id"].inspect}: not this run")
        return
      end

      if event.type == "notification"
        take_once(event.dedupe_key) { notification(event) } # its delivery_id
        return
      end
      return unless event.type == "workflow_run"
      # Applied already, or older than what was.
      return unless event.newer_than?(run.revision)

      # The run as of this event, before your handler runs, so every ending is on the run row
      # whatever the handler does: state, outcome, and a failure's error or a cancel's reason.
      run.state = event.run_state || run_state_for(event)
      run.outcome = event.outcome
      if ended?(event)
        run.ended_at ||= Time.now
        run.error = event.error if event.failed?
        run.cancel_reason = event.cancel_reason if event.cancelled?
      end

      if event.awaiting_input?
        question(event)
      elsif event.completed?
        QubeRails::SyncMark.advance(connection, self.class::WORKFLOW, run.created_at)
        ended(event)
      elsif stopped?(event)
        failed(event)
      end
      # A newer event that isn't a question: the one saved was answered, or the run ended.
      unless event.awaiting_input?
        run.question = nil
        run.links = nil
      end
      run.revision = event.revision
      run.save!
    end

    # The event names this run: its reference, on its connection.
    def this_run?(event)
      same_reference?(event) && on_this_connection?(event)
    end

    def same_reference?(event)
      !event.reference.nil? && event.reference == run.reference
    end

    def on_this_connection?(event)
      qube_id = run.connection.qube_id
      !qube_id.nil? && event["connection_id"] == qube_id
    end

    # The run is over: completed, failed or cancelled.
    def ended?(event)
      event.completed? || stopped?(event)
    end

    # The run ended without completing: failed or cancelled, which the failed handler takes.
    def stopped?(event)
      event.failed? || event.cancelled?
    end

    def run_state_for(event)
      if event.awaiting_input? then "awaiting_input"
      elsif event.completed? then "completed"
      elsif event.failed? then "failed"
      elsif event.cancelled? then "cancelled"
      else run.state
      end
    end

    # Runs the block once per delivery_id of this run, kept in the dedupe store (config.dedupe).
    # The default store writes its row inside this run's lock and transaction, so the row and the
    # handler's writes commit together, or neither does.
    def take_once(delivery_id)
      store = QubeRails.config.dedupe
      return store.once(run, delivery_id) { yield } if store.respond_to?(:once)

      key = "qube-sync/delivery/#{delivery_id}"
      return if store.seen?(key) # a retry of one already taken

      yield
      store.remember(key)
    end

    # The input without its nil values, at every depth: what a mapped operation's input sends, so
    # a field your record doesn't have yet is left out rather than sent as null.
    def without_nils(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner), kept|
          kept[key] = without_nils(inner) unless inner.nil?
        end
      when Array
        value.compact.map { |inner| without_nils(inner) }
      else
        value
      end
    end

    # All a handler does until you fill it in.
    def log_event(event)
      detail = event.dig("prompt", "id") || event["name"] || event["outcome"]
      line = "QuBe Sync: #{self.class.name} #{record.id} (run #{run.id}): #{event.event} #{detail} " \
             "(#{event.reference})"
      if event.type == "workflow_run" && stopped?(event)
        QubeRails.logger.warn(line)
      else
        QubeRails.logger.info(line)
      end
    end
  end
end
