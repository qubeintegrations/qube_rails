# frozen_string_literal: true

# Styling the engine's screens: class hooks, the behaviour script and stylesheet through the
# asset pipeline (Propshaft in the dummy app), and an app's own piece winning over the engine's.
RSpec.describe "Styling the screens", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:signed_in) { { "X-Account" => account.id.to_s } }
  let(:prompt) { JSON.parse(vector_body("workflow_run.awaiting_input"))["prompt"] }

  def page(path = "/invoices/#{invoice.id}")
    get path, headers: signed_in
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def asking(question)
    make_run(invoice, connection).tap do |run|
      run.update!(state: "awaiting_input", question: question, links: { "decisions" => "d", "search" => "s" })
    end
  end

  it "adds config.ui_classes beside the qube- classes" do
    QubeRails.config.ui_classes = { question: "card", button: %w[btn btn-primary], button_secondary: "btn btn-link",
                                    input: "form-control", status: "alert", label: "form-label",
                                    search_result: "list-group-item" }
    asking(prompt)
    shown = page

    expect(shown.at_css("section.qube-question.card")).not_to be_nil
    expect(shown.css("button.qube-choice-button.btn.btn-primary").size).to eq(3)
    expect(shown.at_css("form[data-qube-choice=cancel] button")["class"]).to eq("qube-choice-button btn btn-link")
    expect(shown.at_css("input.qube-search-input.form-control")).not_to be_nil
    expect(shown.at_css("label.qube-label.form-label")).not_to be_nil
    expect(shown.at_css("[data-qube-search]")["data-qube-result-class"]).to eq("qube-search-result list-group-item")
    expect(shown.at_css(".qube-run-status")["class"]).to include("qube-sync-needs_answer", "alert")
  end

  it "leaves no inline script, and includes the behaviour script and the stylesheet from the layout" do
    rows = QubeRails::Storyboard.find("rows").sample["prompt"]
    asking(rows)
    shown = page

    expect(shown.at_css(".qube-rows table")).not_to be_nil
    expect(shown.css("script:not([src])")).to be_empty
    expect(shown.at_css("script[src*='qube_rails/question']")["defer"]).not_to be_nil
    expect(shown.at_css("link[rel=stylesheet][href*='qube_rails']")).not_to be_nil
  end

  it "serves the script and the stylesheet through the app's asset pipeline" do
    shown = page

    get shown.at_css("script[src*='qube_rails/question']")["src"]
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('document.addEventListener("input"', "[data-qube-search-input]",
                                      "[data-qube-rows-pick]", "[data-qube-bulk-apply]")
    expect(response.body).not_to match(/\.qube-[a-z-]+["']/) # keyed on data-qube-*, not classes

    get shown.at_css("link[href*='qube_rails']")["href"]
    expect(response).to have_http_status(:ok)
    selectors = response.body.gsub(%r{/\*.*?\*/}m, "").scan(/^([^{}\n][^{}]*)\{/).flatten.map(&:strip)
    expect(selectors).not_to be_empty
    rules = selectors.reject { |s| s.start_with?("@") || %w[from to].include?(s) } # at-rules, keyframe stops
    expect(rules.reject { |s| s.start_with?(":where(") }).to eq([]) # zero specificity throughout
    expect(response.body).not_to match(/transition:\s*all|scale\(0\)/)
    %w[--qube-accent --qube-border --qube-radius --qube-gap --qube-font --qube-muted --qube-error --qube-surface].each do |name|
      expect(response.body).to include("var(#{name}")
    end
  end

  it "renders an app's own piece instead of the engine's, from the view-model alone" do
    asking(QubeRails::Storyboard.find("number_boolean").sample["prompt"])
    expect(page.at_css("input.qube-checkbox[name='data[allow_negative]']")).not_to be_nil

    overrides = Rails.root.join("app/views_overrides").to_s
    saved = ActionController::Base.view_paths
    ActionController::Base.prepend_view_path(overrides)
    begin
      shown = page
      expect(shown.at_css(".app-toggle[data-app-field=allow_negative] input[name='data[allow_negative]']")).not_to be_nil
      expect(shown.at_css(".qube-checkbox")).to be_nil
      expect(shown.at_css("input.qube-input[name='data[quantity]']")).not_to be_nil # the other pieces stay the engine's
    ensure
      ActionController::Base.view_paths = saved
    end
  end

  it "posts the same names as before: choice and data[...]" do
    asking(prompt)
    form = page.css("form.qube-choice")[1]

    expect(form.css("input[name]").map { |i| i["name"] }).to eq(%w[authenticity_token choice data[list_id]])
  end
end
