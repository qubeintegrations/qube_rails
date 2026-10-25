# frozen_string_literal: true

RSpec.describe QubeRails::Operation do
  let(:account) { Account.create!(name: "Riverbend", qube_connection_id: "conn-1") }
  let(:invoice) do
    Invoice.create!(account: account, number: "1001", qube_reference: "create_invoice-1-ref", qube_revision: 0)
  end

  def run_event(name, changes = {})
    body = vector_body(name, { "reference" => "create_invoice-1-ref" }.merge(changes))
    QubeRails::WebhookJob.perform_now("create_invoice", invoice.id.to_s, body)
    invoice.reload
  end

  describe "the job" do
    it "hands a completed run to ended, and saves its revision" do
      run_event("workflow_run.completed", "revision" => 4, "output" => { "record" => { "txn_id" => "T-9" } })

      expect(QuickbooksDesktop::CreateInvoice.calls).to eq([[:ended, "used_existing"]])
      expect(invoice.status).to eq("sent")
      expect(invoice.txn_id).to eq("T-9")
      expect(invoice.qube_revision).to eq(4)
    end

    it "hands a failed or cancelled run to failed" do
      run_event("workflow_run.failed", "revision" => 2)
      run_event("workflow_run.cancelled", "revision" => 3)

      expect(QuickbooksDesktop::CreateInvoice.calls)
        .to eq([[:failed, "workflow_run.failed"], [:failed, "workflow_run.cancelled"]])
      expect(invoice.status).to eq("failed")
    end

    it "skips an event whose reference isn't the one saved on the record" do
      run_event("workflow_run.completed", "reference" => "create_invoice-1-earlier", "revision" => 9)

      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
      expect(invoice.qube_revision).to eq(0)
      expect(log_output).to include("skipped workflow_run.completed for \"create_invoice-1-earlier\": not its run")
    end

    it "skips an event with no reference at all" do
      run_event("connection.connected", "reference" => nil)

      expect(QuickbooksDesktop::CreateInvoice.calls).to be_empty
      expect(log_output).to include("not its run")
    end

    it "applies an event only when it's newer than the last applied" do
      run_event("workflow_run.failed", "revision" => 5)
      run_event("workflow_run.completed", "revision" => 3) # an older one, late
      run_event("workflow_run.failed", "revision" => 5) # a retry

      expect(QuickbooksDesktop::CreateInvoice.calls).to eq([[:failed, "workflow_run.failed"]])
      expect(invoice.qube_revision).to eq(5)
    end

    it "takes a notification once by its delivery_id, whatever its revision" do
      run_event("workflow_run.notification", "revision" => 2)
      run_event("workflow_run.notification", "revision" => 2) # a retry
      run_event("workflow_run.notification", "revision" => 1, "delivery_id" => "d-2")

      expect(QuickbooksDesktop::CreateInvoice.calls)
        .to eq([[:notification, "0196a1c0-0000-7000-8000-00000000d001"], [:notification, "d-2"]])
      expect(invoice.qube_revision).to eq(0)
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

    it "saves a question with its links, and a newer event that isn't one forgets it" do
      run_event("workflow_run.awaiting_input", "revision" => 6)

      expect(invoice.qube_question).to include("token", "choices", "message")
      expect(invoice.qube_links.keys).to eq(%w[decisions search])
      expect(invoice.qube_links["decisions"]).to include("/decisions")
      expect(invoice.qube_revision).to eq(6)

      run_event("workflow_run.completed", "revision" => 7)

      expect(invoice.qube_question).to be_nil
      expect(invoice.qube_links).to be_nil
    end

    it "leaves the question alone for an awaiting_input retry with no prompt" do
      run_event("workflow_run.awaiting_input", "revision" => 6)
      run_event("workflow_run.awaiting_input", "revision" => 7, "prompt" => nil)

      expect(invoice.qube_question).not_to be_nil
    end

    it "raises when find_record finds nothing, so the queue retries" do
      allow(QuickbooksDesktop::CreateInvoice).to receive(:find_record).and_return(nil)

      expect { QubeRails::WebhookJob.perform_now("create_invoice", "9", vector_body("workflow_run.completed")) }
        .to raise_error(QubeRails::RecordMissing, /find_record\("9"\) found nothing/)
    end

    it "raises for a slug no operation has" do
      expect { QubeRails.run("gone", "1", vector_body("workflow_run.completed")) }
        .to raise_error(QubeRails::UnknownOperation)
    end
  end

  describe ".start" do
    it "saves a new reference, forgets the last run's revision and question, and starts the run" do
      invoice.update_columns(qube_revision: 9, qube_question: { "token" => "old" }, qube_links: {})
      stub = stub_request(:post, api_url("/connections/conn-1/workflow-runs"))
             .to_return(json_data("id" => "run-1", "state" => "running"))

      run = QuickbooksDesktop::CreateInvoice.start(invoice, "conn-1")
      invoice.reload

      expect(run).to eq("id" => "run-1", "state" => "running")
      expect(invoice.qube_reference).to match(/\Acreate_invoice-#{invoice.id}-\h{8}-/)
      expect(invoice.qube_revision).to eq(0)
      expect(invoice.qube_question).to be_nil
      expect(stub.with { |req|
        sent = JSON.parse(req.body)
        req.headers["Idempotency-Key"] == invoice.qube_reference &&
          sent["workflow"] == "add_transaction" &&
          sent["reference"] == invoice.qube_reference &&
          sent["input"] == { "operation" => "invoice.create", "params" => { "ref_number" => "1001" } } &&
          sent["webhook_url"] == "https://app.example/webhooks/qube/create_invoice/#{invoice.id}"
      }).to have_been_requested
    end
  end

  describe "#answered" do
    it "forgets the question only when its token is the one answered" do
      invoice.update_columns(qube_question: { "token" => "t-1" }, qube_links: { "decisions" => "x" })
      operation = QuickbooksDesktop::CreateInvoice.new(invoice)

      operation.answered("t-0")
      expect(invoice.reload.qube_question).to eq("token" => "t-1")

      operation.answered("t-1")
      expect(invoice.reload.qube_question).to be_nil
    end
  end

  describe "#without_nils" do
    it "drops nil values at every depth, for a mapped operation's input" do
      operation = QuickbooksDesktop::CreateInvoice.new(invoice)
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
      plain.new(invoice).failed(event)

      expect(log_output).to match(/WARN.*QuBe Sync: Plain #{invoice.id}: workflow_run.failed renames_exhausted \(r-1\)/)
      expect { plain.find_record(1) }.to raise_error(NotImplementedError, /Plain.find_record\(1\) isn't written yet/)
      expect { plain.new(invoice).input }.to raise_error(NotImplementedError)
    end
  end
end
