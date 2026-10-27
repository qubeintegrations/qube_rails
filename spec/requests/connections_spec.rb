# frozen_string_literal: true

RSpec.describe "Onboarding", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:signed_in) { { "X-Account" => account.id.to_s } }
  let(:onboarding) { "https://qube.example/onboard/abc" }

  describe "POST /quickbooks/connections" do
    it "writes a connection row, makes QuBe Sync's with the row's webhook URL, and sends them to setup" do
      created = stub_request(:post, api_url("/connections"))
                .with { |req| JSON.parse(req.body)["webhook_url"] =~ %r{\Ahttps://app\.example/webhooks/qube/connections/\d+\z} }
                .to_return(json_data("id" => "conn-q-1", "links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections", params: { name: " Main file " }, headers: signed_in

      connection = QubeRails::Connection.last
      expect(created).to have_been_requested
      expect(a_request(:post, api_url("/connections"))
        .with(body: { webhook_url: connection.webhook_url, name: "Main file" })).to have_been_made
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(onboarding)
      expect(connection).to have_attributes(owner: account, qube_id: "conn-q-1", status: "pending", name: "Main file")
    end

    it "makes a new connection when the account's only one is connected" do
      make_connection(account)
      stub_request(:post, api_url("/connections"))
        .to_return(json_data("id" => "conn-q-2", "links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections", headers: signed_in

      expect(QubeRails::Connection.owned_by(account).pluck(:qube_id))
        .to contain_exactly(QubeRailsHelpers::QUBE_ID, "conn-q-2")
    end

    it "sends the newest connection that never connected back through setup, rather than making another" do
      travel_to(1.hour.ago) { make_connection(account, qube_id: "conn-q-old", status: "pending") }
      cancelled = make_connection(account, qube_id: "conn-q-new", status: "setup_cancelled")
      stub_request(:put, api_url("/connections/conn-q-new")).to_return(json_data({}))
      stub_request(:post, api_url("/connections/conn-q-new/onboarding-url"))
        .to_return(json_data("links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections", headers: signed_in

      expect(response).to redirect_to(onboarding)
      expect(QubeRails::Connection.count).to eq(2)
      expect(a_request(:post, api_url("/connections"))).not_to have_been_made
      expect(cancelled.reload.qube_id).to eq("conn-q-new")
    end

    it "makes another with new=1, for a second company file" do
      make_connection(account, qube_id: "conn-q-pending", status: "pending")
      stub_request(:post, api_url("/connections"))
        .to_return(json_data("id" => "conn-q-2", "links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections", params: { new: "1" }, headers: signed_in

      expect(QubeRails::Connection.owned_by(account).count).to eq(2)
    end

    it "leaves the row without a qube_id when QuBe Sync doesn't answer, and the next click picks it up" do
      stub_request(:post, api_url("/connections")).to_return(status: 500, body: "")

      expect { post "/quickbooks/connections", headers: signed_in }.to raise_error(QubeSync::APIError)
      row = QubeRails::Connection.last
      expect(row).to have_attributes(qube_id: nil, status: "pending")

      stub_request(:get, api_url("/connections")).to_return(json_data([]))
      stub_request(:post, api_url("/connections"))
        .to_return(json_data("id" => "conn-q-1", "links" => { "onboarding" => onboarding }))
      post "/quickbooks/connections", headers: signed_in

      expect(QubeRails::Connection.count).to eq(1)
      expect(row.reload.qube_id).to eq("conn-q-1")
    end

    it "adopts a connection whose create landed but whose id was never saved, making no second one" do
      row = make_connection(account, qube_id: nil, status: "pending")
      stub_request(:get, api_url("/connections"))
        .to_return(json_data([qube_connection_for(row)]))
      stub_request(:put, api_url("/connections/conn-q-lost")).to_return(json_data({}))
      stub_request(:post, api_url("/connections/conn-q-lost/onboarding-url"))
        .to_return(json_data("links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections", headers: signed_in

      expect(row.reload.qube_id).to eq("conn-q-lost")
      expect(a_request(:post, api_url("/connections"))).not_to have_been_made
      expect(response).to redirect_to(onboarding)
    end

    it "is behind the app's sign-in" do
      post "/quickbooks/connections"

      expect(response).to have_http_status(:unauthorized)
      expect(QubeRails::Connection.count).to eq(0)
    end

    it "answers 401 when current_account finds no account" do
      QubeRails.config.current_account = ->(_controller) { nil }
      post "/quickbooks/connections", headers: signed_in

      expect(response).to have_http_status(:unauthorized)
      expect(log_output).to include("config.current_account found no signed-in account")
    end

    it "raises naming the initializer when current_account isn't set" do
      QubeRails.config.current_account = nil

      expect { post "/quickbooks/connections", headers: signed_in }
        .to raise_error(QubeRails::NotConfigured, %r{current_account.*config/initializers/qube_rails\.rb})
    end

    it "with simulated=1, makes a new row and a simulated connection for it, and goes back to the page" do
      make_connection(account, qube_id: "conn-q-pending", status: "pending")
      created = stub_request(:post, api_url("/connections"))
                .with { |req| JSON.parse(req.body)["type"] == "simulated" }
                .to_return(json_data("id" => "conn-q-sim", "type" => "simulated"))

      post "/quickbooks/connections", params: { simulated: "1", name: "Test file" },
                                      headers: signed_in.merge("Referer" => "http://www.example.com/account")

      row = QubeRails::Connection.find_by(qube_id: "conn-q-sim")
      expect(created).to have_been_requested
      expect(a_request(:post, api_url("/connections"))
        .with(body: { webhook_url: row.webhook_url, name: "Test file", type: "simulated" })).to have_been_made
      expect(row).to have_attributes(owner: account, status: "pending", name: "Test file")
      expect(response).to redirect_to("http://www.example.com/account")
    end

    it "refuses simulated=1 in production, making nothing" do
      allow(Rails.env).to receive(:production?).and_return(true)

      post "/quickbooks/connections", params: { simulated: "1" }, headers: signed_in

      expect(response).to have_http_status(:not_found)
      expect(QubeRails::Connection.count).to eq(0)
      expect(a_request(:post, api_url("/connections"))).not_to have_been_made
    end
  end

  describe "POST /quickbooks/connections/:id/onboarding" do
    let!(:connection) { make_connection(account) }

    it "brings the connection's webhook URL up to date and sends them back through setup" do
      updated = stub_request(:put, api_url("/connections/#{connection.qube_id}"))
                .with(body: { webhook_url: connection.webhook_url })
                .to_return(json_data("id" => connection.qube_id))
      regenerated = stub_request(:post, api_url("/connections/#{connection.qube_id}/onboarding-url"))
                    .to_return(json_data("links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections/#{connection.id}/onboarding", headers: signed_in

      expect(updated).to have_been_requested
      expect(regenerated).to have_been_requested
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(onboarding)
    end

    it "makes QuBe Sync's connection for a row left without one" do
      connection.update!(qube_id: nil)
      stub_request(:get, api_url("/connections")).to_return(json_data([]))
      stub_request(:post, api_url("/connections"))
        .to_return(json_data("id" => "conn-q-9", "links" => { "onboarding" => onboarding }))

      post "/quickbooks/connections/#{connection.id}/onboarding", headers: signed_in

      expect(connection.reload.qube_id).to eq("conn-q-9")
      expect(response).to redirect_to(onboarding)
    end

    it "answers 404 for another account's connection, and asks QuBe Sync nothing" do
      other = Account.create!(name: "Someone else")

      post "/quickbooks/connections/#{connection.id}/onboarding", headers: { "X-Account" => other.id.to_s }

      expect(response).to have_http_status(:not_found)
      expect(a_request(:any, /qube\.example/)).not_to have_been_made
    end

    it "answers 404 for a connection that isn't there" do
      post "/quickbooks/connections/0/onboarding", headers: signed_in

      expect(response).to have_http_status(:not_found)
    end

    it "is behind the app's sign-in" do
      post "/quickbooks/connections/#{connection.id}/onboarding"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /quickbooks/connections/:id" do
    let(:invoice) { Invoice.create!(number: "1001", account: account) }

    it "deletes QuBe Sync's connection, then the row with its runs and links" do
      connection = make_connection(account)
      run = make_run(invoice, connection)
      run.update!(state: "completed")
      connection.link(invoice, kind: "invoice", qb_id: "TXN-1")
      deleted = stub_request(:delete, api_url("/connections/#{connection.qube_id}")).to_return(status: 204)

      delete "/quickbooks/connections/#{connection.id}", headers: signed_in

      expect(deleted).to have_been_requested
      expect(response).to have_http_status(:see_other)
      expect(QubeRails::Connection.exists?(connection.id)).to be(false)
      expect(QubeRails::Run.exists?(run.id)).to be(false)
      expect(QubeRails::QuickbooksRecord.where(connection_id: connection.id)).to be_empty
    end

    it "tells the app's ConnectionEvents first, inside the delete" do
      connection = make_connection(account)
      stub_request(:delete, api_url("/connections/#{connection.qube_id}")).to_return(status: 204)
      seen = nil
      allow_any_instance_of(QuickbooksDesktop::ConnectionEvents).to receive(:disconnected) do |events|
        seen = QubeRails::Connection.exists?(events.connection.id)
      end

      delete "/quickbooks/connections/#{connection.id}", headers: signed_in

      expect(seen).to be(true)
      expect(QubeRails::Connection.exists?(connection.id)).to be(false)
    end

    it "takes one QuBe Sync already deleted, and one it never made" do
      gone = make_connection(account, qube_id: "conn-q-gone")
      stub_request(:delete, api_url("/connections/conn-q-gone")).to_return(status: 404, body: "{}")
      never = make_connection(account, qube_id: nil, status: "pending")

      delete "/quickbooks/connections/#{gone.id}", headers: signed_in
      delete "/quickbooks/connections/#{never.id}", headers: signed_in

      expect(QubeRails::Connection.where(id: [gone.id, never.id])).to be_empty
    end

    it "is refused while a run hasn't ended, and when QuBe Sync doesn't answer" do
      connection = make_connection(account)
      run = make_run(invoice, connection)

      delete "/quickbooks/connections/#{connection.id}", headers: signed_in, env: { "HTTP_REFERER" => "/account" }

      expect(response).to redirect_to("/account")
      expect(flash[:qube_rails_error]).to eq(QubeRails::ConnectionsController::RUNS_GOING)
      expect(a_request(:delete, api_url("/connections/#{connection.qube_id}"))).not_to have_been_made
      get "/account", headers: signed_in
      expect(response.body.scan(QubeRails::ConnectionsController::RUNS_GOING.gsub("'", "&#39;")).size).to eq(1)
      get "/account", headers: signed_in
      expect(response.body).not_to include("qube-error")

      run.update!(state: "failed")
      stub_request(:delete, api_url("/connections/#{connection.qube_id}")).to_timeout
      delete "/quickbooks/connections/#{connection.id}", headers: signed_in

      expect(flash[:qube_rails_error]).to eq(QubeRails::ConnectionsController::NO_ANSWER)
      expect(QubeRails::Connection.exists?(connection.id)).to be(true)
    end

    it "is refused while a request hasn't ended" do
      connection = make_connection(account)
      QubeRails::QueuedRequest.create!(connection: connection, operation: "find_customer", record: invoice,
                                       reference: "find_customer-1-x", state: "retryable")

      delete "/quickbooks/connections/#{connection.id}", headers: signed_in

      expect(flash[:qube_rails_error]).to eq(QubeRails::ConnectionsController::RUNS_GOING)
      expect(QubeRails::Connection.exists?(connection.id)).to be(true)
    end

    it "answers 404 for another account's connection" do
      other = make_connection(Account.create!(name: "Other"))

      delete "/quickbooks/connections/#{other.id}", headers: signed_in

      expect(response).to have_http_status(:not_found)
      expect(QubeRails::Connection.exists?(other.id)).to be(true)
    end
  end
end
