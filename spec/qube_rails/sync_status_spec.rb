# frozen_string_literal: true

RSpec.describe QubeRails::SyncStatus do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:other) { make_connection(account, qube_id: "conn-q-other") }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }

  def status(record = invoice, on: connection)
    on.sync_status(record, operation: "create_invoice")
  end

  def run_in(state, record = invoice, on: connection, **changes)
    make_run(record, on).tap { |run| run.update!({ state: state }.merge(changes)) }
  end

  it "is not_sent with no run and no link" do
    expect(status).to have_attributes(status: :not_sent, run: nil, qb_id: nil, retry?: false)
    expect(status.not_sent?).to be(true)
  end

  it "is sending while the latest run starts or runs, and says when a start is unconfirmed" do
    run_in("running")
    expect(status).to have_attributes(status: :sending, unconfirmed?: false)

    QubeRails::Run.delete_all
    travel_to(2.minutes.ago) { run_in("starting") }
    expect(status).to have_attributes(status: :sending, unconfirmed?: true, retry?: false)
  end

  it "is needs_answer while the latest run waits for an answer" do
    run_in("awaiting_input")
    expect(status.needs_answer?).to be(true)
  end

  it "is in_quickbooks with its qb_id once linked" do
    connection.link(invoice, kind: "invoice", qb_id: "1F2-1")
    expect(status).to have_attributes(status: :in_quickbooks, qb_id: "1F2-1", retry?: false)
  end

  it "is failed with the run's error, and worth a retry while it isn't linked" do
    run_in("failed", ended_at: Time.now, error: { "message" => "No customer named Riverbend" })
    expect(status).to have_attributes(status: :failed, error: { "message" => "No customer named Riverbend" },
                                      retry?: true)
  end

  it "is cancelled for a cancelled run, or one that completed on a cancelled outcome" do
    run_in("completed", outcome: "cancelled", ended_at: Time.now)
    expect(status).to have_attributes(status: :cancelled, retry?: true)
  end

  it "is in_quickbooks for a run that completed without linking the record" do
    run_in("completed", outcome: "added", ended_at: Time.now)
    expect(status).to have_attributes(status: :in_quickbooks, qb_id: nil)
  end

  describe "when the run and the link disagree" do
    before { travel_to(1.hour.ago) { connection.link(invoice, kind: "invoice", qb_id: "1F2-1") } }

    it "takes a run going since the link" do
      run_in("running")
      expect(status).to have_attributes(status: :sending, qb_id: "1F2-1")
    end

    it "takes a run that failed after the link, but says a new start would add it twice" do
      run_in("failed", ended_at: Time.now)
      expect(status).to have_attributes(status: :failed, qb_id: "1F2-1", retry?: false)
    end

    it "takes a link made after the run failed" do
      travel_to(2.hours.ago) { run_in("failed", ended_at: Time.now) }
      expect(status).to have_attributes(status: :in_quickbooks, qb_id: "1F2-1")
    end
  end

  it "is per connection" do
    connection.link(invoice, kind: "invoice", qb_id: "1F2-1")
    run_in("awaiting_input", on: other)

    expect(status.status).to eq(:in_quickbooks)
    expect(status(on: other).status).to eq(:needs_answer)
  end

  it "reads the latest run's connection for a page that doesn't say which" do
    expect(described_class.latest(invoice, operation: "create_invoice").status).to eq(:not_sent)

    run_in("running", on: other)
    expect(described_class.latest(invoice, operation: "create_invoice").status).to eq(:sending)
  end

  describe "the connection's scopes" do
    let!(:linked) { Invoice.create!(account: account, number: "1") }
    let!(:waiting) { Invoice.create!(account: account, number: "2") }
    let!(:going) { Invoice.create!(account: account, number: "3") }
    let!(:untouched) { Invoice.create!(account: account, number: "4") }

    before do
      connection.link(linked, kind: "invoice", qb_id: "1F2-1")
      other.link(untouched, kind: "invoice", qb_id: "1F2-9") # another company file
      run_in("awaiting_input", waiting)
      run_in("running", going)
      run_in("awaiting_input", going, on: other)
    end

    it "lists records in QuickBooks on this connection, or not, in one query each" do
      expect(connection.in_quickbooks(Invoice).pluck(:number)).to eq(["1"])
      expect(connection.not_in_quickbooks(Invoice.where(account: account)).order(:number).pluck(:number))
        .to eq(%w[2 3 4])
    end

    it "lists records waiting on an answer, and on their way, for an operation" do
      expect(connection.needing_answer(Invoice, operation: "create_invoice").pluck(:number)).to eq(["2"])
      expect(connection.sending(Invoice, operation: "create_invoice").pluck(:number)).to eq(["3"])
      expect(other.needing_answer(Invoice, operation: "create_invoice").pluck(:number)).to eq(["3"])
      expect(connection.needing_answer(Invoice, operation: "sync_customer")).to be_empty
    end
  end
end
