# frozen_string_literal: true

# A connection's links after a company file change: stale and unused, then checked against the
# new file once it's connected again.
RSpec.describe QubeRails::LinkCheck do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account, status: "pending") }
  let(:riverbend) { Customer.create!(account: account, name: "Riverbend Electric") }
  let(:northwind) { Customer.create!(account: account, name: "Northwind Builders") }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:customers_url) { %r{\A#{Regexp.escape(api_url("/connections/#{connection.qube_id}/customers"))}\?} }
  let(:invoices_url) { %r{\A#{Regexp.escape(api_url("/connections/#{connection.qube_id}/invoices"))}\?} }

  def run_event(name, changes = {})
    QubeRails::WebhookJob.new.perform("connection", connection.id.to_s, vector_body(name, changes))
    connection.reload
  end

  # The answer QuBe Sync sends a check: data, and the 500 warning QuickBooks gives for an id it lacks.
  def answer(row, data, warning: false, page_request_id: "pr-#{row.id}")
    json = { "status" => "success", "data" => data }
    json["warning"] = { "code" => 500, "message" => "could not be found" } if warning
    body = vector_body("request: an answer", "id" => row.qube_id, "page_request_id" => page_request_id,
                                             "page" => 1, "iteration_state" => "not_applicable",
                                             "state" => "response_received", "response_json" => json)
    QubeRails::WebhookJob.new.perform("request", row.id.to_s, body)
  end

  def checks(kind)
    QubeRails::QueuedRequest.where(connection: connection, operation: "qube_rails.check_links:#{kind}").order(:id)
  end

  def stub_queue(url)
    count = 0
    stub_request(:get, url).to_return { json_data("id" => "check-q-#{count += 1}", "state" => "queued") }
  end

  before do
    run_event("connection.connected") # revision 1
    connection.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", edit_sequence: "100",
                               name: "Riverbend Electric")
    connection.link(northwind, kind: "customer", qb_id: "80000025-1760999991", edit_sequence: "200",
                               name: "Northwind Builders")
    connection.link(invoice, kind: "invoice", qb_id: "1A-1760999990", edit_sequence: "300", name: "1001")
    run_event("connection.company_file_changed") # revision 5
    QuickbooksDesktop::ConnectionEvents.calls.clear
  end

  it "queues nothing while it's set up again, then a check per kind by ListID and TxnID on connected" do
    expect(a_request(:get, /qube\.example/)).not_to have_been_made

    customers = stub_queue(customers_url)
    invoices = stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)

    expect(customers).to have_been_made.once
    expect(invoices).to have_been_made.once
    expect(checks("customer").first).to have_attributes(
      record: connection, qube_id: "check-q-1", state: "queued",
      params: { "list_id" => %w[80000024-1760999990 80000025-1760999991] }
    )
    expect(checks("invoice").first.params).to eq("txn_id" => %w[1A-1760999990])
  end

  it "queues nothing on a connected with nothing stale, and nothing again while a check is going" do
    other = make_connection(account, qube_id: "conn-q-2")
    QubeRails::WebhookJob.new.perform("connection", other.id.to_s,
                                      vector_body("connection.connected", "connection" => { "id" => "conn-q-2" },
                                                                          "revision" => 9))
    expect(a_request(:get, /qube\.example/)).not_to have_been_made

    stub_queue(customers_url)
    stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)
    run_event("connection.connected", "revision" => 6) # retried
    run_event("connection.resumed", "revision" => 7)

    expect(a_request(:get, customers_url)).to have_been_made.once
    expect(checks("customer").count).to eq(1)
  end

  describe "an answer" do
    before do
      stub_queue(customers_url)
      stub_queue(invoices_url)
      run_event("connection.connected", "revision" => 6)
      QuickbooksDesktop::ConnectionEvents.calls.clear
    end

    it "relinks a record found with the same name, with its new EditSequence, and drops one with another name" do
      answer(checks("customer").first, [
        { "list_id" => "80000024-1760999990", "full_name" => "Riverbend Electric", "edit_sequence" => "777" },
        { "list_id" => "80000025-1760999991", "full_name" => "Someone Else", "edit_sequence" => "888" }
      ])

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(connection.quickbooks_record("80000024-1760999990", kind: "customer").edit_sequence).to eq("777")
      expect(connection.qb_id_for(northwind, kind: "customer")).to be_nil
      expect(QubeRails::QuickbooksRecord.where(qb_id: "80000025-1760999991")).to be_empty
      expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([[:links_checked, "customer", 1, 1, 1]])
    end

    it "drops a transaction QuickBooks doesn't have, and relinks one by its RefNumber" do
      answer(checks("invoice").first, [], warning: true)
      expect(connection.quickbooks_records.where(kind: "invoice")).to be_empty

      connection.link(invoice, kind: "invoice", qb_id: "1A-1760999990", name: "1001")
      connection.quickbooks_records.update_all(stale_since: Time.now)
      stub_queue(invoices_url)
      connection.check_stale_links
      answer(checks("invoice").last, [{ "txn_id" => "1A-1760999990", "ref_number" => "1001", "edit_sequence" => "5" }])

      expect(connection.qb_id_for(invoice, kind: "invoice")).to eq("1A-1760999990")
    end

    it "asks again one at a time about ids a batch's 500 left out, rather than dropping them" do
      answer(checks("customer").first,
             [{ "list_id" => "80000024-1760999990", "full_name" => "Riverbend Electric", "edit_sequence" => "1" }],
             warning: true)

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(connection.stale_links.find_by(qb_id: "80000025-1760999991")).to have_attributes(check_alone: true)
      second = checks("customer").last
      expect(second).not_to eq(checks("customer").first)
      expect(second.params).to eq("list_id" => ["80000025-1760999991"])

      answer(second, [], warning: true)
      expect(QubeRails::QuickbooksRecord.where(qb_id: "80000025-1760999991")).to be_empty
      expect(checks("customer").count).to eq(2) # nothing stale left of the kind
    end

    it "is safe to deliver twice, and leaves a link a run linked since alone" do
      row = checks("customer").first
      connection.link(northwind, kind: "customer", qb_id: "80000099-1761000500", name: "Northwind Builders")
      found = [{ "list_id" => "80000024-1760999990", "full_name" => "Riverbend Electric", "edit_sequence" => "7" }]
      answer(row, found)
      answer(row, found)

      expect(connection.qb_id_for(northwind, kind: "customer")).to eq("80000099-1761000500")
      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([[:links_checked, "customer", 1, 0, 1]])
    end

    it "queues the next batch when a kind has more than one" do
      stub_const("QubeRails::LinkCheck::BATCH", 1)
      connection.quickbooks_records.where(kind: "customer").update_all(stale_since: Time.now)
      QubeRails::QueuedRequest.delete_all
      connection.check_stale_links
      expect(checks("customer").first.params).to eq("list_id" => ["80000024-1760999990"])

      answer(checks("customer").first,
             [{ "list_id" => "80000024-1760999990", "full_name" => "Riverbend Electric", "edit_sequence" => "7" }])

      expect(checks("customer").last.params).to eq("list_id" => ["80000025-1760999991"])
    end

    it "leaves the links stale, unused, when the check fails" do
      row = checks("invoice").first
      body = vector_body("request: QuickBooks refused it", "id" => row.qube_id)
      QubeRails::WebhookJob.new.perform("request", row.id.to_s, body)

      expect(connection.stale_links.where(kind: "invoice").count).to eq(1)
      expect(connection.qb_id_for(invoice, kind: "invoice")).to be_nil
    end
  end

  it "never sends a stale link's id: an input refers by name, and a run linking it on the new file makes it current" do
    run = make_run(invoice, connection)
    operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)

    expect(operation.quickbooks_ref(riverbend, kind: "customer", name: "Riverbend Electric"))
      .to eq(full_name: "Riverbend Electric")

    connection.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", name: "Riverbend Electric")
    expect(operation.quickbooks_ref(riverbend, kind: "customer")).to eq(list_id: "80000024-1760999990")
    expect(connection.stale_links.where(kind: "customer").count).to eq(1)
  end

  it "leaves another connection's links alone" do
    other = make_connection(account, qube_id: "conn-q-2")
    other.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", name: "Riverbend Electric")
    stub_queue(customers_url)
    stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)
    answer(checks("customer").first, [], warning: true)

    expect(other.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
    expect(other.stale_links).to be_empty
  end
end
