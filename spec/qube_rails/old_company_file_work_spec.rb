# frozen_string_literal: true

# Work from before a connection switched company file (company_file_changed_at) is the old file's:
# its late events keep no links and no sync mark, and a start or a queue doesn't reuse it.
RSpec.describe "Work from before a company file change" do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }
  let(:realtime) { { "connection" => { "id" => QubeRailsHelpers::QUBE_ID, "type" => "realtime" } } }

  def connection_event(name, changes = {})
    QubeRails::WebhookJob.new.perform("connection", connection.id.to_s, vector_body(name, realtime.merge(changes)))
    connection.reload
  end

  def switch_file
    travel(1.second)
    connection_event("connection.company_file_changed", "revision" => 5)
    connection_event("connection.connected", "revision" => 6)
  end

  after { travel_back }

  describe "a late run event" do
    let(:run) { make_run(invoice, connection) }
    let(:completed) do
      run_body("workflow_run.completed", run, "revision" => 4, "workflow" => "add_transaction",
                                              "output" => { "record" => { "txn_id" => "T-OLD", "ref_number" => "1001" } })
    end

    it "keeps the run's ending, but no sync mark and no link, and says so" do
      run
      switch_file

      QubeRails::WebhookJob.new.perform("run", run.id.to_s, completed)

      expect(run.reload).to have_attributes(state: "completed", revision: 4)
      expect(invoice.reload.status).to eq("sent") # the handler still ran
      expect(QubeRails::SyncMark.where(connection_id: connection.id)).to be_empty
      expect(connection.last_synced_at("add_transaction")).to be_nil
      expect(connection.quickbooks_records.where(qb_id: "T-OLD")).to be_empty
      expect(log_output).to include("was started before its connection's company file changed")
    end

    it "leaves a stale link stale rather than making the old file's id current" do
      connection.link(invoice, kind: "invoice", qb_id: "T-OLD", name: "1001")
      run
      travel(1.second)
      connection_event("connection.company_file_changed", "revision" => 5) # stays pending: no check yet

      QubeRails::WebhookJob.new.perform("run", run.id.to_s, completed)

      expect(connection.stale_links.where(qb_id: "T-OLD").count).to eq(1)
      expect(connection.qb_id_for(invoice, kind: "invoice")).to be_nil
    end

    it "links nothing through link_references either" do
      run
      switch_file
      operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)
      event = QubeRails::Backend.parse(run_body("workflow_run.completed", run, "output" => {
                                                  "refs" => { "customer_ref" => { "list_id" => "80-OLD", "type" => "customer" } }
                                                }))

      linked = connection.holding_links("test") { operation.link_references(event) { customer } }

      expect(linked).to eq([])
      expect(connection.quickbooks_records.where(qb_id: "80-OLD")).to be_empty
    end

    it "advances the mark and links as before for a run started on the new file" do
      switch_file
      run
      QubeRails::WebhookJob.new.perform("run", run.id.to_s, completed)

      expect(connection.last_synced_at("add_transaction")).to be_within(1.second).of(run.created_at)
      expect(connection.qb_id_for(invoice, kind: "invoice")).to eq("T-OLD")
    end
  end

  describe "a late request answer" do
    it "runs the handler with links held" do
      row = QubeRails::QueuedRequest.create!(connection: connection, operation: "find_customer", record: customer,
                                             reference: "find_customer-1-x", state: "queued", qube_id: "req-q-1")
      switch_file
      linker = Class.new(QuickbooksDesktop::FindCustomer) do
        def answered(_event)
          self.class.linked << connection.link(record, kind: "customer", qb_id: "80-OLD")
        end

        def self.linked
          @linked ||= []
        end
      end
      body = vector_body("request: an answer", "id" => "req-q-1")

      linker.new(customer, row).handle(QubeRails::Backend.parse(body))

      expect(linker.linked).to eq([nil])
      expect(connection.quickbooks_records.where(qb_id: "80-OLD")).to be_empty
    end
  end

  describe "a start that QuBe Sync never confirmed" do
    it "is cancelled, not sent again with the old file's ids, and a new run goes" do
      old = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
      switch_file
      started = stub_request(:post, /workflow-runs/).to_return(json_data("id" => "run-q-new", "state" => "running"))

      run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(run.id).not_to eq(old.id)
      expect(run).to have_attributes(reused?: false, qube_run_id: "run-q-new")
      expect(started).to have_been_made.once
      expect(a_request(:post, /workflow-runs/).with { |req| JSON.parse(req.body)["reference"] == old.reference })
        .not_to have_been_made
      expect(old.reload).to have_attributes(state: "cancelled", cancel_reason: QubeRails.t("status.company_file_changed"))
      expect(old.ended_at).not_to be_nil
    end

    it "is the same for one refused as realtime_required, and for a confirmed run still going" do
      other = Invoice.create!(account: account, number: "1002")
      waiting = make_run(invoice, connection).tap { |r| r.update!(state: "realtime_required") }
      going = make_run(other, connection).tap { |r| r.update!(qube_run_id: "run-q-old") }
      switch_file
      stub_request(:post, /workflow-runs/).to_return(json_data("id" => "run-q-new", "state" => "running"))

      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection).id).not_to eq(waiting.id)
      expect(QuickbooksDesktop::CreateInvoice.start(other, connection).id).not_to eq(going.id)
      expect([waiting.reload.state, going.reload.state]).to eq(%w[cancelled cancelled])
    end

    it "is reused as before when it was made on the file the connection opens now" do
      switch_file
      going = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
      stub_request(:post, /workflow-runs/).to_return(json_data("id" => "run-q-1", "state" => "running"))

      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection).id).to eq(going.id)
    end
  end

  describe "a queue that QuBe Sync never confirmed" do
    let(:customers_url) { %r{/connections/#{QubeRailsHelpers::QUBE_ID}/customers} }

    it "is failed, not sent again, and a new request goes" do
      old = QubeRails::QueuedRequest.create!(connection: connection, operation: "find_customer", record: customer,
                                             reference: "find_customer-1-old", state: "queued",
                                             params: { "full_name" => "Riverbend Electric" })
      switch_file
      queued = stub_request(:get, customers_url).to_return(json_data("id" => "req-q-new", "state" => "queued"))

      row = QuickbooksDesktop::FindCustomer.queue(customer, connection)

      expect(row.id).not_to eq(old.id)
      expect(row).to have_attributes(qube_id: "req-q-new", reused?: false)
      expect(queued).to have_been_made.once
      expect(old.reload).to have_attributes(state: "failed", error: { "error_type" => "company_file_changed" })
      expect(old.ended_at).not_to be_nil
    end
  end
end
