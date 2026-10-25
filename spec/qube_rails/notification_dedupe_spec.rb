# frozen_string_literal: true

RSpec.describe "Notification dedupe" do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:run) { make_run(invoice, connection) }

  def deliver(target = run, changes = {})
    QubeRails::WebhookJob.new.perform("run", target.id.to_s, run_body("workflow_run.notification", target, changes))
  end

  it "keeps taken delivery ids in qube_notifications by default" do
    expect(QubeRails.config.dedupe).to be_a(QubeRails::DatabaseDedupe)
  end

  it "runs a notification delivered twice once" do
    deliver
    deliver

    expect(QuickbooksDesktop::CreateInvoice.calls).to eq([[:notification, "0196a1c0-0000-7000-8000-00000000d001"]])
    expect(QubeRails::Notification.where(run_id: run.id).pluck(:delivery_id))
      .to eq(["0196a1c0-0000-7000-8000-00000000d001"])
  end

  it "leaves no row when the handler raises, so the redelivery runs it" do
    calls = 0
    allow_any_instance_of(QuickbooksDesktop::CreateInvoice).to receive(:notification) do
      calls += 1
      Customer.create!(account: account, name: "written by the handler")
      raise "app bug" if calls == 1
    end

    expect { deliver }.to raise_error(RuntimeError, "app bug")
    expect(QubeRails::Notification.count).to eq(0)
    expect(Customer.count).to eq(0) # the handler's writes rolled back with it

    deliver
    expect(calls).to eq(2)
    expect(QubeRails::Notification.count).to eq(1)
    expect(Customer.count).to eq(1)
  end

  it "keeps two runs' delivery ids apart" do
    other = make_run(invoice, connection)
    deliver(run)
    deliver(other)

    expect(QuickbooksDesktop::CreateInvoice.calls.size).to eq(2)
  end

  it "skips on a unique violation without aborting the transaction" do
    store = QubeRails::DatabaseDedupe.new
    ran = []
    QubeRails::Run.transaction do
      QubeRails::Notification.create!(run_id: run.id, delivery_id: "d-1")
      allow(QubeRails::Notification).to receive(:where).and_call_original
      # The check finds nothing (as if another worker hadn't committed yet); the insert conflicts.
      allow_any_instance_of(ActiveRecord::Relation).to receive(:exists?).and_return(false)
      expect(store.once(run, "d-1") { ran << 1 }).to be(false)
      expect(QubeRails::Run.where(id: run.id).count).to eq(1) # the transaction still works
    end
    expect(ran).to be_empty
  end

  it "deletes a run's rows with the run" do
    deliver
    run.destroy!

    expect(QubeRails::Notification.count).to eq(0)
  end

  it "takes a CacheDedupe when it's configured" do
    QubeRails.config.dedupe = QubeRails::CacheDedupe.new(ActiveSupport::Cache::MemoryStore.new)
    deliver
    deliver

    expect(QuickbooksDesktop::CreateInvoice.calls.size).to eq(1)
    expect(QubeRails::Notification.count).to eq(0)
  end
end
