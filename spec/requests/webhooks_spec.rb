# frozen_string_literal: true

RSpec.describe "QuBe Sync's webhooks", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:run) { make_run(invoice, connection) }
  let(:body) { run_body("workflow_run.completed", run) }

  def deliver(path, body, header, content_type: "application/json")
    headers = { "CONTENT_TYPE" => content_type }
    headers["X-Qube-Signature"] = header if header
    post path, params: body, headers: headers
  end

  describe "POST /webhooks/qube/runs/:id" do
    it "verifies the delivery, enqueues it with its raw body and answers 200" do
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(response).to have_http_status(:ok)
      expect(QubeRails::WebhookJob).to have_been_enqueued.with("run", run.id.to_s, body).on_queue("default")
    end

    it "answers 404 for a run that isn't there, once the signature checks out" do
      deliver("/webhooks/qube/runs/0", body, signature(body))

      expect(response).to have_http_status(:not_found)
      expect(QubeRails::WebhookJob).not_to have_been_enqueued
    end

    it "checks the signature before the row" do
      deliver("/webhooks/qube/runs/0", body, nil)

      expect(response).to have_http_status(:unauthorized)
    end

    it "verifies the server's own test vector at its timestamp" do
      vector = QubeRailsHelpers::VECTORS.fetch("events").find { |e| e["name"] == "workflow_run.completed" }
      QubeRails.config.webhook_secret = QubeRailsHelpers::VECTORS.fetch("secrets")
      travel_to(Time.at(QubeRailsHelpers::VECTORS.fetch("timestamp"))) do
        deliver("/webhooks/qube/runs/#{run.id}", vector["body"], vector["header"])
      end

      expect(response).to have_http_status(:ok)
    end

    it "takes a list of secrets while one rotates" do
      QubeRails.config.webhook_secret = ["whsec_new", QubeRailsHelpers::SECRET]
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(response).to have_http_status(:ok)
    end

    it "hands the delivery to config.enqueue when it's set, on config.queue otherwise" do
      handed = []
      QubeRails.config.enqueue = ->(delivery) { handed << delivery }
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(handed).to eq([{ kind: "run", id: run.id.to_s, body: body }])
      expect(QubeRails::WebhookJob).not_to have_been_enqueued
    end

    it "answers 503, logged without the body, when the enqueue returns false" do
      QubeRails.config.enqueue = ->(_delivery) { false }
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(response).to have_http_status(503)
      expect(log_output).to include("ERROR QuBe Sync: couldn't enqueue a webhook for run #{run.id}")
      expect(log_output).not_to include(run.reference)
    end

    it "answers 503, logged without the body or the error's message, when the enqueue raises" do
      QubeRails.config.enqueue = ->(delivery) { raise IOError, "redis is down: #{delivery[:body]}" }
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(response).to have_http_status(503)
      expect(log_output).to include("(IOError)")
      expect(log_output).not_to include(run.reference)
    end

    it "uses config.queue" do
      QubeRails.config.queue = :qube
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(QubeRails::WebhookJob).to have_been_enqueued.on_queue("qube")
    end

    {
      "a signature with another secret" => [:mismatch, ->(b) { "t=#{Time.now.to_i},v1=#{OpenSSL::HMAC.hexdigest("sha256", "whsec_other", "#{Time.now.to_i}.#{b}")}" }],
      "no signature" => [:missing, ->(_b) { nil }],
      "a malformed signature" => [:malformed, ->(_b) { "v1=abc" }],
      "a stale signature" => [:stale, ->(b) { "t=#{Time.now.to_i - 301},v1=#{OpenSSL::HMAC.hexdigest("sha256", QubeRailsHelpers::SECRET, "#{Time.now.to_i - 301}.#{b}")}" }]
    }.each do |name, (reason, header)|
      it "refuses #{name} with 401, logging the reason and never the secret or the body" do
        sent = header.call(body)
        deliver("/webhooks/qube/runs/#{run.id}", body, sent)

        expect(response).to have_http_status(:unauthorized)
        expect(QubeRails::WebhookJob).not_to have_been_enqueued
        expect(log_output).to include("QuBe Sync: refused a webhook: #{reason} (/webhooks/qube/runs/#{run.id})")
        expect(log_output).to include("QUBE_WEBHOOK_SECRET") if reason == :mismatch
        expect(log_output).not_to include(QubeRailsHelpers::SECRET)
        expect(log_output).not_to include(run.reference)
        expect(log_output).not_to include(sent.split("v1=").last) if sent
      end
    end

    it "refuses a tampered body" do
      header = signature(body)
      deliver("/webhooks/qube/runs/#{run.id}", body.sub(run.reference, "other-ref"), header)

      expect(response).to have_http_status(:unauthorized)
    end

    it "takes any content type, and a body of up to 5 MB" do
      big = run_body("workflow_run.completed", run, "output" => { "pad" => "x" * (4 * 1024 * 1024) })
      deliver("/webhooks/qube/runs/#{run.id}", big, signature(big), content_type: "text/plain")

      expect(response).to have_http_status(:ok)
      expect(QubeRails::WebhookJob).to have_been_enqueued.with("run", run.id.to_s, big)
    end

    it "answers 413 for a body over 5 MB, unread" do
      huge = "x" * (5 * 1024 * 1024 + 1)
      deliver("/webhooks/qube/runs/#{run.id}", huge, signature(huge))

      expect(response).to have_http_status(413)
      expect(log_output).to include("refused a webhook: its body is over 5242880 bytes")
    end

    it "needs no sign-in" do
      deliver("/webhooks/qube/runs/#{run.id}", body, signature(body))

      expect(response).to have_http_status(:ok) # ApplicationController's sign-in would be 401
    end

    it "raises naming the initializer when the webhook secret isn't set" do
      QubeRails.config.webhook_secret = nil

      expect { deliver("/webhooks/qube/runs/#{run.id}", body, signature(body)) }
        .to raise_error(QubeRails::NotConfigured, %r{QUBE_WEBHOOK_SECRET.*config/initializers/qube_rails\.rb})
    end
  end

  describe "POST /webhooks/qube/connections/:id" do
    let(:connected) { vector_body("connection.connected") }

    it "verifies the delivery, enqueues it and answers 200" do
      deliver("/webhooks/qube/connections/#{connection.id}", connected, signature(connected))

      expect(response).to have_http_status(:ok)
      expect(QubeRails::WebhookJob).to have_been_enqueued.with("connection", connection.id.to_s, connected)
    end

    it "answers 404 for a connection that isn't there" do
      deliver("/webhooks/qube/connections/0", connected, signature(connected))

      expect(response).to have_http_status(:not_found)
    end

    it "refuses a bad signature with 401" do
      deliver("/webhooks/qube/connections/#{connection.id}", connected, signature(connected, secret: "whsec_no"))

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /webhooks/qube/requests/:id" do
    let(:customer) { Customer.create!(account: account, name: "Northwind Builders") }
    let(:queued) do
      QubeRails::QueuedRequest.create!(connection: connection, operation: "find_customer", record: customer,
                                       reference: "find_customer-#{customer.id}-1", state: "queued")
    end
    let(:answer) { vector_body("request: a page of a paginated query") }

    it "verifies the delivery, enqueues it with its raw body and answers 200" do
      deliver("/webhooks/qube/requests/#{queued.id}", answer, signature(answer))

      expect(response).to have_http_status(:ok)
      expect(QubeRails::WebhookJob).to have_been_enqueued.with("request", queued.id.to_s, answer)
    end

    it "answers 404 for a request that isn't there" do
      deliver("/webhooks/qube/requests/0", answer, signature(answer))

      expect(response).to have_http_status(:not_found)
      expect(QubeRails::WebhookJob).not_to have_been_enqueued
    end

    it "refuses a bad signature with 401" do
      deliver("/webhooks/qube/requests/#{queued.id}", answer, signature(answer, secret: "whsec_no"))

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers 413 for a body over 5 MB" do
      big = "x" * (5 * 1024 * 1024 + 1)
      deliver("/webhooks/qube/requests/#{queued.id}", big, signature(big))

      expect(response).to have_http_status(413)
    end
  end

  it "has no route for the old /:operation/:record_id and /connection/:account_id URLs" do
    expect { deliver("/webhooks/qube/create_invoice/#{invoice.id}", body, signature(body)) }
      .to raise_error(ActionController::RoutingError)
    expect { deliver("/webhooks/qube/connection/#{account.id}", body, signature(body)) }
      .to raise_error(ActionController::RoutingError)
  end
end
