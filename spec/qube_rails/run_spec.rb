# frozen_string_literal: true

RSpec.describe QubeRails::Run do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:run) { make_run(invoice, connection) }

  def run_event(name, changes = {})
    QubeRails::WebhookJob.new.perform("run", run.id.to_s, run_body(name, run, changes))
    run.reload
  end

  describe "every ending, kept on the row" do
    it "keeps a completed run's state, outcome and end, before the app's handler runs" do
      seen = nil
      allow_any_instance_of(QuickbooksDesktop::CreateInvoice).to receive(:ended) do |operation, _event|
        seen = [operation.run.state, operation.run.outcome, operation.run.ended_at.nil?]
      end
      run_event("workflow_run.completed", "revision" => 2, "outcome" => "added")

      expect(seen).to eq(["completed", "added", false])
      expect(run).to have_attributes(state: "completed", outcome: "added")
      expect(run.ended_at).not_to be_nil
      expect(run).to be_ended
      expect(run.summary_text).to eq("Added to QuickBooks")
    end

    it "keeps a failed run's error, as the event carried it" do
      run_event("workflow_run.failed", "revision" => 2,
                                       "error" => { "code" => "no_such_customer", "message" => "No customer named Riverbend",
                                                    "detail" => "Add the customer, then start again." })

      expect(run).to be_failed
      expect(run.error).to eq("code" => "no_such_customer", "message" => "No customer named Riverbend",
                              "detail" => "Add the customer, then start again.")
      expect(run.summary_text).to eq("Couldn't sync: No customer named Riverbend")
      expect(run.error_detail).to eq("Add the customer, then start again.")
    end

    it "takes an error that's a sentence" do
      run_event("workflow_run.failed", "revision" => 2)

      expect(run.summary_text).to start_with("Couldn't sync: Five renames were tried")
      expect(run.error_detail).to be_nil
    end

    it "keeps a cancelled run's reason" do
      run_event("workflow_run.cancelled", "revision" => 2)

      expect(run).to be_cancelled
      expect(run.cancel_reason).to eq("The customer was merged in our CRM.")
      expect(run.summary_text).to eq("Cancelled: The customer was merged in our CRM.")
    end

    it "keeps an ending even when the app's handler writes nothing" do
      allow_any_instance_of(QuickbooksDesktop::CreateInvoice).to receive(:failed)
      run_event("workflow_run.failed", "revision" => 2)

      expect(run).to have_attributes(state: "failed", outcome: "renames_exhausted")
    end
  end

  it "says where it stands in a sentence" do
    expect(run.summary_text).to eq("Syncing with QuickBooks")
    run.update!(state: "awaiting_input")
    expect(run.summary_text).to eq("Needs your answer")
    run.update!(state: "completed", outcome: "completed")
    expect(run.summary_text).to eq("Done")
    run.update!(state: "completed", outcome: "used_existing")
    expect(run.summary_text).to eq("Done: Used existing")
    run.update!(state: "failed", outcome: nil, ended_at: nil, error: nil)
    expect(run.summary_text).to eq("Couldn't sync: it couldn't be sent")
    run.update!(state: "cancelled", cancel_reason: nil)
    expect(run.summary_text).to eq("Cancelled")
  end

  it "reads a completed run whose outcome is cancelled as cancelled, not done" do
    run.update!(state: "completed", outcome: "cancelled")

    expect(run).to be_cancelled
    expect(run).to be_ended
    expect(run).not_to be_failed
    expect(run.summary_text).to eq("Cancelled")
    run.update!(cancel_reason: "Merged in the CRM")
    expect(run.summary_text).to eq("Cancelled: Merged in the CRM")
  end

  it "says a start QuBe Sync hasn't confirmed for a minute is unconfirmed, and a younger one is starting" do
    fresh = make_run(invoice, connection).tap { |r| r.update!(state: "starting") }
    expect(fresh.summary_text).to eq("Sending to QuickBooks")
    expect(fresh).not_to be_unconfirmed

    old = travel_to(2.minutes.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "starting") } }
    expect(old.summary_text).to eq("Still waiting for QuickBooks")
    expect(old).to be_unconfirmed
  end
end
