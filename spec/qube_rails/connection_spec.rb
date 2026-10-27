# frozen_string_literal: true

RSpec.describe QubeRails::Connection do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }

  it "builds its webhook URL from the webhook_url setting and its own id" do
    expect(connection.webhook_url).to eq("https://app.example/webhooks/qube/connections/#{connection.id}")
  end

  it "is not checking in only when stalled for that reason" do
    connection.update!(status: "stalled", stall_reason: "not_checking_in")
    expect(connection).to be_not_checking_in

    connection.update!(stall_reason: "quickbooks_unavailable")
    expect(connection).not_to be_not_checking_in

    connection.update!(status: "connected", stall_reason: nil)
    expect(connection).not_to be_not_checking_in
  end

  it "links a record's QuickBooks id by kind, and reads it back both ways" do
    row = connection.link(customer, kind: "customer", qb_id: "80000001-1", edit_sequence: "171", name: "Riverbend Electric")

    expect(row).to have_attributes(kind: "customer", qb_id: "80000001-1", edit_sequence: "171",
                                   name: "Riverbend Electric", record: customer)
    expect(connection.qb_id_for(customer, kind: "customer")).to eq("80000001-1")
    expect(connection.qb_id_for(customer, kind: "vendor")).to be_nil
    expect(connection.find_linked("80000001-1", kind: "customer")).to eq(customer)
    expect(connection.find_linked("nope", kind: "customer")).to be_nil
    expect(connection.quickbooks_record("80000001-1", kind: "customer")).to eq(row)
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

    expect(connection.find_linked("80000001-1", kind: "customer")).to eq(customer)
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

    expect(connection.find_linked("80000001-1", kind: "customer")).to eq(customer)
    expect(second.find_linked("80000001-1", kind: "customer")).to eq(other)
  end

  it "lists an owner's connections, whatever its key's type" do
    second = make_connection(account, qube_id: "conn-q-2")
    make_connection(Account.create!(name: "Someone else"), qube_id: "conn-q-3")

    expect(described_class.owned_by(account)).to contain_exactly(connection, second)
    expect(connection.owner_id).to eq(account.id.to_s)
  end

  describe "list families (one ListID counter per family, verified on QuickBooks Enterprise 24.0)" do
    let(:contact) { Customer.create!(account: account, name: "Lone Star Supply") }

    it "maps kinds to families" do
      family = QubeRails::QuickbooksRecord.method(:family_for)
      expect(%w[customer vendor employee other_name].map(&family)).to all(eq("name"))
      expect(%w[item item_service item_non_inventory item_sales_tax item_group].map(&family)).to all(eq("item"))
      expect(%w[account class invoice bill made_up_kind].map(&family)).to eq(%w[account class invoice bill made_up_kind])
    end

    it "links one contact as a customer and as a vendor, with different ids" do
      connection.link(contact, kind: "customer", qb_id: "80000010-1")
      connection.link(contact, kind: "vendor", qb_id: "80000011-1")

      expect(connection.qb_id_for(contact, kind: "customer")).to eq("80000010-1")
      expect(connection.qb_id_for(contact, kind: "vendor")).to eq("80000011-1")
      expect(connection.quickbooks_records.pluck(:list).uniq).to eq(["name"])
    end

    it "finds an EntityRef's id with no kind" do
      connection.link(contact, kind: "vendor", qb_id: "80000011-1")

      expect(connection.find_linked("80000011-1")).to eq(contact)
      expect(connection.find_linked("80000011-1", kind: "customer")).to eq(contact) # same name family
      expect(connection.quickbooks_record("80000011-1").kind).to eq("vendor")
    end

    it "finds an item linked as item_service as item and as item_non_inventory, and relinks it with a new kind" do
      connection.link(customer, kind: "item_service", qb_id: "80000003-1")

      expect(connection.qb_id_for(customer, kind: "item")).to eq("80000003-1")
      expect(connection.qb_id_for(customer, kind: "item_non_inventory")).to eq("80000003-1")
      expect(connection.find_linked("80000003-1", kind: "item")).to eq(customer)

      connection.link(customer, kind: "item_non_inventory", qb_id: "80000003-1", edit_sequence: "2")

      expect(connection.quickbooks_records.where(list: "item").pluck(:kind, :edit_sequence))
        .to eq([%w[item_non_inventory 2]])
    end

    it "links the same qb_id in two families to two records without a clash" do
      connection.link(contact, kind: "customer", qb_id: "80000003-1")
      connection.link(customer, kind: "account", qb_id: "80000003-1")

      expect(connection.find_linked("80000003-1", kind: "customer")).to eq(contact)
      expect(connection.find_linked("80000003-1", kind: "account")).to eq(customer)
      expect(connection.quickbooks_records.count).to eq(2)
    end

    it "raises for a no-kind lookup that finds the id in more than one family" do
      connection.link(contact, kind: "customer", qb_id: "80000003-1")
      connection.link(customer, kind: "class", qb_id: "80000003-1")

      expect { connection.find_linked("80000003-1") }
        .to raise_error(ArgumentError, /more than one kind \(class, customer\): pass kind:/)
    end

    it "never hands out a customer's id as a vendor's" do
      connection.link(contact, kind: "customer", qb_id: "80000010-1")

      expect(connection.qb_id_for(contact, kind: "vendor")).to be_nil
    end

    it "raises for qb_id_for when the family has several links and none is that kind" do
      connection.link(customer, kind: "item_service", qb_id: "80000003-1")
      connection.link(customer, kind: "item_inventory", qb_id: "80000004-1")

      expect { connection.qb_id_for(customer, kind: "item") }.to raise_error(ArgumentError, /pass kind/)
    end
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
