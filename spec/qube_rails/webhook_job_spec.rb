# frozen_string_literal: true

RSpec.describe QubeRails::WebhookJob do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:run) { make_run(Invoice.create!(account: account, number: "1001"), connection) }
  let(:body) { run_body("workflow_run.completed", run) }

  before do
    allow_any_instance_of(QuickbooksDesktop::CreateInvoice).to receive(:ended).and_raise(RuntimeError, "app bug")
  end

  it "retries a delivery whose work raised, with a growing wait" do
    described_class.perform_now("run", run.id.to_s, body)

    expect(described_class).to have_been_enqueued.with("run", run.id.to_s, body)
  end

  it "logs an error and raises when the attempts run out" do
    job = described_class.new("run", run.id.to_s, body)
    # How ActiveJob counts a retry_on's attempts: per exception list since Rails 6, else executions.
    if job.respond_to?(:exception_executions=)
      job.exception_executions = { "[StandardError]" => described_class::ATTEMPTS - 1 }
    else
      job.executions = described_class::ATTEMPTS - 1
    end

    expect { job.perform_now }.to raise_error(RuntimeError, "app bug")
    expect(log_output).to include("ERROR QuBe Sync: gave up on a webhook for run #{run.id} after 10 attempts: " \
                                  "RuntimeError: app bug")
  end

  it "takes job_attempts as a whole number of 1 or more" do
    expect { QubeRails.config.job_attempts = 0 }.to raise_error(ArgumentError, /job_attempts/)
    QubeRails.config.job_attempts = 3
    expect(QubeRails.config.job_attempts).to eq(3)
  end
end
