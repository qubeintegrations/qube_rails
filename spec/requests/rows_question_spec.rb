# frozen_string_literal: true

# add_transaction's one question for every record QuickBooks doesn't have (a rows field), as
# QuBe Sync sends it: a row per record, the columns each asks, and a search per record column.
RSpec.describe "A rows question", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:decisions) { "https://qube.example/api/v2/connections/c/workflow-runs/r/decisions?prompt_token=tok" }
  let(:search_url) { "https://qube.example/api/v2/connections/c/workflow-runs/r/search?prompt_token=tok" }
  let(:signed_in) { { "X-Account" => account.id.to_s } }
  let(:items) do
    [{ "value" => "item_service", "label" => "Service" }, { "value" => "item_inventory", "label" => "Inventory part" },
     { "value" => "item_non_inventory", "label" => "Non-inventory part" }]
  end
  let(:question) do
    {
      "token" => "tok",
      "message" => "QuickBooks doesn't have these records the transaction names.",
      "choices" => [
        {
          "id" => "proceed",
          "label" => "Create or use these, then add the transaction",
          "fields" => [
            {
              "name" => "records", "type" => "rows", "label" => "Records QuickBooks doesn't have", "required" => true,
              "columns" => [
                { "name" => "action", "type" => "string", "required" => true, "label" => "What to do",
                  "enum" => [{ "value" => "create", "label" => "Create it" }, { "value" => "use", "label" => "Use one" }] },
                { "name" => "list_id", "type" => "record", "required" => true, "label" => "Record to use",
                  "kind" => nil, "when" => { "action" => ["use"] } },
                { "name" => "item_type", "type" => "string", "required" => true, "label" => "Item type",
                  "enum" => items, "when" => { "action" => ["create"] } },
                { "name" => "income_account", "type" => "record", "required" => true, "label" => "Income account",
                  "kind" => "account", "when" => { "action" => ["create"] } },
                { "name" => "asset_account", "type" => "record", "required" => true, "label" => "Asset account",
                  "kind" => "account", "when" => { "action" => ["create"], "item_type" => ["item_inventory"] } }
              ],
              "rows" => [
                { "key" => "customer_ref", "label" => "Lone Star Supply", "detail" => "Customer",
                  "columns" => %w[action list_id], "values" => {} },
                { "key" => "invoice_line_add.0.item_ref", "label" => "Vinyl Banner", "detail" => "Item",
                  "columns" => %w[action list_id item_type income_account asset_account], "values" => {} },
                { "key" => "invoice_line_add.1.item_ref", "label" => "Hardware Kit", "detail" => "Item",
                  "columns" => %w[action list_id income_account], "values" => { "item_type" => "item_non_inventory" } }
              ]
            }
          ]
        },
        { "id" => "cancel", "label" => "Cancel", "fields" => [] }
      ]
    }
  end
  let!(:run) do
    make_run(invoice, connection, revision: 6).tap do |r|
      r.update!(state: "awaiting_input", question: question, links: { "decisions" => decisions, "search" => search_url })
    end
  end

  it "shows a block per record: a segmented choice, then only the fields its answers call for, and no table" do
    get "/invoices/#{invoice.id}", headers: signed_in
    page = Nokogiri::HTML(response.body)
    field = page.at_css("[data-qube-rows]")

    expect(field.at_css("table")).to be_nil
    rows = field.css("[data-qube-row][data-qube-values]")
    expect(rows.map { |row| row["data-qube-row"] }).to eq(%w[customer_ref invoice_line_add.0.item_ref invoice_line_add.1.item_ref])
    customer = rows.first
    radios = customer.css(".qube-segmented input[type=radio][name='data[records][customer_ref][action]']")
    expect(radios.map { |r| r["value"] }).to eq(%w[create use])
    expect(radios.map { |r| r["required"] }).to all(be_present)
    expect(customer.at_css(".qube-segmented-field legend").text).to eq("What to do")
    expect(customer.css("[name^='data[records][customer_ref][item_type]']")).to be_empty
    search = customer.at_css(".qube-search")
    expect(search["data-qube-field"]).to eq("records.list_id")
    expect(search["data-qube-row"]).to eq("customer_ref")

    # A field whose "when" doesn't hold: hidden, disabled, not required (required once shown)
    list_id = customer.at_css('[data-qube-col="list_id"]')
    expect(list_id["hidden"]).not_to be_nil
    expect(list_id["data-qube-required"]).not_to be_nil
    expect(list_id.css("input:not([type=hidden])").map { |i| [i["disabled"].nil?, i["required"].nil?] }).to eq([[false, true]])
    expect(list_id.at_css("[data-qube-use-for-all][hidden]")).not_to be_nil
    expect(rows[1].at_css('[data-qube-col="asset_account"]')["data-qube-when"])
      .to eq({ "action" => ["create"], "item_type" => ["item_inventory"] }.to_json)
    expect(rows[1].css('[data-qube-col="item_type"] input[type=radio]').size).to eq(3) # three options: segmented too

    # What a record already has: read-only text, no input
    kit_type = rows[2].at_css('[data-qube-col="item_type"]')
    expect(kit_type.at_css(".qube-row-preset-value").text.strip).to eq("Non-inventory part")
    expect(kit_type.css("input, select")).to be_empty

    set_all = field.at_css("[data-qube-rows-set-all=action]")
    expect(set_all.css("button[data-qube-set-all]").map { |b| [b["data-qube-set-all"], b.text.strip] })
      .to eq([["create", "Create it"], ["use", "Use one"]])
    expect(field.css("[data-qube-rows-pick], [data-qube-rows-all], [data-qube-bulk]")).to be_empty
  end

  it "answers with each row's filled columns, by row key" do
    answered = stub_request(:post, decisions).with(
      body: {
        choice: "proceed",
        data: { records: {
          "customer_ref" => { "action" => "use", "list_id" => "80000001-1" },
          "invoice_line_add.0.item_ref" => { "action" => "create", "item_type" => "item_inventory",
                                             "income_account" => "8000000A-1", "asset_account" => "80000005-1" },
          "invoice_line_add.1.item_ref" => { "action" => "create", "income_account" => "8000000A-1" }
        } }
      }
    ).to_return(json_data("state" => "running"))

    post "/qube/questions/runs/#{run.id}", headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}"), params: {
      choice: "proceed",
      data: { records: {
        "customer_ref" => { "action" => "use", "list_id" => "80000001-1", "item_type" => "item_service" },
        "invoice_line_add.0.item_ref" => { "action" => "create", "list_id" => "", "item_type" => "item_inventory",
                                           "income_account" => "8000000A-1", "asset_account" => "80000005-1" },
        "invoice_line_add.1.item_ref" => { "action" => "create", "income_account" => "8000000A-1" }
      } }
    }

    expect(answered).to have_been_requested
    expect(run.reload.state).to eq("running")
  end

  it "answers a boolean or number column as its type, ticked or not" do
    field = question["choices"][0]["fields"][0]
    field["columns"] += [{ "name" => "taxable", "type" => "boolean", "required" => false, "label" => "Taxable" },
                         { "name" => "price", "type" => "number", "required" => false, "label" => "Price" }]
    field["rows"][1]["columns"] += %w[taxable price]
    field["rows"][2]["columns"] += %w[taxable]
    run.update!(question: question)
    get "/invoices/#{invoice.id}", headers: signed_in
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("input[type=checkbox][name='data[records][invoice_line_add.0.item_ref][taxable]']")).not_to be_nil
    expect(page.at_css("input[type=number][name='data[records][invoice_line_add.0.item_ref][price]']")).not_to be_nil

    answered = stub_request(:post, decisions).with(
      body: { choice: "proceed", data: { records: {
        "customer_ref" => { "action" => "use", "list_id" => "80000001-1" },
        "invoice_line_add.0.item_ref" => { "action" => "use", "list_id" => "80000002-1", "taxable" => true, "price" => 12.5 },
        "invoice_line_add.1.item_ref" => { "action" => "use", "list_id" => "80000003-1", "taxable" => false }
      } } }
    ).to_return(json_data("state" => "running"))

    post "/qube/questions/runs/#{run.id}", headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}"), params: {
      choice: "proceed",
      data: { records: {
        "customer_ref" => { "action" => "use", "list_id" => "80000001-1" },
        "invoice_line_add.0.item_ref" => { "action" => "use", "list_id" => "80000002-1", "taxable" => "true", "price" => "12.5" },
        "invoice_line_add.1.item_ref" => { "action" => "use", "list_id" => "80000003-1" }
      } }
    }

    expect(answered).to have_been_requested
  end

  it "searches a record column for its row" do
    stub_request(:get, "#{search_url}&field=records.list_id&q=lone&row=customer_ref").to_return(json_data([]))

    get "/qube/questions/runs/#{run.id}/search", params: { field: "records.list_id", q: "lone", row: "customer_ref" },
                                                headers: signed_in

    expect(response).to have_http_status(:ok)
  end
end
