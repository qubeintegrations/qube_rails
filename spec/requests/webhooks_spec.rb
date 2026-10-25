# frozen_string_literal: true

RSpec.describe "POST /webhooks/qube/:operation/:record_id", type: :request do
  let(:body) { vector_body("workflow_run.completed", "reference" => "create_invoice-1-x") }

  def deliver(path, body, header)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["X-Qube-Signature"] = header if header
    post path, params: body, headers: headers
  end

  it "verifies the delivery, enqueues it with its raw body and answers 200" do
    deliver("/webhooks/qube/create_invoice/1", body, signature(body))

    expect(response).to have_http_status(:ok)
    expect(QubeRails::WebhookJob).to have_been_enqueued.with("create_invoice", "1", body).on_queue("default")
  end

  it "enqueues the connection's own events for the connection class" do
    connected = vector_body("connection.connected")
    deliver("/webhooks/qube/connection/7", connected, signature(connected))

    expect(response).to have_http_status(:ok)
    expect(QubeRails::WebhookJob).to have_been_enqueued.with("connection", "7", connected)
  end

  it "verifies the server's own test vector at its timestamp" do
    vector = QubeRailsHelpers::VECTORS.fetch("events").find { |e| e["name"] == "workflow_run.completed" }
    QubeRails.config.webhook_secret = QubeRailsHelpers::VECTORS.fetch("secrets")
    travel_to(Time.at(QubeRailsHelpers::VECTORS.fetch("timestamp"))) do
      deliver("/webhooks/qube/create_invoice/1", vector["body"], vector["header"])
    end

    expect(response).to have_http_status(:ok)
  end

  it "takes a list of secrets while one rotates" do
    QubeRails.config.webhook_secret = ["whsec_new", QubeRailsHelpers::SECRET]
    deliver("/webhooks/qube/create_invoice/1", body, signature(body))

    expect(response).to have_http_status(:ok)
  end

  it "hands the delivery to config.enqueue when it's set" do
    handed = []
    QubeRails.config.enqueue = ->(delivery) { handed << delivery }
    deliver("/webhooks/qube/create_invoice/1", body, signature(body))

    expect(response).to have_http_status(:ok)
    expect(handed).to eq([{ operation: "create_invoice", record_id: "1", body: body }])
    expect(QubeRails::WebhookJob).not_to have_been_enqueued
  end

  it "uses config.queue" do
    QubeRails.config.queue = :qube
    deliver("/webhooks/qube/create_invoice/1", body, signature(body))

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
      deliver("/webhooks/qube/create_invoice/1", body, sent)

      expect(response).to have_http_status(:unauthorized)
      expect(QubeRails::WebhookJob).not_to have_been_enqueued
      expect(log_output).to include("QuBe Sync: refused a webhook: #{reason}")
      expect(log_output).not_to include(QubeRailsHelpers::SECRET)
      expect(log_output).not_to include("create_invoice-1-x")
      expect(log_output).not_to include(sent.split("v1=").last) if sent
    end
  end

  it "refuses a tampered body" do
    header = signature(body)
    deliver("/webhooks/qube/create_invoice/1", body.sub("create_invoice-1-x", "create_invoice-2-x"), header)

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers 404 for a slug none of the operations has, once the signature checks out" do
    deliver("/webhooks/qube/delete_everything/1", body, signature(body))

    expect(response).to have_http_status(:not_found)
    expect(QubeRails::WebhookJob).not_to have_been_enqueued
  end

  it "takes any content type, and a body of up to 5 MB" do
    big = vector_body("workflow_run.completed", "reference" => "r", "output" => { "pad" => "x" * (4 * 1024 * 1024) })
    post "/webhooks/qube/create_invoice/1", params: big,
                                            headers: { "CONTENT_TYPE" => "text/plain", "X-Qube-Signature" => signature(big) }

    expect(response).to have_http_status(:ok)
    expect(QubeRails::WebhookJob).to have_been_enqueued.with("create_invoice", "1", big)
  end

  it "answers 413 for a body over 5 MB, unread" do
    huge = "x" * (5 * 1024 * 1024 + 1)
    deliver("/webhooks/qube/create_invoice/1", huge, signature(huge))

    expect(response).to have_http_status(413)
    expect(log_output).to include("refused a webhook: its body is over 5242880 bytes")
  end

  it "checks the signature before the slug" do
    deliver("/webhooks/qube/delete_everything/1", body, nil)

    expect(response).to have_http_status(:unauthorized)
  end

  it "needs no sign-in" do
    deliver("/webhooks/qube/create_invoice/1", body, signature(body))

    expect(response).to have_http_status(:ok) # ApplicationController's sign-in would be 401
  end

  it "raises naming the initializer when the webhook secret isn't set" do
    QubeRails.config.webhook_secret = nil

    expect { deliver("/webhooks/qube/create_invoice/1", body, signature(body)) }
      .to raise_error(QubeRails::NotConfigured, %r{QUBE_WEBHOOK_SECRET.*config/initializers/qube_rails\.rb})
  end
end
