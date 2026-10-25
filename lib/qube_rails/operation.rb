# frozen_string_literal: true

require "erb"
require "securerandom"

module QubeRails
  # One way your app starts a workflow, and what it does with that run's webhooks: subclass it
  # once per operation, in app/services/quickbooks_desktop/, and list it in config.operations by
  # its SLUG. Each run's webhook URL names the operation and your record
  # (QUBE_WEBHOOK_URL/<slug>/<record id>), so the webhook job hands each event back to the same
  # class, with the record found again.
  #
  #   module QuickbooksDesktop
  #     class CreateInvoice < QubeRails::Operation
  #       WORKFLOW = "add_transaction"
  #       SLUG = "create_invoice"
  #
  #       def self.find_record(id)
  #         Invoice.find(id)
  #       end
  #
  #       def input
  #         { operation: "invoice.create", params: { ref_number: record.number } }
  #       end
  #
  #       def ended(event)
  #         record.update!(txn_id: event.dig("output", "record", "txn_id"))
  #       end
  #     end
  #   end
  #
  # The run's reference and the last revision applied are kept on the record, in qube_reference
  # (a string) and qube_revision (an integer) columns, and a question the run asks, with its
  # links, in qube_question and qube_links (json) columns. A migration for invoices, say:
  #   add_column :invoices, :qube_reference, :string
  #   add_column :invoices, :qube_revision, :integer
  #   add_column :invoices, :qube_question, :json
  #   add_column :invoices, :qube_links, :json
  # A record whose workflow asks nothing (a sync's) needs only the first two. Override
  # saved_reference, save_reference, saved_revision and save_revision, or saved_question,
  # saved_links and save_question, to keep them elsewhere.
  class Operation
    # Starts the operation's run for record, one your app has saved, on the customer's connection
    # (the connection id onboarding saved on their account), and returns the run as it stands.
    # The reference is new for every run (<slug>-<record id>-<uuid>) and saved on the record
    # before the run starts, since a webhook can arrive before this returns.
    def self.start(record, connection_id)
      operation = new(record)
      reference = "#{self::SLUG}-#{record.id}-#{SecureRandom.uuid}"
      operation.save_reference(reference)
      QubeRails.client.start_run(connection_id, self::WORKFLOW, operation.input,
                                 reference: reference, webhook_url: operation.webhook_url)
    end

    # Your record, by the id in its webhook URL. Each operation says how.
    def self.find_record(id)
      raise NotImplementedError, "#{name}.find_record(#{id.inspect}) isn't written yet"
    end

    attr_reader :record

    def initialize(record)
      @record = record
    end

    # Where this run's webhooks go: QUBE_WEBHOOK_URL, then the operation and the record's id.
    def webhook_url
      "#{QubeRails.config.webhook_url}/#{self.class::SLUG}/#{ERB::Util.url_encode(record.id.to_s)}"
    end

    # The run's input, from the record. Each operation says how.
    def input
      raise NotImplementedError, "#{self.class.name}#input isn't written yet"
    end

    # One of the run's webhooks, from the webhook job, as the qube_sync gem parsed it: a
    # WorkflowRunEvent or a NotificationEvent. Deliveries come at least once and, from a queue
    # with more than one worker, in any order:
    # - an event whose reference isn't the one saved on the record isn't this record's run (an
    #   earlier run's, or a signed body posted to another record's URL): it's logged and skipped;
    # - a notification is taken once, by its delivery_id (the dedupe setting);
    # - any other event is applied only when its revision is newer than the last one applied.
    # It holds the record's row lock while it does (with_lock, which reads the record again), so
    # two workers never apply one record's events at once, and what a handler writes is saved
    # with the revision or not at all.
    def handle(event)
      record.with_lock { apply(event) }
    end

    # A question the run asks: saved whole on the record, with its links (where to answer it,
    # and where a record field searches), for the question partial (qube_rails/_question) to
    # show on the record's page. Your user's choice answers it, through the question routes:
    # nothing here picks one, and the run waits for as long as it takes. A newer event that
    # isn't a question forgets it.
    def question(event)
      prompt = event.prompt
      return unless prompt # answered already: this delivery was a retry

      links = event.links || {}
      save_question(prompt, { "decisions" => links["decisions"], "search" => links["search"] })
    end

    # What an operation does with the rest of its run's events: each operation says, and until
    # it does, each logs.
    def notification(event)
      log_event(event)
    end

    def ended(event)
      log_event(event)
    end

    def failed(event)
      log_event(event)
    end

    def saved_reference
      record.qube_reference
    end

    # Saves a new run's reference and forgets the last run's revision, since each run's
    # revisions start again at 1, and any question it was asking.
    def save_reference(reference)
      record.update_columns(qube_reference: reference, qube_revision: 0)
      save_question(nil, nil) if saved_question
    end

    def saved_revision
      record.qube_revision
    end

    def save_revision(revision)
      record.update_columns(qube_revision: revision)
    end

    # The question the run is asking, as its webhook's prompt had it, or nil. A record with no
    # qube_question column has none.
    def saved_question
      record.qube_question if record.respond_to?(:qube_question)
    end

    # Its links: "decisions" and, for a record field, "search".
    def saved_links
      record.qube_links if record.respond_to?(:qube_links)
    end

    def save_question(prompt, links)
      record.update_columns(qube_question: prompt, qube_links: links)
    end

    # After your user's choice is in: the question is forgotten, unless the run has asked another
    # since (its token is the question's own).
    def answered(token)
      record.with_lock do
        question = saved_question
        save_question(nil, nil) if question && question["token"] == token
      end
    end

    private

    # Only a run's events and its notifications carry a reference: any other event posted to
    # this URL is skipped with the rest that aren't this record's run.
    def apply(event)
      unless event.reference && event.reference == saved_reference
        QubeRails.logger.warn("QuBe Sync: #{self.class.name} #{record.id} skipped " \
                              "#{event.event} for #{event.reference.inspect}: not its run")
        return
      end

      if event.type == "notification"
        take_once(event.dedupe_key) { notification(event) } # its delivery_id
        return
      end

      # Applied already, or older than what was.
      return unless event.newer_than?(saved_revision)

      if event.awaiting_input?
        question(event)
      elsif event.completed?
        ended(event)
      elsif event.failed? || event.cancelled?
        failed(event)
      end
      # A newer event that isn't a question: the one saved was answered, or the run ended.
      save_question(nil, nil) if !event.awaiting_input? && saved_question
      save_revision(event.revision)
    end

    # Runs the block once per delivery_id, kept in the dedupe store (config.dedupe).
    def take_once(delivery_id)
      key = "qube-sync/delivery/#{delivery_id}"
      store = QubeRails.config.dedupe
      return if store.seen?(key) # a retry of one already taken

      yield
      store.remember(key)
    end

    # The input without its nil values, at every depth: what a mapped operation's input sends,
    # so a field your record doesn't have yet is left out rather than sent as null.
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
      line = "QuBe Sync: #{self.class.name} #{record.id}: #{event.event} #{detail} " \
             "(#{event.reference})"
      if event.type == "workflow_run" && (event.failed? || event.cancelled?)
        QubeRails.logger.warn(line)
      else
        QubeRails.logger.info(line)
      end
    end
  end
end
