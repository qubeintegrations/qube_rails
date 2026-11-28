# frozen_string_literal: true

# Work from before a connection switched company file (company_file_changed_at) is the old file's:
# its late events keep no links and no sync mark, and before the record is sent again it's settled
# with QuBe Sync (cancelled there, ended here once QuBe Sync says so), never ended on our say-so.
RSpec.describe "Work from before a company file change" do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }
  let(:realtime) { { "connection" => { "id" => QubeRailsHelpers::QUBE_ID, "type" => "realtime" } } }
  let(:runs_url) { api_url("/connections/#{QubeRailsHelpers::QUBE_ID}/workflow-runs") }
  let(:cancel_url) { "#{runs_url}/run-q-old/cancel" }

  def connection_event(name, changes = {})
    QubeRails::WebhookJob.new.perform("connection", connection.id.to_s, vector_body(name, realtime.merge(changes)))
    connection.reload
  end

  def switch_file
    travel(1.second)
    connection_event("connection.company_file_changed", "revision" => 5)
    connection_event("connection.connected", "revision" => 6)
  end

  def run_answer(state, id: "run-q-old", reference: nil)
    { "id" => id, "state" => state, "reference" => reference,
      "links" => state == "running" ? { "cancel" => cancel_url } : {} }
  end

  def no_run_by_reference
    stub_request(:get, runs_url).with(query: hash_including("reference" => /.+/)).to_return(json_data([]))
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

    it "links nothing through link_references in the run's real handler, nor through another copy of the connection" do
      linker = Class.new(QuickbooksDesktop::CreateInvoice) do
        def ended(event)
          customer = Customer.find_by!(name: "Riverbend Electric")
          link_references(event) { customer }
          QubeRails::Connection.find(connection.id).link(customer, kind: "customer", qb_id: "80-ELSEWHERE")
        end
      end
      stub_const("QuickbooksDesktop::Linker", linker)
      QubeRails.config.operations = QubeRails.config.operations.merge("linker" => "QuickbooksDesktop::Linker")
      customer
      old = make_run(invoice, connection, operation: "linker")
      switch_file
      body = run_body("workflow_run.completed", old, "revision" => 4, "workflow" => "add_transaction",
                                                     "output" => { "refs" => { "customer_ref" => { "list_id" => "80-OLD", "type" => "customer" } } })

      QubeRails::WebhookJob.new.perform("run", old.id.to_s, body)

      expect(old.reload.state).to eq("completed")
      expect(connection.quickbooks_records.where(qb_id: %w[80-OLD 80-ELSEWHERE])).to be_empty
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

      linker.new(customer, row).handle(QubeRails::Backend.parse(vector_body("request: an answer", "id" => "req-q-1")))

      expect(linker.linked).to eq([nil])
      expect(connection.quickbooks_records.where(qb_id: "80-OLD")).to be_empty
    end
  end

  describe "starting a record whose last run is from before the change" do
    it "cancels a confirmed run at QuBe Sync, ends it once QuBe Sync says so, then starts a new one" do
      old = make_run(invoice, connection).tap { |r| r.update!(qube_run_id: "run-q-old", cancel_url: cancel_url) }
      switch_file
      cancelled = stub_request(:post, cancel_url).to_return(json_data(run_answer("cancelled")))
      started = stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(cancelled).to have_been_made.once
      expect(started).to have_been_made.once
      expect(run).to have_attributes(qube_run_id: "run-q-new", reused?: false)
      expect(old.reload).to have_attributes(state: "cancelled", revision: 0,
                                            cancel_reason: QubeRails.t("status.company_file_changed"))
    end

    it "starts nothing while QuBe Sync can't confirm the old run ended (no answer, or still running)" do
      make_run(invoice, connection).tap { |r| r.update!(qube_run_id: "run-q-old", cancel_url: cancel_url) }
      switch_file
      stub_request(:post, cancel_url).to_timeout
      started = stub_request(:post, runs_url)

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::OldFileWorkPending)
      stub_request(:post, cancel_url).to_return(json_data(run_answer("running")))
      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::OldFileWorkPending)

      expect(started).not_to have_been_made
      expect(QubeRails::Run.count).to eq(1)
      expect(QubeRails::Run.first.state).to eq("running")
    end

    it "takes the ending QuBe Sync reports for a run that had already ended there" do
      old = make_run(invoice, connection).tap { |r| r.update!(qube_run_id: "run-q-old", cancel_url: cancel_url) }
      switch_file
      stub_request(:post, cancel_url).to_return(status: 409, body: '{"errors":{"code":"already_finished"}}',
                                                headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{runs_url}/run-q-old").to_return(json_data(run_answer("completed")))
      stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(old.reload.state).to eq("completed")
    end

    it "finds a start QuBe Sync never confirmed by its reference, and cancels it there" do
      old = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
      switch_file
      stub_request(:get, runs_url).with(query: { "reference" => old.reference })
                                  .to_return(json_data([run_answer("running", reference: old.reference)]))
      cancelled = stub_request(:post, cancel_url).to_return(json_data(run_answer("cancelled")))
      stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(cancelled).to have_been_made.once
      expect(old.reload).to have_attributes(state: "cancelled", qube_run_id: "run-q-old")
      expect(run.id).not_to eq(old.id)
    end

    it "ends a start QuBe Sync never took once it can't still land, and never sends its reference again" do
      old = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
      switch_file
      no_run_by_reference
      started = stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::OldFileWorkPending) # it may still be on its way
      travel(QubeRails::OldFileWork::UNCONFIRMED_AFTER + 1)
      run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(old.reload.state).to eq("cancelled")
      expect(run.id).not_to eq(old.id)
      expect(started).to have_been_made.once
      expect(a_request(:post, runs_url).with { |req| JSON.parse(req.body)["reference"] == old.reference })
        .not_to have_been_made
    end

    it "ends one refused as realtime_required at once: QuBe Sync stored nothing" do
      waiting = make_run(invoice, connection).tap { |r| r.update!(state: "realtime_required") }
      switch_file
      stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection).id).not_to eq(waiting.id)
      expect(waiting.reload.state).to eq("cancelled")
    end

    it "reuses as before a run made on the file the connection opens now" do
      switch_file
      going = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
      stub_request(:post, runs_url).to_return(json_data("id" => "run-q-1", "state" => "running"))

      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection).id).to eq(going.id)
    end

    it "settles a run started while a company_file_changed was late at QuBe Sync before starting another" do
      stub_request(:post, runs_url)
        .to_return(json_data("id" => "run-q-old", "state" => "running", "links" => { "cancel" => cancel_url }))
      connection_event("connection.connected", "revision" => 3)
      first = QuickbooksDesktop::CreateInvoice.start(invoice, connection)
      travel(2.seconds)
      connection_event("connection.company_file_changed", "revision" => 2) # came late
      cancelled = stub_request(:post, cancel_url).to_return(json_data(run_answer("cancelled")))
      stub_request(:post, runs_url).to_return(json_data("id" => "run-q-2", "state" => "running"))

      second = QuickbooksDesktop::CreateInvoice.start(invoice, connection)

      expect(cancelled).to have_been_made.once
      expect(first.reload.state).to eq("cancelled")
      expect(second.qube_run_id).to eq("run-q-2")
    end
  end

  describe "retrying an old start" do
    it "never resends the old reference and input: it's settled, and the record started afresh" do
      old = make_run(invoice, connection).tap { |r| r.update!(state: "starting", input: { "old" => "ids" }) }
      switch_file
      travel(QubeRails::OldFileWork::UNCONFIRMED_AFTER + 1)
      no_run_by_reference
      started = stub_request(:post, runs_url).to_return(json_data("id" => "run-q-new", "state" => "running"))

      run = old.retry_start!

      expect(started).to have_been_made.once
      expect(a_request(:post, runs_url).with { |req| JSON.parse(req.body)["reference"] == old.reference })
        .not_to have_been_made
      expect(run.id).not_to eq(old.id)
      expect(old.reload.state).to eq("cancelled")
    end
  end

  describe "queueing a record whose last request is from before the change" do
    let(:customers_url) { %r{/connections/#{QubeRailsHelpers::QUBE_ID}/customers} }
    let(:request_url) { api_url("/connections/#{QubeRailsHelpers::QUBE_ID}/queued-requests/req-q-old") }

    def old_request(attrs = {})
      QubeRails::QueuedRequest.create!({ connection: connection, operation: "find_customer", record: customer,
                                         reference: "find_customer-1-old", state: "queued",
                                         params: { "full_name" => "Riverbend Electric" } }.merge(attrs))
    end

    it "discards one QuickBooks hasn't picked up, ends it once QuBe Sync says so, then queues a new one" do
      old = old_request(qube_id: "req-q-old")
      switch_file
      stub_request(:get, request_url).to_return(json_data("id" => "req-q-old", "state" => "waiting"),
                                                json_data("id" => "req-q-old", "state" => "discarded",
                                                          "error" => { "error_type" => "discarded" }))
      discarded = stub_request(:post, "#{request_url}/discard").to_return(json_data("id" => "req-q-old"))
      queued = stub_request(:get, customers_url).to_return(json_data("id" => "req-q-new", "state" => "queued"))

      row = QuickbooksDesktop::FindCustomer.queue(customer, connection)

      expect(discarded).to have_been_made.once
      expect(queued).to have_been_made.once
      expect(row).to have_attributes(qube_id: "req-q-new", reused?: false)
      expect(old.reload).to have_attributes(state: "discarded", error: { "error_type" => "discarded" })
    end

    it "queues nothing while QuickBooks has the old one" do
      old_request(qube_id: "req-q-old")
      switch_file
      stub_request(:get, request_url).to_return(json_data("id" => "req-q-old", "state" => "sent"))
      queued = stub_request(:get, customers_url)

      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(QubeRails::OldFileWorkPending)
      expect(queued).not_to have_been_made
    end

    it "ends one QuBe Sync never acknowledged once it can't still land" do
      old = old_request
      switch_file
      queued = stub_request(:get, customers_url).to_return(json_data("id" => "req-q-new", "state" => "queued"))

      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(QubeRails::OldFileWorkPending)
      travel(QubeRails::OldFileWork::UNCONFIRMED_AFTER + 1)
      row = QuickbooksDesktop::FindCustomer.queue(customer, connection)

      expect(row.id).not_to eq(old.id)
      expect(queued).to have_been_made.once
      expect(old.reload).to have_attributes(state: "failed", error: { "error_type" => "company_file_changed" })
    end

    it "settles one again on retry_queue! rather than resending its old params" do
      old = old_request
      switch_file
      travel(QubeRails::OldFileWork::UNCONFIRMED_AFTER + 1)
      queued = stub_request(:get, customers_url).to_return(json_data("id" => "req-q-new", "state" => "queued"))

      row = old.retry_queue!

      expect(row.id).not_to eq(old.id)
      expect(queued).to have_been_made.once
      expect(old.reload.state).to eq("failed")
    end
  end
end
