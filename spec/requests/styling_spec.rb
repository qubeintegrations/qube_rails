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
    # The first offered record's "Use this one"; a pick's row is never a `button` piece. The
    # search's submit, primary too, is hidden until a match is picked.
    expect(shown.css(".btn-primary:not([hidden])").size).to eq(1)
    expect(shown.at_css("form[data-qube-choice='use:1'] .qube-pick-action")["class"])
      .to eq("qube-pick-action qube-choice-button btn btn-primary")
    expect(shown.at_css("form[data-qube-choice=use] button[type=submit]:not([form])")["class"]).to eq("qube-choice-button btn btn-primary")
    expect(shown.at_css("form[data-qube-choice='use:1'] button")["class"]).to eq("qube-pick")
    expect(shown.at_css("form[data-qube-choice=none] button")["class"]).to eq("qube-choice-button btn btn-link")
    # Cancel is a ghost: with no button_ghost piece it takes no host class (the engine's look)
    expect(shown.at_css("form[data-qube-choice=cancel] button")["class"]).to eq("qube-choice-button")
    expect(shown.at_css("[data-qube-branch=offered]")["class"]).to eq("qube-choice-button qube-branch-back")
    expect(shown.at_css("[data-qube-branch=search]")["class"]).to eq("qube-choice-button btn btn-link")
    expect(shown.at_css("input.qube-search-input.form-control")).not_to be_nil
    expect(shown.at_css("label.qube-label.form-label")).not_to be_nil
    expect(shown.at_css("[data-qube-search]")["data-qube-result-class"]).to eq("qube-search-result list-group-item")
    expect(shown.at_css(".qube-run-status")["class"]).to include("qube-sync-needs_answer", "alert")
  end

  it "takes the choice pieces' classes: picks, pick, pick_detail, button_ghost, choice_footer, choice_divider" do
    QubeRails.config.ui_classes = { button: "btn", button_secondary: "btn-2", button_ghost: "btn-link", picks: "list",
                                    pick: "list-item", pick_detail: "muted", choice_footer: "actions",
                                    choice_divider: "or" }
    asking(prompt)
    shown = page

    expect(shown.at_css(".qube-picks.list form[data-qube-choice='use:1'] button.qube-pick.list-item .qube-pick-detail.muted"))
      .not_to be_nil
    expect(shown.at_css(".qube-choice-divider.or")).to be_nil # the search is a branch of its own, after the picks
    expect(shown.at_css("[data-qube-branch=offered]")["class"]).to eq("qube-choice-button qube-branch-back btn-link")
    expect(shown.at_css(".qube-choice-footer.actions form[data-qube-choice=none] button")["class"]).to eq("qube-choice-button btn-2")
    expect(shown.at_css(".qube-choice-footer.actions form[data-qube-choice=cancel] button")["class"])
      .to eq("qube-choice-button btn-link")
  end

  it "leaves no inline script, and includes the behaviour script and the stylesheet from the layout" do
    rows = QubeRails::Storyboard.find("rows").sample["prompt"]
    asking(rows)
    shown = page

    expect(shown.at_css("[data-qube-rows] .qube-rows [data-qube-row]")).not_to be_nil
    expect(shown.css("script:not([src])")).to be_empty
    expect(shown.at_css("script[src*='qube_rails/question']")["defer"]).not_to be_nil
    expect(shown.at_css("link[rel=stylesheet][href*='qube_rails']")).not_to be_nil
    # Under Turbo Drive a changed asset reloads the page rather than keeping the old script
    expect(shown.at_css("script[src*='qube_rails/question']")["data-turbo-track"]).to eq("reload")
    expect(shown.at_css("link[rel=stylesheet][href*='qube_rails']")["data-turbo-track"]).to eq("reload")
  end

  it "serves the script and the stylesheet through the app's asset pipeline" do
    shown = page

    get shown.at_css("script[src*='qube_rails/question']")["src"]
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('document.addEventListener("input"', "[data-qube-search-input]",
                                      "[data-qube-set-all]", "[data-qube-use-for-all]")
    expect(response.body).not_to match(/\.qube-[a-z-]+["']/) # keyed on data-qube-*, not classes

    get shown.at_css("link[href*='qube_rails']")["href"]
    expect(response).to have_http_status(:ok)
    selectors = response.body.gsub(%r{/\*.*?\*/}m, "").scan(/^([^{}\n][^{}]*)\{/).flatten.map(&:strip)
    expect(selectors).not_to be_empty
    rules = selectors.reject { |s| s.start_with?("@") || %w[from to].include?(s) } # at-rules, keyframe stops
    expect(rules.reject { |s| s.start_with?(":where(") }).to eq([]) # zero specificity throughout
    expect(response.body).not_to match(/transition:\s*all|scale\(0\)/)
    row_rules = response.body.gsub(%r{/\*.*?\*/}m, "").scan(/([^{}]*)\{([^{}]*)\}/).select { |sel, _| sel.include?("row") }
    expect(row_rules).not_to be_empty
    expect(row_rules.map(&:last).grep(/overflow(-x)?:\s*(auto|scroll)/)).to eq([]) # a rows field never scrolls sideways
    %w[--qube-accent --qube-border --qube-radius --qube-gap --qube-font --qube-muted --qube-error --qube-surface].each do |name|
      expect(response.body).to include("var(#{name}")
    end
  end

  it "lets a form choice's fields fill its column, after the rules that cap their width" do
    css = File.read(QubeRails::Engine.root.join("app/assets/stylesheets/qube_rails.css")).gsub(%r{/\*.*?\*/}m, "")
    cap = css.rindex(/max-width: 28rem/)
    fill = css.index(/:where\(\.qube-choice-form\) :where\(\.qube-input[^{]*\{\s*max-width: none/)

    expect(fill).not_to be_nil
    expect(fill).to be > cap
  end

  # Every rule has zero specificity, so a later rule wins: hidden buttons, choices and a chain's
  # branch not on show stay hidden only after the rules that give them a display.
  it "keeps what's hidden hidden, in the layer's last rule, after the rules that show it" do
    css = File.read(QubeRails::Engine.root.join("app/assets/stylesheets/qube_rails.css")).gsub(%r{/\*.*?\*/}m, "")
    last = <<~CSS.strip.gsub(/^/, "  ")
      :where([data-qube-needs-script][hidden]),
      :where([data-qube-branch-part][hidden]),
      :where(.qube-choice-button[hidden]),
      :where(.qube-choice[hidden]) {
        display: none;
      }
    CSS

    expect(css.rstrip.delete_suffix("}").rstrip).to end_with(last)
    expect(css.index(/:where\(\.qube-choice-button, [^{]*\{[^}]*display: inline-flex/)).not_to be_nil
    # Its parts' grids and the footer's flex come before it
    expect(css.index(/:where\(\.qube-choice\) \{\s*display: grid/)).not_to be_nil
    expect(css.index(/:where\(\.qube-picks\) \{\s*display: grid/)).not_to be_nil
  end

  it "keeps a search's note with no matches in flow under the box, after the rules that float it" do
    css = File.read(QubeRails::Engine.root.join("app/assets/stylesheets/qube_rails.css")).gsub(%r{/\*.*?\*/}m, "")
    floats = css.index(/:where\(\.qube-search-results\) \{\s*position: absolute/)
    inline = css.index(/:where\(\.qube-search-results:has\(> \[data-qube-search-note\]\):not\(:has\(\[data-qube-search-result\]\)\)\) \{\s*position: static/)
    note = css.index(/:where\(\.qube-search-results \[data-qube-search-note\]\) \{/)
    flush = css.index(/:where\(\.qube-search-results:not\(:has\(\[data-qube-search-result\]\)\) > \[data-qube-search-note\]\) \{\s*padding: 6px 0 0/)

    expect([floats, inline, note, flush]).to all(be_a(Integer))
    expect(inline).to be > floats
    expect(flush).to be > note
  end

  # Tailwind v4 puts preflight in @layer base and utilities in @layer utilities. Unlayered, the
  # engine's rules beat every utility class; in "components", declared in Tailwind's order before
  # anything else, they beat preflight and lose to utilities and to any unlayered app CSS.
  it "puts every rule in the components layer, after declaring Tailwind's layer order" do
    css = File.read(QubeRails::Engine.root.join("app/assets/stylesheets/qube_rails.css")).gsub(%r{/\*.*?\*/}m, "").strip

    expect(css).to start_with("@layer theme, base, components, utilities;\n\n@layer components {\n")
    expect(css).to end_with("}")
    body = css.delete_prefix("@layer theme, base, components, utilities;").strip.delete_prefix("@layer components {")
    expect(body.scan(/^\S/)).to eq(["}"]) # nothing outside the layer block
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
