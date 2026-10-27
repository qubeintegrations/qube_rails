# frozen_string_literal: true

RSpec.describe "The storyboard", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:signed_in) { { "X-Account" => account.id.to_s } }
  let(:engine_views) { File.expand_path("../../app/views/qube_rails", __dir__) }

  before { QubeRails.config.storyboard = true }

  def page(path = "/qube/storyboard")
    get path, headers: signed_in
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  it "shows every screen from sample data, in the app's layout, with each piece's override path" do
    rows_before = [QubeRails::Run.count, QubeRails::Connection.count]
    shown = page
    panels = shown.css("[data-qube-storyboard]")

    expect(shown.at_css("#dummy-nav")).not_to be_nil # the app's layout, its own route helpers working
    expect(panels.map { |p| p["data-qube-storyboard"] }).to eq(QubeRails::Storyboard.screens.map(&:key))
    expect(panels.map { |p| p["data-qube-storyboard"] }).to include(
      *%w[not_sent starting unconfirmed running needs_answer looks_stuck in_quickbooks done failed cancelled error],
      *%w[near_match record_search choose enum_select number_boolean name_clash ask_about_add rows refusal]
    )
    expect(shown.css(".qube-run-status").size).to eq(9) # not_sent renders nothing
    expect(shown.css(".qube-question").size).to eq(9)
    expect([QubeRails::Run.count, QubeRails::Connection.count]).to eq(rows_before)

    panel = ->(key) { shown.at_css("[data-qube-storyboard='#{key}']") }
    expect(panel.call("unconfirmed").at_css("form.qube-retry-start-form")["action"]).to eq("/qube/storyboard/unconfirmed/answer")
    expect(panel.call("looks_stuck").at_css("form.qube-redeliver-form")).not_to be_nil
    expect(panel.call("failed").at_css(".qube-run-error-detail").text).to include("active in QuickBooks")
    expect(panel.call("error").at_css(".qube-error")).not_to be_nil
    expect(panel.call("refusal").at_css(".qube-question .qube-error").text).to include("couldn't be used")
    expect(panel.call("rows").css("[data-qube-row][data-qube-values]").size).to eq(3)
    expect(panel.call("near_match").at_css("[data-qube-search]")["data-qube-search"]).to eq("/qube/storyboard/near_match/search")
    expect(panel.call("failed").at_css(".qube-storyboard-files").text)
      .to include("app/views/qube_rails/run_status/_status.html.erb", "app/views/qube_rails/run_status/_detail.html.erb")
  end

  it "renders every piece the engine has, and names each as an override path" do
    shown = page
    named = shown.css(".qube-storyboard-files code").map(&:text).uniq
    pieces = Dir[File.join(engine_views, "{question,run_status}/**/_*.html.erb")] + [File.join(engine_views, "_error.html.erb")]

    pieces.each do |file|
      expect(named).to include("app/views/qube_rails/#{file.delete_prefix("#{engine_views}/")}")
    end
  end

  it "shows each question's choices by kind, at most one filled button, and no submit disabled in the markup" do
    shown = page
    panel = ->(key) { shown.at_css("[data-qube-storyboard='#{key}']") }
    kinds = ->(key) { panel.call(key).css("form[data-qube-choice]").map { |f| [f["data-qube-choice"], f["data-qube-choice-kind"]] } }

    expect(kinds.call("near_match")).to eq([%w[use:1 pick], %w[use form], %w[none exit], %w[cancel exit]])
    expect(panel.call("near_match").at_css(".qube-picks + .qube-choice-divider + form.qube-choice-form")).not_to be_nil
    expect(panel.call("near_match").at_css(".qube-choice-footer form[data-qube-choice=none]")).not_to be_nil
    expect(panel.call("choose").css("[data-qube-button=primary]")).to be_empty
    QubeRails::Storyboard::QUESTIONS.each do |key|
      expect(panel.call(key).css("[data-qube-button=primary]").size).to be <= 1, key
    end
    expect(shown.css(".qube-question button[disabled], .qube-question input[type=submit][disabled]")).to be_empty
  end

  it "shows one screen" do
    shown = page("/qube/storyboard/rows")

    expect(shown.css("[data-qube-storyboard]").map { |p| p["data-qube-storyboard"] }).to eq(["rows"])
    get "/qube/storyboard/nope", headers: signed_in
    expect(response).to have_http_status(:not_found)
  end

  it "answers a search from the samples" do
    get "/qube/storyboard/rows/search", params: { field: "records.income_account", q: "sales", row: "customer_ref" },
                                        headers: signed_in

    expect(JSON.parse(response.body).map { |m| m["label"] }).to eq(["Sales", "Sales:Signs"])
  end

  it "sends nothing for an answer, and says so" do
    post "/qube/storyboard/name_clash/answer", params: { choice: "rename", data: { name: "x" } }, headers: signed_in

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to("/qube/storyboard/name_clash")
    expect(page("/qube/storyboard/name_clash").at_css(".qube-storyboard-notice").text).to eq("Storyboard: nothing was sent.")
  end

  it "is behind the app's sign-in" do
    get "/qube/storyboard"

    expect(response).to have_http_status(:unauthorized)
  end

  it "is not there when config.storyboard is false, as by default outside development" do
    QubeRails.reset!
    configure_qube_rails
    expect(QubeRails.config.storyboard).to be(false)

    get "/qube/storyboard", headers: signed_in
    expect(response).to have_http_status(:not_found)
    get "/qube/storyboard/rows/search", params: { field: "records.list_id", q: "lo" }, headers: signed_in
    expect(response).to have_http_status(:not_found)
    post "/qube/storyboard/rows/answer", headers: signed_in
    expect(response).to have_http_status(:not_found)
  end
end
