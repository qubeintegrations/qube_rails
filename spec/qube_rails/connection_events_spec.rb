# frozen_string_literal: true

RSpec.describe QubeRails::ConnectionEvents do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account, status: "pending") }

  def run_event(name, changes = {}, target = connection)
    QubeRails::WebhookJob.new.perform("connection", target.id.to_s, vector_body(name, changes))
    target.reload
  end

  it "applies each of the four events to the row, then hands it to the app's class with its owner" do
    run_event("connection.connected")
    expect(connection).to have_attributes(status: "connected", revision: 1)

    run_event("connection.setup_cancelled")
    expect(connection.status).to eq("setup_cancelled")

    run_event("connection.stalled")
    expect(connection).to have_attributes(status: "stalled", stall_reason: "not_checking_in", revision: 3)

    run_event("connection.resumed")
    expect(connection).to have_attributes(status: "connected", stall_reason: nil, revision: 4)

    id = connection.id
    expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([
      [:connected, id, account.id, "connected"],
      [:setup_cancelled, id, account.id, "setup_cancelled"],
      [:stalled, id, account.id, "not_checking_in"],
      [:resumed, id, account.id, nil]
    ])
  end

  it "keeps the type each event's connection carries: an upgrade in the dashboard shows on the row" do
    connection_hash = JSON.parse(vector_body("connection.connected"))["connection"]
    run_event("connection.connected", "connection" => connection_hash.merge("type" => "standard"))
    expect(connection.connection_type).to eq("standard")

    run_event("connection.resumed", "connection" => connection_hash.merge("type" => "realtime"), "revision" => 5)
    expect(connection.connection_type).to eq("realtime")
  end

  it "tells the pages of records with a run going on it to refresh when it stalls or resumes" do
    channel = class_double("Turbo::StreamsChannel", broadcast_refresh_to: nil)
    stub_const("Turbo::StreamsChannel", channel)
    going = Invoice.create!(account: account, number: "1001")
    done = Invoice.create!(account: account, number: "1002")
    make_run(going, connection).update!(state: "running")
    make_run(done, connection).update!(state: "completed", ended_at: Time.now)

    run_event("connection.connected")
    expect(channel).not_to have_received(:broadcast_refresh_to)

    run_event("connection.stalled")
    expect(channel).to have_received(:broadcast_refresh_to).with(going, :qube_rails).once
    run_event("connection.resumed")
    expect(channel).to have_received(:broadcast_refresh_to).with(going, :qube_rails).twice
    expect(channel).not_to have_received(:broadcast_refresh_to).with(done, :qube_rails)
  end

  it "skips an event whose connection id isn't the row's qube_id" do
    run_event("connection.connected", "connection" => { "id" => "someone-elses" })

    expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
    expect(connection).to have_attributes(status: "pending", revision: nil)
    expect(log_output).to include("connection #{connection.id} skipped connection.connected for " \
                                  "\"someone-elses\": not this connection")
  end

  describe "a row with no qube_id yet" do
    before { connection.update!(qube_id: nil) }

    it "raises NotReady, so the queue retries, when QuBe Sync has no connection for the row" do
      stub_request(:get, api_url("/connections")).to_return(json_data([{ "id" => "other", "webhook_url" => "https://elsewhere" }]))

      expect { QubeRails.run("connection", connection.id.to_s, vector_body("connection.connected")) }
        .to raise_error(QubeRails::NotReady, /no qube_id yet/)
      expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
    end

    it "retries the job on NotReady" do
      stub_request(:get, api_url("/connections")).to_return(json_data([]))
      QubeRails::WebhookJob.perform_now("connection", connection.id.to_s, vector_body("connection.connected"))

      expect(QubeRails::WebhookJob).to have_been_enqueued.with("connection", connection.id.to_s, anything)
    end

    it "adopts QuBe Sync's connection made with the row's webhook URL, then applies the event" do
      stub_request(:get, api_url("/connections"))
        .to_return(json_data([qube_connection_for(connection, "id" => QubeRailsHelpers::QUBE_ID)]))

      QubeRails.run("connection", connection.id.to_s, vector_body("connection.connected"))

      expect(connection.reload).to have_attributes(qube_id: QubeRailsHelpers::QUBE_ID, status: "connected")
      expect(log_output).to include("adopted QuBe Sync's connection")
    end
  end

  it "skips an event that isn't a connection's" do
    run_event("workflow_run.completed")

    expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
    expect(log_output).to include("skipped workflow_run.completed for nil: not this connection")
  end

  it "applies an event only when it's newer than the last applied" do
    run_event("connection.resumed") # revision 4
    run_event("connection.stalled") # revision 3, a retry that came late

    expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).to eq([:resumed])
    expect(connection).to have_attributes(status: "connected", revision: 4)
  end

  it "keeps two connections on one account apart" do
    other = make_connection(account, qube_id: "conn-q-2", status: "pending")
    run_event("connection.connected")
    run_event("connection.connected", {}, other) # the vector's id is the first's

    expect(connection.status).to eq("connected")
    expect(other.reload.status).to eq("pending")
  end

  describe "connection.company_file_changed" do
    let(:invoice) { Invoice.create!(account: account, number: "1001") }
    let(:other) { make_connection(account, qube_id: "conn-q-2") }

    before do
      run_event("connection.connected") # revision 1
      connection.link(invoice, kind: "invoice", qb_id: "1A-1760999990", edit_sequence: "1760999990")
      connection.link(Customer.create!(account: account, name: "Riverbend"), kind: "customer", qb_id: "80000024-1")
      other.link(invoice, kind: "invoice", qb_id: "2B-1760999990")
      QubeRails::SyncMark.advance(connection, "sync_customer", 1.hour.ago)
      QubeRails::SyncMark.advance(other, "sync_customer", 1.hour.ago)
      QuickbooksDesktop::ConnectionEvents.calls.clear
    end

    it "sets it back to pending, drops its QuickBooks links and sync marks, and calls the app's hook once" do
      run_event("connection.company_file_changed") # revision 5

      expect(connection).to have_attributes(status: "pending", stall_reason: nil, revision: 5)
      expect(connection.company_file_changed_at).to be_within(5.seconds).of(Time.now)
      expect(connection.quickbooks_records).to be_empty
      expect(connection.qb_id_for(invoice, kind: "invoice")).to be_nil
      expect(connection.last_synced_at("sync_customer")).to be_nil
      expect(QuickbooksDesktop::ConnectionEvents.calls)
        .to eq([[:company_file_changed, connection.id, account.id, "pending"]])
    end

    it "leaves the account's other connections alone" do
      run_event("connection.company_file_changed")

      expect(other.qb_id_for(invoice, kind: "invoice")).to eq("2B-1760999990")
      expect(other.last_synced_at("sync_customer")).not_to be_nil
      expect(other.reload.status).to eq("connected")
    end

    it "does nothing for a replay, or for an event older than the last applied" do
      run_event("connection.company_file_changed")
      connection.link(invoice, kind: "invoice", qb_id: "9Z-1761000500") # learned on the new file
      run_event("connection.company_file_changed") # the same delivery again
      run_event("connection.company_file_changed", "revision" => 4, "delivery_id" => "late")

      expect(connection.qb_id_for(invoice, kind: "invoice")).to eq("9Z-1761000500")
      expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).to eq([:company_file_changed])

      run_event("connection.connected", "revision" => 6)
      expect(connection).to have_attributes(status: "connected", revision: 6)
    end

    it "is skipped when it's older than the last applied, and drops nothing" do
      run_event("connection.resumed", "revision" => 7)
      run_event("connection.company_file_changed") # revision 5, came late

      expect(connection.qb_id_for(invoice, kind: "invoice")).to eq("1A-1760999990")
      expect(connection).to have_attributes(status: "connected", company_file_changed_at: nil)
      expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).to eq([:resumed])
    end

    it "makes a record sent on the old file read as not sent" do
      make_run(invoice, connection).update!(state: "completed", ended_at: Time.now, created_at: 1.minute.ago)
      expect(connection.sync_status(invoice, operation: "create_invoice")).to be_in_quickbooks

      run_event("connection.company_file_changed")

      expect(connection.sync_status(invoice, operation: "create_invoice")).to be_not_sent
      expect(connection.not_in_quickbooks(Invoice.all)).to include(invoice)

      travel(1.second) { make_run(invoice, connection, reference: "create_invoice-after") }
      expect(connection.sync_status(invoice, operation: "create_invoice")).to be_sending
    end

    it "logs in the base handler" do
      event = QubeRails::Backend.parse(vector_body("connection.company_file_changed"))
      described_class.new(connection).company_file_changed(event)

      expect(log_output).to include("INFO QuBe Sync: connection #{connection.id}: connection.company_file_changed (revision 5)")
    end
  end

  it "raises naming the initializer when connection_events isn't set" do
    QubeRails.config.connection_events = nil

    expect { QubeRails.run("connection", connection.id.to_s, vector_body("connection.connected")) }
      .to raise_error(QubeRails::NotConfigured, %r{connection_events.*config/initializers/qube_rails\.rb})
  end

  it "logs in the base handlers, a stall as a warning" do
    event = QubeRails::Backend.parse(vector_body("connection.stalled"))
    described_class.new(connection).stalled(event)

    expect(log_output).to include("WARN QuBe Sync: connection #{connection.id}: connection.stalled (revision 3)")
  end
end
