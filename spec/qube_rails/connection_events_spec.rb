# frozen_string_literal: true

RSpec.describe QubeRails::ConnectionEvents do
  let(:connection_id) { "0196a1c0-0000-7000-8000-00000000c001" }
  let(:account) { Account.create!(name: "Riverbend", qube_connection_id: connection_id) }

  def run_event(name, changes = {})
    QubeRails::WebhookJob.perform_now("connection", account.id.to_s, vector_body(name, changes))
    account.reload
  end

  it "hands each of the four events to its handler, and saves the revision" do
    run_event("connection.connected")
    run_event("connection.setup_cancelled")
    run_event("connection.stalled")
    run_event("connection.resumed")

    expect(QuickbooksDesktop::Connection.calls)
      .to eq([[:connected, 1], [:setup_cancelled, 2], [:stalled, "not_checking_in"], [:resumed, 4]])
    expect(account.qube_connection_revision).to eq(4)
  end

  it "skips an event for a connection that isn't the one saved on the account" do
    run_event("connection.connected", "connection" => { "id" => "someone-elses" })

    expect(QuickbooksDesktop::Connection.calls).to be_empty
    expect(account.qube_connection_revision).to be_nil
    expect(log_output).to include("account #{account.id} skipped connection.connected for \"someone-elses\": " \
                                  "not its connection")
  end

  it "skips everything before a connection is saved" do
    account.update_columns(qube_connection_id: nil)
    run_event("connection.connected")

    expect(QuickbooksDesktop::Connection.calls).to be_empty
  end

  it "skips an event that isn't a connection's" do
    run_event("workflow_run.completed")

    expect(QuickbooksDesktop::Connection.calls).to be_empty
    expect(log_output).to include("skipped workflow_run.completed for nil: not its connection")
  end

  it "applies an event only when it's newer than the last applied" do
    run_event("connection.resumed") # revision 4
    run_event("connection.stalled") # revision 3, a retry that came late

    expect(QuickbooksDesktop::Connection.calls).to eq([[:resumed, 4]])
    expect(account.qube_connection_revision).to eq(4)
  end

  it "forgets the last connection's revision when a new connection id is saved" do
    account.update_columns(qube_connection_revision: 12)
    QuickbooksDesktop::Connection.new(account).save_connection_id("conn-2")

    expect(account.reload.qube_connection_id).to eq("conn-2")
    expect(account.qube_connection_revision).to be_nil
  end

  it "builds the account's webhook URL from the webhook_url setting" do
    expect(QuickbooksDesktop::Connection.new(account).webhook_url)
      .to eq("https://app.example/webhooks/qube/connection/#{account.id}")
  end

  it "logs in the base handlers, a stall as a warning" do
    event = QubeRails::Backend.parse(vector_body("connection.stalled"))
    described_class.new(account).stalled(event)

    expect(log_output).to include("WARN QuBe Sync: account #{account.id}: connection.stalled (revision 3)")
  end
end
