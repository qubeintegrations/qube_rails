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
    # returns. A start that raises (QuBe Sync refused it, or didn't answer) marks the row
    # "failed" and raises again; starting again makes a new run.
    def self.start(record, connection)
      unless connection.is_a?(QubeRails::Connection) && !connection.qube_id.to_s.empty?
        raise NotConnected, "QuBe Sync: #{name}.start needs a connection QuBe Sync has made (one with a " \
                            "qube_id): the customer finishes onboarding first"
      end

      run = QubeRails::Run.create!(
        connection: connection, operation: self::SLUG, record: record,
        reference: "#{self::SLUG}-#{record.id}-#{SecureRandom.uuid}", state: "starting", revision: 0
      )
      begin
        started = QubeRails.client.start_run(connection.qube_id, self::WORKFLOW, new(record, run).input,
                                             reference: run.reference, webhook_url: run.webhook_url)
      rescue StandardError, NotImplementedError # an input not written yet, too
        run.update_columns(state: "failed", updated_at: Time.now)
        raise
      end
      record_start(run, started.is_a?(Hash) ? started : {})
      run
    end

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

    # The run's input, from the record. Each operation says how.
    def input
      raise NotImplementedError, "#{self.class.name}#input isn't written yet"
    end

    # One of the run's webhooks, from the webhook job, as the qube_sync gem parsed it: a
    # WorkflowRunEvent or a NotificationEvent. Deliveries come at least once and, from a queue
    # with more than one worker, in any order:
    # - an event whose reference isn't the run's, or whose connection_id isn't its connection's
    #   qube_id (a signed body posted to another run's URL), is logged and skipped;
    # - a notification is taken once, by its delivery_id (the dedupe setting);
    # - any other event is applied only when its revision is newer than the last one applied.
    # It holds the run row's lock while it does (with_lock, which reads it again), so two workers
    # never apply one run's events at once, and what a handler writes is saved with the revision
    # or not at all.
    def handle(event)
      run.with_lock { apply(event) }
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
    # does, each logs.
    def notification(event)
      log_event(event)
    end

    def ended(event)
      log_event(event)
    end

    def failed(event)
      log_event(event)
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
      qube_id = run.connection.qube_id
      unless event.reference && event.reference == run.reference && qube_id && event["connection_id"] == qube_id
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

      if event.awaiting_input?
        question(event)
      elsif event.completed?
        ended(event)
      elsif event.failed? || event.cancelled?
        failed(event)
      end
      # A newer event that isn't a question: the one saved was answered, or the run ended.
      unless event.awaiting_input?
        run.question = nil
        run.links = nil
      end
      run.state = event.run_state if event.run_state
      run.outcome = event.outcome
      run.revision = event.revision
      run.save!
    end

    # Runs the block once per delivery_id, kept in the dedupe store (config.dedupe).
    def take_once(delivery_id)
      key = "qube-sync/delivery/#{delivery_id}"
      store = QubeRails.config.dedupe
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
      if event.type == "workflow_run" && (event.failed? || event.cancelled?)
        QubeRails.logger.warn(line)
      else
        QubeRails.logger.info(line)
      end
    end
  end
end
