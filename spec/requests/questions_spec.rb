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
  let(:invoice) do
    Invoice.create!(account: account, number: "1001", qube_reference: "ref", qube_revision: 6,
                    qube_question: question, qube_links: { "decisions" => decisions, "search" => search_url })
  end
  let(:signed_in) { { "X-Account" => account.id.to_s } }

  def answer(params, options = {})
    headers = options.fetch(:headers, signed_in)
    record = options.fetch(:record, invoice)
    post "/qube/questions/create_invoice/#{record.id}", params: params, headers: headers.merge("HTTP_REFERER" => "/invoices/#{record.id}")
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
      expect(invoice.reload.qube_question).to be_nil
    end

    it "sends an unticked checkbox as false, and a number it can't read as typed" do
      answered = stub_request(:post, decisions)
                 .with(body: { choice: "add", data: { count: "three", taxable: false } })
                 .to_return(json_data({}))

      answer(choice: "add", data: { count: "three" })

      expect(answered).to have_been_requested
    end

    it "answers 409 for a choice the question doesn't have" do
      answer(choice: "delete_everything")

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq("This question has changed; reload.")
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "forgets the question and answers 409 when QuBe Sync says it was answered or asked again" do
      stub_request(:post, decisions).to_return(api_error(409, "errors" => { "code" => "prompt_changed" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:conflict)
      expect(invoice.reload.qube_question).to be_nil
    end

    it "forgets the question and answers 409 for a 400 not_awaiting_input" do
      stub_request(:post, decisions).to_return(api_error(400, "errors" => { "code" => "not_awaiting_input" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:conflict)
      expect(invoice.reload.qube_question).to be_nil
    end

    it "keeps the question and says why for a 422" do
      stub_request(:post, decisions)
        .to_return(api_error(422, "errors" => { "detail" => "count must be a whole number" }))

      answer(choice: "add", data: { count: "3" })

      expect(response).to have_http_status(422)
      expect(response.body).to eq("QuBe Sync couldn't take that answer: count must be a whole number")
      expect(invoice.reload.qube_question).to eq(question)
    end

    it "raises for anything else QuBe Sync answers" do
      stub_request(:post, decisions).to_return(api_error(500, "errors" => "boom"))

      expect { answer(choice: "use:1") }.to raise_error(QubeSync::APIError)
    end

    it "refuses every answer, logging why, while authorize_question isn't set" do
      QubeRails.config.authorize_question = nil

      answer(choice: "use:1")

      expect(response).to have_http_status(:forbidden)
      expect(log_output).to include("ERROR QuBe Sync: refused an answer or search for create_invoice #{invoice.id}: " \
                                    "config.authorize_question isn't set in config/initializers/qube_rails.rb")
      expect(a_request(:post, decisions)).not_to have_been_made
      expect(invoice.reload.qube_question).to eq(question)
    end

    it "refuses when authorize_question says no" do
      other = Account.create!(name: "Someone else")

      answer({ choice: "use:1" }, headers: { "X-Account" => other.id.to_s })

      expect(response).to have_http_status(:forbidden)
      expect(log_output).to include("config.authorize_question said no")
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "passes the controller, the record and the slug to authorize_question" do
      seen = nil
      QubeRails.config.authorize_question = lambda do |controller, record, operation|
        seen = [controller.class.name, record, operation]
        false
      end
      answer(choice: "use:1")

      expect(seen).to eq(["QubeRails::QuestionsController", invoice, "create_invoice"])
    end

    it "lets only true through: a truthy answer is refused" do
      QubeRails.config.authorize_question = ->(_controller, record, _operation) { record }
      answer(choice: "use:1")

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:post, decisions)).not_to have_been_made
    end

    it "answers 404 when find_record returns nil" do
      allow(QuickbooksDesktop::CreateInvoice).to receive(:find_record).and_return(nil)
      answer(choice: "use:1")

      expect(response).to have_http_status(:not_found)
    end

    it "forgets the question and answers 409 for any other 400" do
      stub_request(:post, decisions).to_return(api_error(400, "errors" => { "code" => "bad_request" }))

      answer(choice: "use:1")

      expect(response).to have_http_status(:conflict)
      expect(invoice.reload.qube_question).to be_nil
    end

    it "answers 404 for a slug no operation has, the connection's included" do
      post "/qube/questions/connection/#{account.id}", params: { choice: "x" }, headers: signed_in
      expect(response).to have_http_status(:not_found)

      post "/qube/questions/nope/1", params: { choice: "x" }, headers: signed_in
      expect(response).to have_http_status(:not_found)
    end

    it "raises RecordNotFound, which Rails answers 404, for a record that doesn't exist" do
      expect { post "/qube/questions/create_invoice/0", params: { choice: "x" }, headers: signed_in }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "is behind the app's sign-in" do
      answer({ choice: "use:1" }, headers: {})

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /qube/questions/:operation/:record_id/search" do
    def search(q, headers: signed_in)
      get "/qube/questions/create_invoice/#{invoice.id}/search", params: { field: "list_id", q: q }, headers: headers
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

      get "/qube/questions/create_invoice/#{invoice.id}/search", params: { field: "", q: "river" }, headers: signed_in
      expect(JSON.parse(response.body)).to eq([])

      get "/qube/questions/create_invoice/#{invoice.id}/search", params: { field: "f" * 101, q: "river" },
                                                                 headers: signed_in
      expect(JSON.parse(response.body)).to eq([])
      expect(response).to have_http_status(:ok)

      expect(a_request(:get, /search/)).not_to have_been_made
    end

    it "answers 409 when the question has no search link" do
      invoice.update_columns(qube_links: { "decisions" => decisions })

      search("river")

      expect(response).to have_http_status(:conflict)
    end

    it "passes QuBe Sync's 4xx on, with no matches" do
      stub_request(:get, /search/).to_return(api_error(409, "errors" => { "code" => "prompt_changed" }))

      search("river")

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)).to eq([])
    end

    it "refuses every search while authorize_question isn't set" do
      QubeRails.config.authorize_question = nil

      search("river")

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq([])
      expect(a_request(:get, /search/)).not_to have_been_made
    end
  end
end
