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
    expect(status.at_css(".qube-run-summary").text).to eq("Couldn't sync")
    expect(status.at_css(".qube-run-reason").text).to eq("No customer <b>named</b> Riverbend.")
    expect(status.at_css(".qube-run-summary b")).to be_nil # escaped
    expect(status.at_css(".qube-run-error-detail").text).to eq("Add the customer first.")
  end

  it "shows why a retry or an answer didn't go through, once, on the page it came back to" do
    run = make_run(invoice, connection)
    post "/qube/runs/#{run.id}/retry_start",
         headers: { "X-Account" => account.id.to_s, "Referer" => "http://www.example.com/invoices/#{invoice.id}" }
    expect(response).to redirect_to("http://www.example.com/invoices/#{invoice.id}")

    errors = page.css(".qube-error")
    expect(errors.map(&:text)).to eq(["This was already sent, so there's nothing to try again."])
    expect(page.css(".qube-error")).to be_empty # shown once
  end

  it "says the record is in QuickBooks when its link is newer than its failed run, and nothing before it's sent" do
    expect(page.at_css(".qube-run-status")).to be_nil # not sent

    travel_to(1.hour.ago) { make_run(invoice, connection).update!(state: "failed", ended_at: Time.now) }
    connection.link(invoice, kind: "invoice", qb_id: "1F2-1")
    status = page.at_css(".qube-run-status")

    expect(status["data-qube-sync-status"]).to eq("in_quickbooks")
    expect(status.at_css(".qube-run-summary").text).to eq("In QuickBooks")
    expect(status.at_css(".qube-run-error-detail")).to be_nil
  end

  it "offers to send a quiet run's latest news again, and not before" do
    run = make_run(invoice, connection)
    run.update!(qube_run_id: "run-q-1")
    expect(page.at_css("form.qube-redeliver-form")).to be_nil

    run.update_columns(updated_at: 11.minutes.ago)
    form = page.at_css("form.qube-redeliver-form")
    expect(form["action"]).to eq("/qube/runs/#{run.id}/redeliver")
    expect(page.at_css(".qube-run-quiet").text).to eq("No update from QuickBooks for a while.")
  end

  it "shows a completed run without a detail" do
    make_run(invoice, connection).update!(state: "completed", outcome: "added")

    expect(page.at_css(".qube-run-summary").text).to eq("Added to QuickBooks")
    expect(page.at_css(".qube-run-error-detail")).to be_nil
  end

  it "offers to try an unconfirmed start again, and only then" do
    travel_to(2.minutes.ago) { make_run(invoice, connection).update!(state: "starting") }
    button = page.at_css("form.qube-retry-start-form")

    expect(page.at_css(".qube-run-summary").text).to eq("Still waiting for QuickBooks")
    expect(button["action"]).to eq("/qube/runs/#{QubeRails::Run.last.id}/retry_start")
    expect(button.at_css("button.qube-retry-start, input.qube-retry-start")).not_to be_nil

    make_run(invoice, connection).update!(state: "starting") # a younger one, now the latest
    expect(page.at_css(".qube-run-summary").text).to eq("Sending to QuickBooks")
    expect(page.at_css("form.qube-retry-start-form")).to be_nil

    make_run(invoice, connection).update!(state: "running")
    expect(page.at_css("form.qube-retry-start-form")).to be_nil
  end

  it "shows nothing for a record with no runs" do
    expect(page.at_css(".qube-run-status")).to be_nil
  end
end
