# frozen_string_literal: true

RSpec.describe "POST /qube/runs/:id/retry_start", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:signed_in) { { "X-Account" => account.id.to_s, "HTTP_REFERER" => "/invoices/#{invoice.id}" } }
  let(:run) do
    travel_to(2.minutes.ago) do
      make_run(invoice, connection).tap { |r| r.update!(state: "starting", input: { "operation" => "invoice.create" }) }
    end
  end
  let(:start_url) { api_url("/connections/#{connection.qube_id}/workflow-runs") }

  it "resends the start with its reference, keeps QuBe Sync's answer and goes back with 303" do
    replayed = stub_request(:post, start_url)
               .with(headers: { "Idempotency-Key" => run.reference })
               .to_return(json_data("id" => "run-q-1", "state" => "running"))

    post "/qube/runs/#{run.id}/retry_start", headers: signed_in

    expect(replayed).to have_been_requested
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to("/invoices/#{invoice.id}")
    expect(run.reload).to have_attributes(qube_run_id: "run-q-1", state: "running")
  end

  it "goes back with the run failed when QuBe Sync refuses it, or still unconfirmed when there's no answer" do
    stub_request(:post, start_url).to_timeout
    post "/qube/runs/#{run.id}/retry_start", headers: signed_in
    expect(response).to have_http_status(:see_other)
    expect(run.reload.state).to eq("starting")

    stub_request(:post, start_url).to_return(status: 422, body: { errors: { detail: "bad" } }.to_json)
    post "/qube/runs/#{run.id}/retry_start", headers: signed_in
    expect(response).to have_http_status(:see_other)
    expect(run.reload.state).to eq("failed")
  end

  it "sends them back saying why, for a run that isn't starting" do
    run.update!(state: "running")

    post "/qube/runs/#{run.id}/retry_start", headers: signed_in

    expect(response).to have_http_status(:see_other)
    expect(flash[:qube_rails_error]).to eq("This was already sent, so there's nothing to try again.")
    expect(a_request(:post, start_url)).not_to have_been_made
  end

  it "answers 404 for another account's run, logged, and sends nothing" do
    other = Account.create!(name: "Someone else")

    post "/qube/runs/#{run.id}/retry_start", headers: { "X-Account" => other.id.to_s }

    expect(response).to have_http_status(:not_found)
    expect(log_output).to include("refused a start retry for run #{run.id}")
    expect(a_request(:post, start_url)).not_to have_been_made
  end

  it "answers 404 for a run that isn't there" do
    post "/qube/runs/0/retry_start", headers: signed_in

    expect(response).to have_http_status(:not_found)
  end

  it "is behind the app's sign-in" do
    post "/qube/runs/#{run.id}/retry_start"

    expect(response).to have_http_status(:unauthorized)
  end
end

RSpec.describe "POST /qube/runs/:id/redeliver", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:signed_in) { { "X-Account" => account.id.to_s, "HTTP_REFERER" => "/invoices/#{invoice.id}" } }
  let(:redeliver_url) { api_url("/connections/#{connection.qube_id}/workflow-runs/run-q-1/redeliver") }

  def quiet_run(state: "running", question: nil)
    travel_to(11.minutes.ago) do
      make_run(invoice, connection).tap { |r| r.update!(state: state, qube_run_id: "run-q-1", question: question) }
    end
  end

  it "asks QuBe Sync to send a quiet run's latest event again, and goes back" do
    run = quiet_run
    asked = stub_request(:post, redeliver_url)
            .to_return(json_data("run_id" => "run-q-1", "event" => "workflow_run.awaiting_input", "revision" => 4))

    post "/qube/runs/#{run.id}/redeliver", headers: signed_in

    expect(asked).to have_been_requested
    expect(response).to redirect_to("/invoices/#{invoice.id}")
    expect(flash[:qube_rails_error]).to be_nil
  end

  it "asks for a run waiting on a question this app never got" do
    run = quiet_run(state: "awaiting_input")
    stub_request(:post, redeliver_url).to_return(json_data({}))

    post "/qube/runs/#{run.id}/redeliver", headers: signed_in

    expect(a_request(:post, redeliver_url)).to have_been_made
  end

  it "asks for nothing on a run heard from lately, or one that ended" do
    run = make_run(invoice, connection)
    run.update!(qube_run_id: "run-q-1")
    post "/qube/runs/#{run.id}/redeliver", headers: signed_in
    expect(flash[:qube_rails_error]).to eq(QubeRails.t(QubeRails::RunsController::NOT_QUIET))

    ended = quiet_run(state: "completed")
    post "/qube/runs/#{ended.id}/redeliver", headers: signed_in
    expect(a_request(:post, /redeliver/)).not_to have_been_made
  end

  it "says why when QuBe Sync has nothing to send, or was asked too recently" do
    run = quiet_run
    stub_request(:post, redeliver_url).to_return(status: 409, body: { errors: { code: "nothing_to_redeliver" } }.to_json)
    post "/qube/runs/#{run.id}/redeliver", headers: signed_in
    expect(flash[:qube_rails_error]).to eq("There's no update yet. Check again in a few minutes.")

    stub_request(:post, redeliver_url).to_return(status: 429, body: "{}")
    post "/qube/runs/#{run.id}/redeliver", headers: signed_in
    expect(flash[:qube_rails_error]).to eq("That was checked a moment ago. Try again in a minute.")
  end

  it "answers 404 for a run another account's user can't act on" do
    run = quiet_run
    other = Account.create!(name: "Other")

    post "/qube/runs/#{run.id}/redeliver", headers: { "X-Account" => other.id.to_s }

    expect(response).to have_http_status(:not_found)
  end
end
