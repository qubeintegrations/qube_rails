# frozen_string_literal: true

RSpec.describe "The question routes", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:decisions) { "https://qube.example/api/v2/connections/c/workflow-runs/r/decisions?prompt_token=tok" }
  let(:search_url) { "https://qube.example/api/v2/connections/c/workflow-runs/r/search?prompt_token=tok" }
  let(:question) do
    {
      "token" => "tok",
      "message" => "Which customer?",
      "choices" => [
        { "id" => "use:1", "label" => "Riverbend Electric", "fields" => [] },
        {
          "id" => "add",
          "label" => "Add it",
          "fields" => [
            { "name" => "name", "type" => "text" },
            { "name" => "count", "type" => "number" },
            { "name" => "rate", "type" => "number" },
            { "name" => "taxable", "type" => "boolean" },
            { "name" => "note", "type" => "text" }
          ]
        }
      ]
    }
  end
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:connection) { make_connection(account) }
  let(:run) do
    make_run(invoice, connection, revision: 6).tap do |r|
      r.update!(question: question, links: { "decisions" => decisions, "search" => search_url })
    end
  end
  let(:signed_in) { { "X-Account" => account.id.to_s } }

  def answer(params, options = {})
    headers = options.fetch(:headers, signed_in)
    target = options.fetch(:run, run)
    post "/qube/questions/runs/#{target.id}", params: params, headers: headers.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
  end

  def api_error(status, body)
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end

  describe "POST /qube/questions/:operation/:record_id" do
    it "posts the choice with its fields as their types, forgets the question and goes back" do
      answered = stub_request(:post, decisions)
                 .with(body: { choice: "add", data: { name: "Lone Star", count: 3, rate: 1.5, taxable: true } })
                 .to_return(json_data("state" => "running"))

      answer(choice: "add", data: { name: " Lone Star ", count: "3", rate: "1.5", taxable: "true", note: "" })

      expect(answered).to have_been_requested
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/invoices/#{invoice.id}")
      expect(run.reload.question).to be_nil
    end

    it "sends an unticked checkbox as false, and a number it can't read as typed" do
      answered = stub_request(:post, decisions)
                 .with(body: { choice: "add", data: { count: "three", taxable: false } })
                 .to_return(json_data({}))

      answer(choice: "add", data: { count: "three" })

      expect(answered).to have_been_requested
    end

    it "sends them back saying it changed, for a choice the question doesn't have" do
      answer(choice: "delete_everything")

      expect(response).to have_http_status(:see_other)
      expect(flash[:qube_rails_error]).to eq("This question changed since the page showed it, so that answer was not sent: the page now shows where it stands.")
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "forgets the question and says it changed when QuBe Sync says it was answered or asked again" do
      stub_request(:post, decisions).to_return(api_error(409, "errors" => { "code" => "prompt_changed" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:see_other)
      expect(flash[:qube_rails_error]).to eq("This question changed since the page showed it, so that answer was not sent: the page now shows where it stands.")
      expect(run.reload.question).to be_nil
    end

    it "forgets the question and says it changed for a 400 not_awaiting_input" do
      stub_request(:post, decisions).to_return(api_error(400, "errors" => { "code" => "not_awaiting_input" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:see_other)
      expect(run.reload.question).to be_nil
    end

    it "keeps the question and says why for a 422" do
      stub_request(:post, decisions)
        .to_return(api_error(422, "errors" => { "detail" => "count must be a whole number" }))

      answer(choice: "add", data: { count: "3" })

      expect(response).to have_http_status(:see_other)
      expect(flash[:qube_rails_error]).to eq("QuBe Sync couldn't take that answer: count must be a whole number")
      expect(run.reload.question).to eq(question)
    end

    it "raises for anything else QuBe Sync answers" do
      stub_request(:post, decisions).to_return(api_error(500, "errors" => "boom"))

      expect { answer(choice: "use:1") }.to raise_error(QubeSync::APIError)
    end

    it "by default lets the account that owns the run's connection answer" do
      stub_request(:post, decisions).to_return(json_data({}))

      answer(choice: "use:1")

      expect(response).to have_http_status(:see_other)
    end

    it "by default refuses when current_account finds no account" do
      QubeRails.config.current_account = ->(_controller) { nil }

      answer(choice: "use:1")

      expect(response).to have_http_status(:not_found)
    end

    it "by default compares the owner by type and id, so an unsaved account never matches" do
      QubeRails.config.current_account = ->(_controller) { Account.new(name: "Unsaved") }

      answer(choice: "use:1")

      expect(response).to have_http_status(:not_found)
    end

    it "uses an authorize_question the app sets in place of the default" do
      other = Account.create!(name: "Staff account")
      QubeRails.config.authorize_question = ->(_controller, record, _run) { record.number == "1001" }
      stub_request(:post, decisions).to_return(json_data({}))

      answer({ choice: "use:1" }, headers: { "X-Account" => other.id.to_s })

      expect(response).to have_http_status(:see_other)
    end

    it "by default answers 404 for another account's run, logged, so its existence doesn't show" do
      other = Account.create!(name: "Someone else")

      answer({ choice: "use:1" }, headers: { "X-Account" => other.id.to_s })

      expect(response).to have_http_status(:not_found)
      expect(log_output).to include("config.authorize_question said no")
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "passes the controller, the record and the run to authorize_question" do
      seen = nil
      QubeRails.config.authorize_question = lambda do |controller, record, asked|
        seen = [controller.class.name, record, asked]
        false
      end
      answer(choice: "use:1")

      expect(seen).to eq(["QubeRails::QuestionsController", invoice, run])
    end

    it "lets only true through: a truthy answer is refused" do
      QubeRails.config.authorize_question = ->(_controller, record, _run) { record }
      answer(choice: "use:1")

      expect(response).to have_http_status(:not_found)
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "answers 404 when find_record returns nil" do
      allow(QuickbooksDesktop::CreateInvoice).to receive(:find_record).and_return(nil)
      answer(choice: "use:1")

      expect(response).to have_http_status(:not_found)
    end

    it "sends them back saying it changed, for a run that has stopped asking" do
      run.update!(question: nil, links: nil)
      answer(choice: "use:1")

      expect(response).to have_http_status(:see_other)
      expect(flash[:qube_rails_error]).to eq("This question changed since the page showed it, so that answer was not sent: the page now shows where it stands.")
    end

    it "forgets the question and says it changed for any other 400" do
      stub_request(:post, decisions).to_return(api_error(400, "errors" => { "code" => "bad_request" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:see_other)
      expect(run.reload.question).to be_nil
    end

    it "answers 404 for a run that isn't there, or whose operation isn't configured" do
      post "/qube/questions/runs/0", params: { choice: "x" }, headers: signed_in
      expect(response).to have_http_status(:not_found)

      QubeRails.config.operations = { "sync_customer" => "QuickbooksDesktop::SyncCustomer" }
      answer(choice: "use:1")
      expect(response).to have_http_status(:not_found)
    end

    it "has no route for the old /:operation/:record_id URLs" do
      expect { post "/qube/questions/create_invoice/#{invoice.id}", params: { choice: "x" }, headers: signed_in }
        .to raise_error(ActionController::RoutingError)
    end

    it "is behind the app's sign-in" do
      answer({ choice: "use:1" }, headers: {})

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /qube/questions/:operation/:record_id/search" do
    def search(q, headers: signed_in)
      get "/qube/questions/runs/#{run.id}/search", params: { field: "list_id", q: q }, headers: headers
    end

    it "returns the matches from the question's links.search" do
      matches = [{ "value" => "80000001-1", "label" => "Riverbend Electric", "detail" => nil }]
      stub_request(:get, "#{search_url}&field=list_id&q=river").to_return(json_data(matches))

      search(" river ")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(matches)
    end

    it "asks nothing for fewer than 2 or more than 100 characters" do
      search("r")
      expect(JSON.parse(response.body)).to eq([])

      search("r" * 101)
      expect(JSON.parse(response.body)).to eq([])
      expect(response).to have_http_status(:ok)

      get "/qube/questions/runs/#{run.id}/search", params: { field: "", q: "river" }, headers: signed_in
      expect(JSON.parse(response.body)).to eq([])

      get "/qube/questions/runs/#{run.id}/search", params: { field: "f" * 101, q: "river" },
                                                                 headers: signed_in
      expect(JSON.parse(response.body)).to eq([])
      expect(response).to have_http_status(:ok)

      expect(a_request(:get, /search/)).not_to have_been_made
    end

    it "answers 409 when the question has no search link" do
      run.update!(links: { "decisions" => decisions })

      search("river")

      expect(response).to have_http_status(:conflict)
    end

    it "passes QuBe Sync's 4xx on, with no matches" do
      stub_request(:get, /search/).to_return(api_error(409, "errors" => { "code" => "prompt_changed" }))

      search("river")

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)).to eq([])
    end

    it "answers [] with 404 when authorize_question says no" do
      QubeRails.config.authorize_question = ->(_controller, _record, _run) { false }

      search("river")

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq([])
      expect(a_request(:get, /search/)).not_to have_been_made
    end

    it "by default answers [] with 404 for another account's run" do
      other = Account.create!(name: "Someone else")

      search("river", headers: { "X-Account" => other.id.to_s })

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq([])
      expect(a_request(:get, /search/)).not_to have_been_made
    end
  end
end
