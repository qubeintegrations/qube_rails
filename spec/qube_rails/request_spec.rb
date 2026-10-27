# frozen_string_literal: true

RSpec.describe QubeRails::Request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:customer) { Customer.create!(account: account, name: "Northwind Builders") }
  let(:queue_url) { %r{\A#{Regexp.escape(api_url("/connections/#{connection.qube_id}/customers"))}} }
  let(:qube_id) { "0196a1c0-0000-7000-8000-00000000e001" }

  def make_request(state: "queued", qube_id: self.qube_id)
    QubeRails::QueuedRequest.create!(connection: connection, operation: "find_customer", record: customer,
                                     reference: "find_customer-#{customer.id}-#{SecureRandom.uuid}",
                                     state: state, qube_id: qube_id, params: { "full_name" => customer.name })
  end

  let(:row) { make_request }

  def deliver(name, changes = {}, target = row)
    body = vector_body(name, { "id" => qube_id }.merge(changes))
    QubeRails::WebhookJob.new.perform("request", target.id.to_s, body)
    target.reload
  end

  def page(number, iteration_state, state: "response_received")
    { "page" => number, "page_request_id" => "pr-#{number}", "iteration_state" => iteration_state, "state" => state }
  end

  describe ".queue" do
    it "writes the row first, queues the operation with its reference as the Idempotency-Key and its webhook URL" do
      stub = stub_request(:get, queue_url).to_return(json_data("id" => "req-q-1", "state" => "queued"))

      queued = QuickbooksDesktop::FindCustomer.queue(customer, connection)

      expect(queued).to be_a(QubeRails::QueuedRequest)
      expect(queued.reload).to have_attributes(
        operation: "find_customer", record: customer, connection: connection, qube_id: "req-q-1",
        state: "queued", params: { "full_name" => "Northwind Builders" }, ended_at: nil
      )
      expect(queued.reference).to start_with("find_customer-#{customer.id}-")
      expect(queued.webhook_url).to eq("#{QubeRailsHelpers::WEBHOOK_URL}/requests/#{queued.id}")
      expect(stub.with { |req|
        query = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
        req.headers["Idempotency-Key"] == queued.reference &&
          query == { "webhook_url" => queued.webhook_url, "full_name" => "Northwind Builders" }
      }).to have_been_made.once
    end

    it "returns the record's request that hasn't ended, queueing nothing new, and a new reference once it ends" do
      stub_request(:get, queue_url).to_return(json_data("id" => "req-q-1", "state" => "queued"))
      first = QuickbooksDesktop::FindCustomer.queue(customer, connection)
      expect(first.reused?).to be(false)

      first.update!(state: "retryable")
      again = QuickbooksDesktop::FindCustomer.queue(customer, connection)
      expect(again).to eq(first)
      expect(again.reused?).to be(true)
      expect(a_request(:get, queue_url)).to have_been_made.once

      first.update!(state: "response_received", ended_at: Time.now)
      later = QuickbooksDesktop::FindCustomer.queue(customer, connection)
      expect(later).not_to eq(first)
      expect(later.reference).not_to eq(first.reference)
    end

    it "sends an unconfirmed queue again with its own reference and params" do
      stub_request(:get, queue_url).to_timeout
      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(Net::OpenTimeout)
      first = QubeRails::QueuedRequest.last
      expect(first).to have_attributes(state: "queued", qube_id: nil)

      customer.update!(name: "Renamed since") # the resend still sends what the first did
      WebMock.reset!
      replay = stub_request(:get, queue_url)
               .with { |req|
                 query = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
                 req.headers["Idempotency-Key"] == first.reference && query["full_name"] == "Northwind Builders"
               }
               .to_return(json_data("id" => "req-q-1", "state" => "queued"))

      again = QuickbooksDesktop::FindCustomer.queue(customer, connection)

      expect(again).to eq(first)
      expect(again.reload.qube_id).to eq("req-q-1")
      expect(replay).to have_been_made.once
      expect(first.reload.retry_queue!).to eq(first) # confirmed now: nothing is sent
      expect(replay).to have_been_made.once
    end

    it "marks the row failed and raises when QuBe Sync refuses the queue (a 4xx)" do
      stub_request(:get, queue_url).to_return(status: 422, body: { errors: { detail: "bad params" } }.to_json)

      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(QubeSync::APIError)
      expect(QubeRails::QueuedRequest.last).to have_attributes(state: "failed", qube_id: nil)
      expect(QubeRails::QueuedRequest.last.ended_at).not_to be_nil
    end

    it "leaves a queue answered 409 (its key in use by the other click) queued" do
      stub_request(:get, queue_url).to_return(status: 409, body: { errors: "in use" }.to_json)

      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(QubeSync::APIError)
      expect(QubeRails::QueuedRequest.last).to have_attributes(state: "queued", ended_at: nil)
    end

    it "marks the row failed when its params raise, before anything is sent" do
      allow_any_instance_of(QuickbooksDesktop::FindCustomer).to receive(:params).and_raise(ArgumentError, "no name")

      expect { QuickbooksDesktop::FindCustomer.queue(customer, connection) }.to raise_error(ArgumentError, "no name")
      expect(QubeRails::QueuedRequest.last.state).to eq("failed")
      expect(a_request(:get, queue_url)).not_to have_been_made
    end

    it "refuses a connection QuBe Sync hasn't made yet" do
      pending_connection = make_connection(account, qube_id: nil, status: "pending")

      expect { QuickbooksDesktop::FindCustomer.queue(customer, pending_connection) }
        .to raise_error(QubeRails::NotConnected)
    end
  end

  describe "the job" do
    it "hands an answer to answered, then done, and ends the row" do
      deliver("request: an answer")

      expect(QuickbooksDesktop::FindCustomer.calls).to eq([[:answered, 1], [:done, 1]])
      expect(row).to have_attributes(state: "response_received", pages_answered: 1, last_page: 1)
      expect(row.done?).to be(true)
      expect(row.error).to be_nil
    end

    it "takes a delivery once, by page_request_id and state" do
      deliver("request: an answer")
      deliver("request: an answer")

      expect(QuickbooksDesktop::FindCustomer.calls).to eq([[:answered, 1], [:done, 1]])
      expect(QubeRails::RequestDelivery.where(request_id: row.id).count).to eq(1)
    end

    it "calls done once every page 1..N is in, whatever order they come in" do
      deliver("request: a page of a paginated query", page(3, "done"))
      deliver("request: a page of a paginated query", page(1, "continue"))
      expect(row.ended?).to be(false)
      expect(row).to have_attributes(pages_answered: 2, last_page: 3, state: "response_received")

      deliver("request: a page of a paginated query", page(2, "continue"))
      deliver("request: a page of a paginated query", page(2, "continue")) # a retry

      expect(QuickbooksDesktop::FindCustomer.calls)
        .to eq([[:answered, 3], [:answered, 1], [:answered, 2], [:done, 3]])
      expect(row.done?).to be(true)
    end

    it "keeps a retryable as not final, and skips one that comes after its page's answer" do
      deliver("request: QuickBooks refused it", page(1, "not_applicable", state: "retryable"))
      expect(row).to have_attributes(state: "retryable", ended_at: nil)
      expect(row.error).to include("user_message")

      deliver("request: an answer", page(1, "not_applicable"))
      deliver("request: QuickBooks refused it", page(1, "not_applicable", state: "retryable").merge("page_request_id" => "pr-1-late"))

      expect(QuickbooksDesktop::FindCustomer.calls).to eq([[:retrying, 1], [:answered, 1], [:done, 1]])
      expect(row.state).to eq("response_received")
    end

    it "ends the row on an error, keeping the error, and hands it to failed" do
      deliver("request: QuickBooks refused it")

      expect(QuickbooksDesktop::FindCustomer.calls).to eq([[:failed, "error"]])
      expect(row).to have_attributes(state: "error")
      expect(row.ended?).to be(true)
      expect(row.error).to include("error_code" => 3100)
    end

    it "hands a timed_out to failed by default" do
      deliver("request: an answer that never came back")

      expect(QuickbooksDesktop::FindCustomer.calls).to eq([[:failed, "timed_out"]])
      expect(row.state).to eq("timed_out")
    end

    it "skips an event whose id isn't the row's qube_id" do
      deliver("request: an answer", "id" => "someone-elses")

      expect(QuickbooksDesktop::FindCustomer.calls).to be_empty
      expect(row.state).to eq("queued")
      expect(log_output).to include("skipped request \"someone-elses\": not this request")
    end

    it "skips an event that isn't a request's" do
      QubeRails::WebhookJob.new.perform("request", row.id.to_s, vector_body("workflow_run.completed"))

      expect(QuickbooksDesktop::FindCustomer.calls).to be_empty
      expect(log_output).to include("not this request")
    end

    it "takes the id from the first event when the queue's answer hasn't come back yet" do
      unconfirmed = make_request(qube_id: nil)
      deliver("request: an answer", {}, unconfirmed)

      expect(unconfirmed).to have_attributes(qube_id: qube_id, state: "response_received")
    end

    it "keeps no response body on the row" do
      deliver("request: an answer")

      expect(QubeRails::QueuedRequest.column_names).not_to include("response_json", "response_xml")
    end
  end

  describe "pruning and disconnecting" do
    it "prunes ended requests past prune_runs_after with their deliveries, and keeps the rest" do
      QubeRails.config.prune_runs_after = 30.days
      old_done = travel_to(40.days.ago) { make_request(state: "response_received").tap { |r| r.update!(ended_at: Time.current) } }
      QubeRails::RequestDelivery.create!(queued_request: old_done, dedupe_key: "pr-1:response_received", page: 1,
                                         state: "response_received")
      old_going = travel_to(40.days.ago) { make_request(state: "retryable") }
      recent = travel_to(2.days.ago) { make_request(state: "error").tap { |r| r.update!(ended_at: Time.current) } }

      QubeRails::PruneRunsJob.perform_now

      expect(QubeRails::QueuedRequest.pluck(:id)).to contain_exactly(old_going.id, recent.id)
      expect(QubeRails::RequestDelivery.where(request_id: old_done.id)).to be_empty
    end

    it "deletes the connection's requests and their deliveries on disconnect!" do
      deliver("request: an answer")

      connection.disconnect!

      expect(QubeRails::QueuedRequest.where(id: row.id)).to be_empty
      expect(QubeRails::RequestDelivery.count).to eq(0)
    end
  end
end
