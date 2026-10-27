# frozen_string_literal: true

require "yaml"

# What the screens say to an app's users: never QuBe Sync's name or its plumbing, and every word
# from I18n (qube_rails.*), so an app can reword or translate it.
RSpec.describe "The screens' wording", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:signed_in) { { "X-Account" => account.id.to_s, "HTTP_REFERER" => "/invoices/#{invoice.id}" } }
  let(:jargon) { /QuBe Sync|qube sync|webhook|revision|ListID|your app|\bthe run\b/i }

  before { QubeRails.config.storyboard = true }

  before { I18n.t("qube_rails.status.added") } # the locale files load before a test's own words go in

  after { I18n.reload! }

  def storyboard
    get "/qube/storyboard", headers: signed_in
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  it "never names QuBe Sync or its plumbing on any screen (the storyboard's own notes aside)" do
    canvases = storyboard.css("[data-qube-storyboard-canvas]")

    expect(canvases.size).to eq(QubeRails::Storyboard.screens.size)
    canvases.each do |canvas|
      screen = canvas.ancestors("[data-qube-storyboard]").first["data-qube-storyboard"]
      words = canvas.xpath(".//text()").map(&:text).join(" ") +
              canvas.css("[aria-label], [data-qube-search]").map do |el|
                [el["aria-label"], *el.attributes.select { |k, _| k.start_with?("data-qube-text-") }.values.map(&:value)]
              end.flatten.compact.join(" ")
      expect(words).not_to match(jargon), "#{screen}: #{words[jargon]}"
    end
  end

  it "keeps every English string free of QuBe Sync's name and plumbing" do
    english = YAML.load_file(File.expand_path("../../config/locales/en.yml", __dir__))
    strings = ->(node) { node.is_a?(Hash) ? node.values.flat_map(&strings) : [node.to_s] }

    expect(strings.call(english.dig("en", "qube_rails")).grep(jargon)).to eq([])
  end

  it "takes an app's own words for a key, on the screens and in a route's message" do
    I18n.backend.store_translations(:en, qube_rails: { status: { check_for_updates: "Look again" },
                                                       errors: { not_starting: "Already on its way." } })

    stuck = storyboard.at_css("[data-qube-storyboard='looks_stuck'] form.qube-redeliver-form")
    expect(stuck.at_css("button, input[type=submit]").then { |b| b.text.strip.empty? ? b["value"] : b.text.strip })
      .to eq("Look again")

    run = make_run(invoice, connection).tap { |r| r.update!(state: "running") }
    post "/qube/runs/#{run.id}/retry_start", headers: signed_in
    expect(flash[:qube_rails_error]).to eq("Already on its way.")
  end

  it "speaks the app's locale, and falls back to English for a key that locale lacks" do
    I18n.backend.store_translations(:fr, qube_rails: { status: { running: "Synchronisation avec QuickBooks" } })
    run = make_run(invoice, connection).tap { |r| r.update!(state: "running") }
    I18n.available_locales = %i[en fr]

    I18n.with_locale(:fr) do
      expect(run.summary_text).to eq("Synchronisation avec QuickBooks")
      expect(QubeRails.t("status.added")).to eq("Added to QuickBooks")
    end
  ensure
    I18n.available_locales = nil
  end
end
