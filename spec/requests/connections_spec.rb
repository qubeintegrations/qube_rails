# frozen_string_literal: true

RSpec.describe "POST /quickbooks/connect", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:onboarding) { "https://qube.example/onboard/abc" }
  let(:webhook_url) { "https://app.example/webhooks/qube/connection/#{account.id}" }

  it "creates a connection for an account without one, saves its id, and sends them to onboarding" do
    created = stub_request(:post, api_url("/connections"))
              .with(body: { webhook_url: webhook_url })
              .to_return(json_data("id" => "conn-1", "links" => { "onboarding" => onboarding }))

    post "/quickbooks/connect", headers: { "X-Account" => account.id.to_s }

    expect(created).to have_been_requested
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(onboarding)
    expect(account.reload.qube_connection_id).to eq("conn-1")
  end

  it "reuses a saved connection: its webhook URL brought up to date, with a fresh link" do
    account.update_columns(qube_connection_id: "conn-1", qube_connection_revision: 3)
    updated = stub_request(:put, api_url("/connections/conn-1"))
              .with(body: { webhook_url: webhook_url })
              .to_return(json_data("id" => "conn-1"))
    regenerated = stub_request(:post, api_url("/connections/conn-1/onboarding-url"))
                  .to_return(json_data("id" => "conn-1", "links" => { "onboarding" => onboarding }))

    post "/quickbooks/connect", headers: { "X-Account" => account.id.to_s }

    expect(updated).to have_been_requested
    expect(regenerated).to have_been_requested
    expect(a_request(:post, api_url("/connections"))).not_to have_been_made
    expect(response).to redirect_to(onboarding)
    expect(account.reload.qube_connection_revision).to eq(3)
  end

  it "is behind the app's sign-in" do
    post "/quickbooks/connect"

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers 401 when current_account finds no account" do
    QubeRails.config.current_account = ->(_controller) { nil }
    post "/quickbooks/connect", headers: { "X-Account" => account.id.to_s }

    expect(response).to have_http_status(:unauthorized)
    expect(log_output).to include("config.current_account found no signed-in account")
  end

  it "raises naming the initializer when current_account isn't set" do
    QubeRails.config.current_account = nil

    expect { post "/quickbooks/connect", headers: { "X-Account" => account.id.to_s } }
      .to raise_error(QubeRails::NotConfigured, %r{current_account.*config/initializers/qube_rails\.rb})
  end
end
