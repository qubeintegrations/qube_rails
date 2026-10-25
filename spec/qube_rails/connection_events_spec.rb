# frozen_string_literal: true

RSpec.describe QubeRails::ConnectionEvents do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account, status: "pending") }

  def run_event(name, changes = {}, target = connection)
    QubeRails::WebhookJob.perform_now("connection", target.id.to_s, vector_body(name, changes))
    target.reload
  end

  it "applies each of the four events to the row, then hands it to the app's class with its owner" do
    run_event("connection.connected")
    expect(connection).to have_attributes(status: "connected", revision: 1)

    run_event("connection.setup_cancelled")
    expect(connection.status).to eq("setup_cancelled")

    run_event("connection.stalled")
    expect(connection).to have_attributes(status: "stalled", stall_reason: "not_checking_in", revision: 3)

    run_event("connection.resumed")
    expect(connection).to have_attributes(status: "connected", stall_reason: nil, revision: 4)

    id = connection.id
    expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([
      [:connected, id, account.id, "connected"],
      [:setup_cancelled, id, account.id, "setup_cancelled"],
      [:stalled, id, account.id, "not_checking_in"],
      [:resumed, id, account.id, nil]
    ])
  end

  it "skips an event whose connection id isn't the row's qube_id" do
    run_event("connection.connected", "connection" => { "id" => "someone-elses" })

    expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
    expect(connection).to have_attributes(status: "pending", revision: nil)
    expect(log_output).to include("connection #{connection.id} skipped connection.connected for " \
                                  "\"someone-elses\": not this connection")
  end

  it "skips everything while the row has no qube_id" do
    connection.update!(qube_id: nil)
    run_event("connection.connected", "connection" => { "id" => nil })
    run_event("connection.connected")

    expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
  end

  it "skips an event that isn't a connection's" do
    run_event("workflow_run.completed")

    expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
    expect(log_output).to include("skipped workflow_run.completed for nil: not this connection")
  end

  it "applies an event only when it's newer than the last applied" do
    run_event("connection.resumed") # revision 4
    run_event("connection.stalled") # revision 3, a retry that came late

    expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).to eq([:resumed])
    expect(connection).to have_attributes(status: "connected", revision: 4)
  end

  it "keeps two connections on one account apart" do
    other = make_connection(account, qube_id: "conn-q-2", status: "pending")
    run_event("connection.connected")
    run_event("connection.connected", {}, other) # the vector's id is the first's

    expect(connection.status).to eq("connected")
    expect(other.reload.status).to eq("pending")
  end

  it "raises naming the initializer when connection_events isn't set" do
    QubeRails.config.connection_events = nil

    expect { run_event("connection.connected") }
      .to raise_error(QubeRails::NotConfigured, %r{connection_events.*config/initializers/qube_rails\.rb})
  end

  it "logs in the base handlers, a stall as a warning" do
    event = QubeRails::Backend.parse(vector_body("connection.stalled"))
    described_class.new(connection).stalled(event)

    expect(log_output).to include("WARN QuBe Sync: connection #{connection.id}: connection.stalled (revision 3)")
  end
end
