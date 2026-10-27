# frozen_string_literal: true

# The view-models the partials render from: the override contract (README, "Styling").
RSpec.describe "The view-models" do
  let(:prompt) { JSON.parse(vector_body("workflow_run.awaiting_input"))["prompt"] }
  let(:urls) { QubeRails::Storyboard::Urls.new("/answer") }

  def sample(key)
    QubeRails::Storyboard.find(key).sample["prompt"]
  end

  def question(prompt_hash)
    QubeRails::QuestionView.new(prompt_hash, action_url: "/q/1", search_url: "/q/1/search")
  end

  describe QubeRails::QuestionView do
    it "is built from a prompt as QuBe Sync sends it" do
      view = question(prompt)

      expect(view.message).to eq(prompt["message"])
      expect(view.token).to eq("Vq3kT9xRb2LmW8sZ")
      expect(view.details.map { |d| [d.label, d.value] }).to eq([%w[Customer Riverbend]])
      expect(view.choices.map(&:id)).to eq(%w[use:1 use none cancel])
      expect(view.choices.first.detail).to eq("similar name")
      expect(view.choices.first.action_url).to eq("/q/1")
      expect(view.choices.last).to be_secondary

      field = view.choices[1].fields.first
      expect([field.type, field.name, field.input_name, field.dom_id, field.label, field.required])
        .to eq(["search", "list_id", "data[list_id]", "qube-Vq3kT9xRb2LmW8sZ-1-list_id", "The one to use", true])
      expect([field.search_url, field.search_field, field.kind, field.partial])
        .to eq(["/q/1/search", "list_id", "customer", "qube_rails/question/fields/search"])
      expect(field).to be_labelled
    end

    it "comes from a run's open question, with the run's routes, and is nil when it isn't asking" do
      account = Account.create!(name: "Riverbend")
      invoice = Invoice.create!(account: account, number: "1001")
      run = make_run(invoice, make_connection(account))
      routes = QubeRails::Engine.routes.url_helpers

      expect(QubeRails::QuestionView.from_run(run, routes)).to be_nil
      expect(QubeRails::QuestionView.from_run(nil, routes)).to be_nil

      run.update!(question: prompt)
      view = QubeRails::QuestionView.from_run(run, routes, error: "Nope")
      expect(view.action_url).to eq("/qube/questions/runs/#{run.id}")
      expect(view.search_url).to eq("/qube/questions/runs/#{run.id}/search")
      expect(view.error).to eq("Nope")
    end

    it "shows an enum as a select, and number and boolean fields as themselves" do
      select = question(sample("enum_select")).choices.first.fields.first
      expect(select.type).to eq("select")
      expect(select.options.map { |o| [o.value, o.label] }.first).to eq(%w[sales_order Sales\ order])

      fields = question(sample("number_boolean")).choices.first.fields
      expect(fields.map(&:type)).to eq(%w[number boolean])
      expect(fields.map(&:input_name)).to eq(%w[data[quantity] data[allow_negative]])
    end
  end

  describe QubeRails::RowsView do
    let(:rows) { question(sample("rows")).choices.first.fields.first.rows }

    it "has the columns, a row per record, and a cell per column it asks or has a value for" do
      expect(rows.columns.map(&:name)).to eq(%w[action list_id item_type entity_type income_account asset_account cogs_account])
      expect(rows.rows.map(&:key)).to eq(%w[customer_ref invoice_line_add.0.item_ref invoice_line_add.1.item_ref])

      customer = rows.rows.first
      action = customer.cells.first.field
      expect([action.type, action.input_name, action.context, action.data])
        .to eq(["select", "data[records][customer_ref][action]", :cell, { "qube-rows-input" => "" }])
      list_id = customer.cells[1].field
      expect([list_id.type, list_id.search_field, list_id.row_key]).to eq(%w[search records.list_id customer_ref])
      expect(customer.cells.map(&:column)).to eq(%w[action list_id]) # only the columns it asks
      expect(action).to be_segmented # two options
      expect(list_id.dom_id).to eq("qube-data-records-0-list_id")
    end

    it "shows a value the row already has by its label, and hides a cell whose when doesn't hold yet" do
      kit = rows.rows.last
      item_type = kit.cells.find { |c| c.column == "item_type" }

      expect(item_type.preset).to eq("Inventory part")
      expect(item_type).to be_hidden # action isn't create yet
      expect(kit.cells.first).not_to be_hidden
      asset = kit.cells.find { |c| c.column == "asset_account" }
      expect([asset.field.disabled, asset.when_json]).to eq([true, { "action" => ["create"], "item_type" => ["item_inventory"] }.to_json])
    end

    it "sets all by the first short enum column two rows ask, and isn't required while hidden" do
      expect(rows.set_all.name).to eq("action")
      expect(rows.set_all.options.map(&:label)).to eq(["Create it", "Use an existing one"])
      vinyl = rows.rows[1]
      income = vinyl.cells.find { |c| c.column == "income_account" }
      expect([income.hidden?, income.required, income.field.required, income.field.disabled]).to eq([true, true, false, true])
      item_type = vinyl.cells.find { |c| c.column == "item_type" }
      expect(item_type.field).not_to be_segmented # four options: a select
    end
  end

  describe QubeRails::RunStatusView do
    let(:account) { Account.create!(name: "Riverbend") }
    let(:invoice) { Invoice.create!(account: account, number: "1001") }
    let(:connection) { make_connection(account) }
    let(:routes) { QubeRails::Engine.routes.url_helpers }

    def view
      QubeRails::RunStatusView.from_sync(QubeRails::SyncStatus.latest(invoice, operation: "create_invoice"), routes)
    end

    it "says a failure, with its detail" do
      make_run(invoice, connection).update!(state: "failed", ended_at: Time.now,
                                            error: { "message" => "No customer", "detail" => "Add it first." })

      expect([view.status, view.state, view.summary, view.reason, view.detail])
        .to eq([:failed, "failed", "Couldn't sync", "No customer.", "Add it first."])
      expect(view.css_class).to eq("qube-run-status qube-sync-failed qube-run-failed")
      expect([view.retry_url, view.redeliver_url]).to eq([nil, nil])
    end

    it "has the retry URL for an unconfirmed start and the redeliver URL for a quiet run" do
      run = travel_to(2.minutes.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "starting") } }
      expect(view.retry_url).to eq("/qube/runs/#{run.id}/retry_start")

      run.update!(state: "running", qube_run_id: "run-q")
      run.update_columns(updated_at: 11.minutes.ago)
      expect([view.redeliver_url, view.quiet_text]).to eq(["/qube/runs/#{run.id}/redeliver", "No update from QuickBooks for a while."])
    end

    it "says why a run waits on a stalled connection, offers no redelivery, and clears when it resumes" do
      run = make_run(invoice, connection).tap { |r| r.update!(state: "running", qube_run_id: "run-q") }
      run.update_columns(updated_at: 11.minutes.ago) # quiet, but the cause is known
      connection.update!(status: "stalled", stall_reason: "not_checking_in")

      expect([view.stall, view.summary, view.redeliver_url, view.quiet_text])
        .to eq([:not_checking_in, "Waiting for QuickBooks", nil, nil])
      expect(view.stall_text).to start_with("QuickBooks hasn't checked in for a while")
      expect(view.css_class).to include("qube-connection-stalled")
      connection.update!(stall_reason: "quickbooks_unavailable")
      expect(view.stall_text).to start_with("The Web Connector is checking in but can't open QuickBooks")
      connection.update!(stall_reason: "something_new")
      expect([view.stall, view.stall_text]).to eq([:something_new, "Syncing with QuickBooks has stopped for now. " \
                                                                   "Check the computer with QuickBooks and its Web Connector."])

      connection.update!(status: "connected", stall_reason: nil)
      expect([view.stall, view.stall_text, view.summary]).to eq([nil, nil, "Syncing with QuickBooks"])
      expect(view.redeliver_url).to eq("/qube/runs/#{run.id}/redeliver")
    end

    it "leaves a question waiting on the person as it is, stalled or not" do
      make_run(invoice, connection).update!(state: "awaiting_input", question: { "message" => "?" })
      connection.update!(status: "stalled", stall_reason: "not_checking_in")

      expect([view.status, view.stall, view.summary]).to eq([:needs_answer, nil, "Needs your answer"])
    end

    it "takes the connection the page is about" do
      make_run(invoice, connection).update!(state: "running")
      other = QubeRails::Connection.create!(owner: account, status: "stalled", stall_reason: "quickbooks_unavailable")
      sync = QubeRails::SyncStatus.latest(invoice, operation: "create_invoice")

      expect(QubeRails::RunStatusView.from_sync(sync, routes, connection: other).stall).to eq(:quickbooks_unavailable)
      expect(QubeRails::RunStatusView.from_sync(sync, routes).stall).to be_nil
    end

    it "isn't visible before the record is sent" do
      expect(view.visible?).to be(false)
      expect(view.status).to eq(:not_sent)
    end
  end
end
