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

  it "shows a table: a row per record, the columns it asks, a search per record column and a bulk bar" do
    get "/invoices/#{invoice.id}", headers: signed_in
    page = Nokogiri::HTML(response.body)
    table = page.at_css(".qube-rows table")

    rows = table.css("tbody tr[data-qube-row]")
    expect(rows.map { |row| row["data-qube-row"] }).to eq(%w[customer_ref invoice_line_add.0.item_ref invoice_line_add.1.item_ref])
    customer = rows.first
    expect(customer.css("select[name='data[records][customer_ref][action]']").size).to eq(1)
    expect(customer.css("[name^='data[records][customer_ref][item_type]']")).to be_empty
    search = customer.at_css(".qube-search")
    expect(search["data-qube-field"]).to eq("records.list_id")
    expect(search["data-qube-row"]).to eq("customer_ref")
    expect(rows[1].at_css('td[data-qube-col="asset_account"]')["data-qube-when"])
      .to eq({ "action" => ["create"], "item_type" => ["item_inventory"] }.to_json)
    expect(rows[2].at_css('td[data-qube-col="item_type"]').text.strip).to eq("Non-inventory part")
    expect(table.css(".qube-rows-bulk [data-qube-bulk='income_account'] .qube-bulk-apply").size).to eq(1)
    expect(table.css(".qube-rows-bulk [data-qube-bulk='list_id'] .qube-bulk-apply")).to be_empty
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

  it "searches a record column for its row" do
    stub_request(:get, "#{search_url}&field=records.list_id&q=lone&row=customer_ref").to_return(json_data([]))

    get "/qube/questions/runs/#{run.id}/search", params: { field: "records.list_id", q: "lone", row: "customer_ref" },
                                                headers: signed_in

    expect(response).to have_http_status(:ok)
  end
end
