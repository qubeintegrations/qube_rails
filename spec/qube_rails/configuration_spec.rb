# frozen_string_literal: true

RSpec.describe QubeRails::Configuration do
  subject(:config) { described_class.new }

  around do |example|
    saved = ENV.to_h.slice("QUBE_API_KEY", "QUBE_URL", "QUBE_WEBHOOK_SECRET", "QUBE_WEBHOOK_URL")
    example.run
  ensure
    %w[QUBE_API_KEY QUBE_URL QUBE_WEBHOOK_SECRET QUBE_WEBHOOK_URL].each { |name| ENV.delete(name) }
    saved.each { |name, value| ENV[name] = value }
  end

  {
    operations: "config.operations",
    connection_events: "config.connection_events",
    current_account: "config.current_account",
    api_key: "QUBE_API_KEY",
    webhook_secret: "QUBE_WEBHOOK_SECRET",
    webhook_url: "QUBE_WEBHOOK_URL"
  }.each do |setting, named|
    it "raises for #{setting}, unset, naming #{named} and the initializer" do
      expect { config.public_send(setting) }.to raise_error(QubeRails::NotConfigured) { |error|
        expect(error.message).to include(named, "config/initializers/qube_rails.rb")
      }
    end
  end

  it "reads the environment at first use" do
    ENV["QUBE_API_KEY"] = "key-from-env"
    ENV["QUBE_WEBHOOK_SECRET"] = "secret-from-env"
    ENV["QUBE_WEBHOOK_URL"] = "https://app.example/webhooks/qube/"

    expect(config.api_key).to eq("key-from-env")
    expect(config.webhook_secret).to eq("secret-from-env")
    expect(config.webhook_url).to eq("https://app.example/webhooks/qube")
    expect(config.base_url).to eq("https://qubesync.com")
  end

  it "prefers what the initializer sets" do
    ENV["QUBE_URL"] = "https://env.example"
    config.base_url = "https://set.example"

    expect(config.base_url).to eq("https://set.example")
  end

  it "has the defaults the plan names" do
    expect(config.queue).to eq(:default)
    expect(config.parent_controller).to eq("ApplicationController")
    expect(config.dedupe).to be_a(QubeRails::CacheDedupe)
    expect(config.enqueue).to respond_to(:call)
    expect(config.authorize_question).to respond_to(:call)
  end

  it "keeps operations and connection_events as class names, resolved at use" do
    config.operations = { create_invoice: QuickbooksDesktop::CreateInvoice, "other" => "QuickbooksDesktop::Nope" }
    config.connection_events = QuickbooksDesktop::ConnectionEvents

    expect(config.operations).to eq("create_invoice" => "QuickbooksDesktop::CreateInvoice",
                                     "other" => "QuickbooksDesktop::Nope")
    expect(config.operation_class("create_invoice")).to eq(QuickbooksDesktop::CreateInvoice)
    expect(config.operation_class("missing")).to be_nil
    expect(config.connection_events).to eq("QuickbooksDesktop::ConnectionEvents")
    expect(config.connection_events_class).to eq(QuickbooksDesktop::ConnectionEvents)
    expect { config.operation_class("other") }.to raise_error(NameError)
  end

  it "refuses settings that can't be called" do
    expect { config.current_account = "Account.first" }.to raise_error(ArgumentError, /current_account/)
    expect { config.authorize_question = true }.to raise_error(ArgumentError, /authorize_question/)
    expect { config.dedupe = Object.new }.to raise_error(ArgumentError, /seen\?/)
  end

  it "never shows a secret in inspect" do
    config.api_key = "qube_live_supersecret"
    config.webhook_secret = %w[whsec_one whsec_two]

    expect(config.inspect).not_to include("supersecret", "whsec_one", "whsec_two")
    expect(config.inspect).to include("api_key=[hidden]")
  end

  it "makes the client from the settings, with neither secret in its inspect" do
    expect(QubeRails.client.base_url).to eq(QubeRailsHelpers::BASE_URL)
    expect(QubeRails.client.inspect).not_to include(QubeRailsHelpers::API_KEY)
  end

  it "logs a retry without its query or any key" do
    QubeRails.log_retry(method: "GET", url: "https://qube.example/api/v2/x", status: 503, delay: 0.25)

    expect(log_output).to include("WARN QuBe Sync: retrying GET https://qube.example/api/v2/x (503) in 0.3 s")
  end
end
