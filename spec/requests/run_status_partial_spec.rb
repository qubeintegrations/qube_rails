# frozen_string_literal: true

RSpec.describe "The run status partial", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }

  def page
    get "/invoices/#{invoice.id}", headers: { "X-Account" => account.id.to_s }
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  it "shows the latest run's summary, and a failure's detail" do
    travel_to(1.hour.ago) { make_run(invoice, connection).update!(state: "completed", outcome: "added") }
    make_run(invoice, connection).update!(
      state: "failed", ended_at: Time.now,
      error: { "message" => "No customer <b>named</b> Riverbend", "detail" => "Add the customer first." }
    )
    status = page.at_css(".qube-run-status")

    expect(status["class"]).to include("qube-run-failed")
    expect(status.at_css(".qube-run-summary").text).to eq("Failed: No customer <b>named</b> Riverbend")
    expect(status.at_css(".qube-run-summary b")).to be_nil # escaped
    expect(status.at_css(".qube-run-error-detail").text).to eq("Add the customer first.")
  end

  it "shows why a retry or an answer didn't go through, once, on the page it came back to" do
    run = make_run(invoice, connection)
    post "/qube/runs/#{run.id}/retry_start",
         headers: { "X-Account" => account.id.to_s, "Referer" => "http://www.example.com/invoices/#{invoice.id}" }
    expect(response).to redirect_to("http://www.example.com/invoices/#{invoice.id}")

    errors = page.css(".qube-error")
    expect(errors.map(&:text)).to eq(["This run isn't waiting for its start to be confirmed."])
    expect(page.css(".qube-error")).to be_empty # shown once
  end

  it "shows a completed run without a detail" do
    make_run(invoice, connection).update!(state: "completed", outcome: "added")

    expect(page.at_css(".qube-run-summary").text).to eq("Added to QuickBooks")
    expect(page.at_css(".qube-run-error-detail")).to be_nil
  end

  it "offers to try an unconfirmed start again, and only then" do
    travel_to(2.minutes.ago) { make_run(invoice, connection).update!(state: "starting") }
    button = page.at_css("form.qube-retry-start-form")

    expect(page.at_css(".qube-run-summary").text).to eq("Not confirmed by QuBe Sync yet")
    expect(button["action"]).to eq("/qube/runs/#{QubeRails::Run.last.id}/retry_start")
    expect(button.at_css("button.qube-retry-start, input.qube-retry-start")).not_to be_nil

    make_run(invoice, connection).update!(state: "starting") # a younger one, now the latest
    expect(page.at_css(".qube-run-summary").text).to eq("Starting")
    expect(page.at_css("form.qube-retry-start-form")).to be_nil

    make_run(invoice, connection).update!(state: "running")
    expect(page.at_css("form.qube-retry-start-form")).to be_nil
  end

  it "shows nothing for a record with no runs" do
    expect(page.at_css(".qube-run-status")).to be_nil
  end
end
