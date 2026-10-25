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

  it "shows a completed run without a detail" do
    make_run(invoice, connection).update!(state: "completed", outcome: "added")

    expect(page.at_css(".qube-run-summary").text).to eq("Added to QuickBooks")
    expect(page.at_css(".qube-run-error-detail")).to be_nil
  end

  it "shows nothing for a record with no runs" do
    expect(page.at_css(".qube-run-status")).to be_nil
  end
end
