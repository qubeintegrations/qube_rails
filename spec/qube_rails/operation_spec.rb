# frozen_string_literal: true

RSpec.describe QubeRails::Operation do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:run) { make_run(invoice, connection) }

  def run_event(name, changes = {}, target = run)
    QubeRails::WebhookJob.new.perform("run", target.id.to_s, run_body(name, target, changes))
    target.reload
  end

  describe "the job" do
    it "hands a completed run to ended with the record, the run and its connection" do
      run_event("workflow_run.completed", "revision" => 4)

      expect(QuickbooksDesktop::CreateInvoice.calls).to eq([[:ended, "used_existing", run.id, connection.id]])
      expect(invoice.reload.status).to eq("sent")
      expect(run).to have_attributes(revision: 4, state: "completed", outcome: "used_existing")
    end

    it "hands a failed or cancelled run to failed" do
      run_event("workflow_run.failed", "revision" => 2)
      run_event("workflow_run.cancelled", "revision" => 3)

      expect(QuickbooksDesktop::CreateInvoice.calls)
        .to eq([[:failed, "workflow_run.failed"], [:failed, "workflow_run.cancelled"]])
      expect(run.state).to eq("cancelled")
    end

    it "skips an event whose reference isn't the run's" do
      run_event("workflow_run.completed", "reference" => "create_invoice-1-earlier", "revision" => 9)

      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
      expect(run.revision).to eq(0)
      expect(log_output).to include("skipped workflow_run.completed for \"create_invoice-1-earlier\"", "not this run")
    end

    it "skips an event whose connection_id isn't the run's connection's" do
      run_event("workflow_run.completed", "connection_id" => "someone-elses", "revision" => 9)

      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
      expect(run.revision).to eq(0)
      expect(log_output).to include("on \"someone-elses\": not this run")
    end

    it "skips an event with no reference at all" do
      run_event("connection.connected", "reference" => nil)

      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
    end

    it "applies an event only when it's newer than the last applied" do
      run_event("workflow_run.failed", "revision" => 5)
      run_event("workflow_run.completed", "revision" => 3) # an older one, late
      run_event("workflow_run.failed", "revision" => 5) # a retry

      expect(QuickbooksDesktop::CreateInvoice.calls).to eq([[:failed, "workflow_run.failed"]])
      expect(run.revision).to eq(5)
    end

    it "takes a notification once by its delivery_id, whatever its revision" do
      run_event("workflow_run.notification", "revision" => 2)
      run_event("workflow_run.notification", "revision" => 2) # a retry
      run_event("workflow_run.notification", "revision" => 1, "delivery_id" => "d-2")

      expect(QuickbooksDesktop::CreateInvoice.calls)
        .to eq([[:notification, "0196a1c0-0000-7000-8000-00000000d001"], [:notification, "d-2"]])
      expect(run.revision).to eq(0)
    end

    it "uses the dedupe setting" do
      store = Class.new do
        attr_reader :keys

        def initialize
          @keys = []
        end

        def seen?(key)
          @keys.include?(key)
        end

        def remember(key)
          @keys << key
        end
      end.new
      QubeRails.config.dedupe = store
      run_event("workflow_run.notification")

      expect(store.keys).to eq(["qube-sync/delivery/0196a1c0-0000-7000-8000-00000000d001"])
    end

    it "keeps a question on the run with its links, and a newer event that isn't one forgets it" do
      run_event("workflow_run.awaiting_input", "revision" => 6)

      expect(run.question).to include("token", "choices", "message")
      expect(run.links.keys).to eq(%w[decisions search])
      expect(run).to have_attributes(revision: 6, state: "awaiting_input")

      run_event("workflow_run.completed", "revision" => 7)

      expect(run.question).to be_nil
      expect(run.links).to be_nil
    end

    it "leaves the question alone for an awaiting_input retry with no prompt" do
      run_event("workflow_run.awaiting_input", "revision" => 6)
      run_event("workflow_run.awaiting_input", "revision" => 7, "prompt" => nil)

      expect(run.question).not_to be_nil
    end

    it "keeps nothing on the app's record" do
      expect(Invoice.column_names).to eq(%w[id account_id number status])
    end

    it "finds the record by the run's record_type when the operation has no find_record" do
      customer = Customer.create!(account: account, name: "Riverbend Electric")
      sync = make_run(customer, connection, operation: "sync_customer")
      run_event("workflow_run.completed", { "revision" => 1 }, sync)

      expect(QuickbooksDesktop::SyncCustomer.calls).to eq([[:ended, customer]])
    end

    it "drops a delivery whose record was deleted, with a warning, rather than raising for ever" do
      run
      invoice.destroy!

      expect { QubeRails::WebhookJob.perform_now("run", run.id.to_s, run_body("workflow_run.completed", run)) }
        .not_to raise_error
      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
      expect(log_output).to include("WARN QuBe Sync: dropped workflow_run.completed: run #{run.id}'s Invoice " \
                                    "#{invoice.id} isn't there")
    end

    it "drops one whose find_record raises RecordNotFound" do
      allow(QuickbooksDesktop::CreateInvoice).to receive(:find_record).and_raise(ActiveRecord::RecordNotFound)

      expect { run_event("workflow_run.completed") }.not_to raise_error
      expect(log_output).to include("dropped workflow_run.completed")
    end

    it "drops a delivery for a run or connection deleted since, and raises for an operation taken out" do
      expect { QubeRails.run("run", "0", vector_body("workflow_run.completed")) }.not_to raise_error
      expect { QubeRails.run("connection", "0", vector_body("connection.connected")) }.not_to raise_error
      expect(log_output).to include("run 0 isn't there", "connection 0 isn't there")

      QubeRails.config.operations = { "sync_customer" => "QuickbooksDesktop::SyncCustomer" }
      expect { QubeRails.run("run", run.id.to_s, run_body("workflow_run.completed", run)) }
        .to raise_error(QubeRails::UnknownOperation)
    end
  end

  describe ".start" do
    it "writes the run first, starts it on the connection's qube_id, and keeps QuBe Sync's answer" do
      stub = stub_request(:post, api_url("/connections/#{connection.qube_id}/workflow-runs"))
             .to_return(json_data("id" => "run-q-1", "state" => "running",
                                  "links" => { "run" => "https://qube.example/r/1", "cancel" => "https://qube.example/r/1/cancel" }))

      started = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(started).to be_a(QubeRails::Run)
      expect(started.reload).to have_attributes(
        operation: "create_invoice", record: invoice, connection: connection, qube_run_id: "run-q-1",
        state: "running", run_url: "https://qube.example/r/1", cancel_url: "https://qube.example/r/1/cancel"
      )
      expect(started.reference).to match(/\Acreate_invoice-#{invoice.id}-\h{8}-/)
      expect(stub.with { |req|
        sent = JSON.parse(req.body)
        req.headers["Idempotency-Key"] == started.reference &&
          sent["workflow"] == "add_transaction" &&
          sent["reference"] == started.reference &&
          sent["input"] == { "operation" => "invoice.create", "params" => { "ref_number" => "1001" } } &&
          sent["webhook_url"] == "https://app.example/webhooks/qube/runs/#{started.id}"
      }).to have_been_requested
    end

    it "keeps a state a webhook wrote before the answer came back" do
      stub_request(:post, /workflow-runs/).to_return do
        QubeRails::Run.last.update_columns(state: "awaiting_input", revision: 2)
        json_data("id" => "run-q-1", "state" => "running")
      end

      started = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(started.reload).to have_attributes(state: "awaiting_input", qube_run_id: "run-q-1")
    end

    it "refuses a second start while the record's run hasn't ended, and allows one after" do
      stub_request(:post, /workflow-runs/).to_return(json_data("id" => "run-q-1", "state" => "running"))
      first = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::AlreadyRunning, /Invoice #{invoice.id} already has a create_invoice run .*run #{first.id}, running/)
      expect(QubeRails::Run.count).to eq(1)
      expect(a_request(:post, /workflow-runs/)).to have_been_made.once

      first.update!(state: "completed", outcome: "added")
      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection)).to be_a(QubeRails::Run)
      expect(QubeRails::Run.count).to eq(2)
    end

    it "points an unconfirmed start at retry_start!" do
      make_run(invoice, connection).update!(state: "starting")

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::AlreadyRunning, /retry_start!/)
    end

    it "lets the same record start on another connection" do
      make_run(invoice, connection)
      other = make_connection(account, qube_id: "conn-q-other")
      stub_request(:post, api_url("/connections/conn-q-other/workflow-runs"))
        .to_return(json_data("id" => "run-q-2", "state" => "running"))

      expect(QuickbooksDesktop::CreateInvoice.start(invoice, other).connection).to eq(other)
    end

    it "refuses a connection QuBe Sync hasn't made yet" do
      pending_connection = make_connection(account, qube_id: nil, status: "pending")

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, pending_connection) }
        .to raise_error(QubeRails::NotConnected, /qube_id/)
      expect(QubeRails::Run.count).to eq(0)
    end

    it "marks the run failed and raises again when QuBe Sync refuses the start (a 4xx)" do
      stub_request(:post, /workflow-runs/).to_return(status: 422, body: { errors: { detail: "bad input" } }.to_json)

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(QubeSync::APIError)
      expect(QubeRails::Run.last).to have_attributes(state: "failed", qube_run_id: nil)
    end

    it "marks the run failed when its input raises, before anything is sent" do
      allow_any_instance_of(QuickbooksDesktop::CreateInvoice).to receive(:input).and_raise(NotImplementedError)

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(NotImplementedError)
      expect(QubeRails::Run.last.state).to eq("failed")
      expect(a_request(:post, /workflow-runs/)).not_to have_been_made
    end

    it "leaves the run starting, with its reference and input, when the start gets no answer" do
      stub_request(:post, /workflow-runs/).to_timeout

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(Net::OpenTimeout)
      expect(QubeRails::Run.last).to have_attributes(
        state: "starting", qube_run_id: nil, input: { "operation" => "invoice.create", "params" => { "ref_number" => "1001" } }
      )
    end

    it "leaves the run starting on a 5xx" do
      stub_request(:post, /workflow-runs/).to_return(status: 500, body: "")

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(QubeSync::APIError)
      expect(QubeRails::Run.last.state).to eq("starting")
    end
  end

  describe "#retry_start!" do
    it "resends the same reference (as the Idempotency-Key), workflow, input and webhook URL" do
      stub_request(:post, /workflow-runs/).to_timeout
      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(Net::OpenTimeout)
      started = QubeRails::Run.last
      invoice.update!(number: "changed since") # the input it resends is the first one's

      WebMock.reset!
      replayed = stub_request(:post, api_url("/connections/#{connection.qube_id}/workflow-runs"))
                 .to_return(json_data("id" => "run-q-1", "state" => "running").merge(
                   headers: { "Content-Type" => "application/json", "Idempotent-Replayed" => "true" }
                 ))

      expect(started.retry_start!).to eq(started)
      expect(replayed.with { |req|
        sent = JSON.parse(req.body)
        req.headers["Idempotency-Key"] == started.reference && sent["reference"] == started.reference &&
          sent["workflow"] == "add_transaction" && sent["webhook_url"] == started.webhook_url &&
          sent["input"] == { "operation" => "invoice.create", "params" => { "ref_number" => "1001" } }
      }).to have_been_requested
      expect(started.reload).to have_attributes(qube_run_id: "run-q-1", state: "running")
    end

    it "returns a run already answered as it is, and refuses one that failed" do
      answered = make_run(invoice, connection).tap { |r| r.update!(qube_run_id: "run-q-9") }
      expect(answered.retry_start!).to eq(answered)

      failed = make_run(invoice, connection).tap { |r| r.update!(state: "failed") }
      expect { failed.retry_start! }.to raise_error(ArgumentError, /only a start that got no answer/)
    end
  end

  describe "#answered" do
    it "forgets the question only when its token is the one answered" do
      run.update!(question: { "token" => "t-1" }, links: { "decisions" => "x" })
      operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)

      operation.answered("t-0")
      expect(run.reload.question).to eq("token" => "t-1")

      operation.answered("t-1")
      expect(run.reload.question).to be_nil
    end
  end

  describe "#quickbooks_ref" do
    let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }
    let(:operation) { QuickbooksDesktop::CreateInvoice.new(invoice, run) }

    it "refers by ListID when the record is linked on the run's connection, else by name, else nil" do
      expect(operation.quickbooks_ref(customer, kind: "customer", name: "Riverbend Electric"))
        .to eq(full_name: "Riverbend Electric")
      expect(operation.quickbooks_ref(nil, kind: "customer", name: nil)).to be_nil

      connection.link(customer, kind: "customer", qb_id: "80000001-1")
      expect(operation.quickbooks_ref(customer, kind: "customer", name: "Riverbend Electric")).to eq(list_id: "80000001-1")
    end

    it "never uses another connection's link" do
      make_connection(account, qube_id: "conn-q-2").link(customer, kind: "customer", qb_id: "80000001-1")

      expect(operation.quickbooks_ref(customer, kind: "customer", name: "R")).to eq(full_name: "R")
    end
  end

  describe "#link_references" do
    let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }
    let(:widget) { Customer.create!(account: account, name: "Widget (an item, here)") }
    let(:references) do
      {
        "customer_ref" => { "kind" => "customer", "outcome" => "found",
                            "record" => { "type" => "customer", "list_id" => "80000001-1", "edit_sequence" => "17",
                                          "full_name" => "Riverbend Electric" } },
        "invoice_line_add.0.item_ref" => { "kind" => "item", "outcome" => "created",
                                           "record" => { "type" => "item_service", "list_id" => "80000002-1",
                                                         "full_name" => "Widget" } },
        "invoice_line_add.1.item_ref" => { "kind" => "item", "outcome" => "not_found", "record" => nil },
        "class_ref" => { "kind" => "class", "outcome" => "found", "record" => { "list_id" => "80000003-1" } }
      }
    end

    def event_with(name, output)
      QubeRails::Backend.parse(run_body(name, run, "output" => output))
    end

    it "links each reference's record to the app record the block returns, by the record's own type" do
      operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)
      seen = []
      linked = operation.link_references(event_with("workflow_run.completed", "references" => references)) do |path, entry|
        seen << [path, entry["outcome"]]
        { "customer_ref" => customer, "invoice_line_add.0.item_ref" => widget, "class_ref" => invoice }[path]
      end

      expect(seen).to eq([["customer_ref", "found"], ["invoice_line_add.0.item_ref", "created"], ["class_ref", "found"]])
      expect(linked.size).to eq(3)
      expect(connection.quickbooks_record("80000001-1", kind: "customer"))
        .to have_attributes(record: customer, edit_sequence: "17", name: "Riverbend Electric")
      expect(connection.quickbooks_record("80000002-1", kind: "item")).to have_attributes(kind: "item_service", record: widget)
      expect(connection.quickbooks_record("80000003-1", kind: "class")).to have_attributes(kind: "class", record: invoice)
    end

    it "skips what the block returns nil for, and works on a cancelled ending" do
      operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)
      cancelled = event_with("workflow_run.cancelled", "references" => references.slice("customer_ref"), "record" => nil)

      expect(operation.link_references(cancelled) { |_path, _entry| customer }.size).to eq(1)
      expect(operation.link_references(cancelled) { |_path, _entry| nil }).to eq([])
      expect(operation.link_references(event_with("workflow_run.completed", nil)) { customer }).to eq([])
    end
  end

  describe "#without_nils" do
    it "drops nil values at every depth, for a mapped operation's input" do
      operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)
      input = { a: 1, b: nil, c: { d: nil, e: [1, nil, { f: nil, g: false }] } }

      expect(operation.send(:without_nils, input)).to eq(a: 1, c: { e: [1, { g: false }] })
    end
  end

  describe "the base handlers" do
    it "log until an operation fills them in" do
      plain = Class.new(described_class) do
        const_set(:SLUG, "plain")
        def self.name
          "Plain"
        end
      end
      event = QubeRails::Backend.parse(vector_body("workflow_run.failed", "reference" => "r-1"))
      plain.new(invoice, run).failed(event)

      expect(log_output).to match(/WARN.*QuBe Sync: Plain #{invoice.id} \(run #{run.id}\): workflow_run.failed renames_exhausted \(r-1\)/)
      expect { plain.find_record(1) }.to raise_error(NotImplementedError, /record_type/)
      expect { plain.new(invoice, run).input }.to raise_error(NotImplementedError)
    end
  end
end
