# frozen_string_literal: true

RSpec.describe "Sync marks and pruning" do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }

  def run_event(run, name, changes = {})
    QubeRails::WebhookJob.new.perform("run", run.id.to_s, run_body(name, run, changes))
    run.reload
  end

  describe "last_synced_at" do
    it "is when the last completed run of the workflow started, never moving back" do
      expect(connection.last_synced_at("add_transaction")).to be_nil

      older = travel_to(2.days.ago) { make_run(invoice, connection) }
      newer = travel_to(1.day.ago) { make_run(invoice, connection) }
      failed = make_run(invoice, connection)

      run_event(newer, "workflow_run.completed", "revision" => 4)
      run_event(older, "workflow_run.completed", "revision" => 4)
      run_event(failed, "workflow_run.failed", "revision" => 2)

      expect(connection.last_synced_at("add_transaction")).to be_within(1.second).of(newer.created_at)
      expect(connection.last_synced_at("pull_changes")).to be_nil
    end

    it "outlives the runs it came from" do
      run = make_run(invoice, connection)
      run_event(run, "workflow_run.completed", "revision" => 4)
      QubeRails::Run.where(id: run.id).delete_all

      expect(connection.last_synced_at("add_transaction")).to be_within(1.second).of(run.created_at)
    end
  end

  describe "QubeRails::PruneRunsJob" do
    before { QubeRails.config.prune_runs_after = 30.days }

    it "deletes ended runs past the setting, with their notifications, and keeps links and the rest" do
      old_done = travel_to(40.days.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "completed", ended_at: Time.current) } }
      old_unstarted = travel_to(40.days.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "failed") } }
      old_going = travel_to(40.days.ago) { make_run(invoice, connection) }
      recent = travel_to(2.days.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "completed", ended_at: Time.current) } }
      QubeRails::Notification.create!(run: old_done, delivery_id: "d-1")
      connection.link(invoice, kind: "invoice", qb_id: "TXN-1")

      QubeRails::PruneRunsJob.perform_now

      expect(QubeRails::Run.pluck(:id)).to contain_exactly(old_going.id, recent.id)
      expect(QubeRails::Notification.where(run_id: [old_done.id, old_unstarted.id])).to be_empty
      expect(connection.sync_status(invoice, operation: "create_invoice")).to be_in_quickbooks
    end

    it "does nothing until prune_runs_after is set, and keeps a day at least" do
      QubeRails.config.prune_runs_after = nil
      run = travel_to(40.days.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "completed", ended_at: Time.current) } }
      QubeRails::PruneRunsJob.perform_now
      expect(QubeRails::Run.exists?(run.id)).to be(true)

      fresh = travel_to(2.hours.ago) { make_run(invoice, connection).tap { |r| r.update!(state: "completed", ended_at: Time.current) } }
      expect(QubeRails::Run.prunable(older_than: 1.minute)).not_to include(fresh)
      expect { QubeRails.config.prune_runs_after = 1.hour }.to raise_error(ArgumentError)
    end
  end
end
