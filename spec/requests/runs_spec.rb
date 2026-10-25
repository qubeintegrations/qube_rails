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

  it "answers 409 for a run that isn't starting" do
    run.update!(state: "running")

    post "/qube/runs/#{run.id}/retry_start", headers: signed_in

    expect(response).to have_http_status(:conflict)
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
