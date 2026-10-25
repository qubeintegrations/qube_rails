# frozen_string_literal: true

RSpec.describe QubeRails::Connection do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }

  it "builds its webhook URL from the webhook_url setting and its own id" do
    expect(connection.webhook_url).to eq("https://app.example/webhooks/qube/connections/#{connection.id}")
  end

  it "links a record's QuickBooks id by kind, and reads it back both ways" do
    row = connection.link(customer, kind: "customer", qb_id: "80000001-1", edit_sequence: "171", name: "Riverbend Electric")

    expect(row).to have_attributes(kind: "customer", qb_id: "80000001-1", edit_sequence: "171",
                                   name: "Riverbend Electric", record: customer)
    expect(connection.qb_id_for(customer, kind: "customer")).to eq("80000001-1")
    expect(connection.qb_id_for(customer, kind: "vendor")).to be_nil
    expect(connection.find_linked("customer", "80000001-1")).to eq(customer)
    expect(connection.find_linked("customer", "nope")).to be_nil
    expect(connection.quickbooks_record("customer", "80000001-1")).to eq(row)
  end

  it "replaces a record's id for the same kind when it's linked again" do
    connection.link(customer, kind: "customer", qb_id: "80000001-1")
    connection.link(customer, kind: "customer", qb_id: "80000002-1", edit_sequence: "9")

    expect(connection.qb_id_for(customer, kind: "customer")).to eq("80000002-1")
    expect(connection.quickbooks_records.count).to eq(1)
  end

  it "moves a qb_id between records, and logs it" do
    other = Customer.create!(account: account, name: "Riverbend (old)")
    connection.link(other, kind: "customer", qb_id: "80000001-1")
    connection.link(customer, kind: "customer", qb_id: "80000002-1")

    connection.link(customer, kind: "customer", qb_id: "80000001-1")

    expect(connection.find_linked("customer", "80000001-1")).to eq(customer)
    expect(connection.qb_id_for(other, kind: "customer")).to be_nil
    expect(connection.qb_id_for(customer, kind: "customer")).to eq("80000001-1")
    expect(connection.quickbooks_records.count).to eq(1)
    expect(log_output).to include("customer 80000001-1 moved from Customer #{other.id} to Customer #{customer.id}")
  end

  it "keeps the same QuickBooks id on two connections apart" do
    second = make_connection(account, qube_id: "conn-q-2")
    other = Customer.create!(account: account, name: "Other file's")
    connection.link(customer, kind: "customer", qb_id: "80000001-1")
    second.link(other, kind: "customer", qb_id: "80000001-1")

    expect(connection.find_linked("customer", "80000001-1")).to eq(customer)
    expect(second.find_linked("customer", "80000001-1")).to eq(other)
  end

  it "lists an owner's connections, whatever its key's type" do
    second = make_connection(account, qube_id: "conn-q-2")
    make_connection(Account.create!(name: "Someone else"), qube_id: "conn-q-3")

    expect(described_class.owned_by(account)).to contain_exactly(connection, second)
    expect(connection.owner_id).to eq(account.id.to_s)
  end

  it "refuses a link without a qb_id" do
    expect { connection.link(customer, kind: "customer", qb_id: nil) }.to raise_error(ArgumentError)
  end

  describe "two connections on one account" do
    it "each have their own runs and links" do
      second = make_connection(account, qube_id: "conn-q-2")
      invoice = Invoice.create!(account: account, number: "1001")
      first_run = make_run(invoice, connection)
      second_run = make_run(invoice, second)

      ended = lambda do |run, txn_id|
        body = run_body("workflow_run.completed", run, "revision" => 1,
                                                       "output" => { "record" => { "txn_id" => txn_id } })
        QubeRails.run("run", run.id.to_s, body)
      end
      ended.call(first_run, "T-1")
      ended.call(second_run, "T-2")

      expect(connection.runs).to eq([first_run])
      expect(second.runs).to eq([second_run])
      expect(connection.qb_id_for(invoice, kind: "invoice")).to eq("T-1")
      expect(second.qb_id_for(invoice, kind: "invoice")).to eq("T-2")
    end
  end
end
