# frozen_string_literal: true

# Offered records show all at once: the records, a decline that says what it is as a row among
# them, a search box under them whose pick waits as a row of its own, and cancel in the footer.
# A name clash leads with the existing record, the rename behind "or add it under another name…".
# (This replaces the stepped ask, which showed offered records and their search a branch at a time.)
RSpec.describe "A question's offered records, decline and search, at once", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:signed_in) { { "X-Account" => account.id.to_s } }
  let(:decisions) { "https://qube.example/api/v2/connections/c/workflow-runs/r/decisions?prompt_token=tok" }

  def sample(key)
    QubeRails::Storyboard.find(key).sample["prompt"].merge("token" => "tok")
  end

  def asking(question)
    make_run(invoice, connection).tap do |run|
      run.update!(state: "awaiting_input", question: question, links: { "decisions" => decisions, "search" => "s" })
    end
  end

  def page
    get "/invoices/#{invoice.id}", headers: signed_in
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  # What shows without the script: nothing hidden, nor inside something hidden.
  def shown_without_script(doc, selector)
    doc.css(selector).reject { |el| el["hidden"] || el.ancestors.any? { |a| a.respond_to?(:[]) && a["hidden"] } }
  end

  def text(node)
    node.text.strip.gsub(/\s+/, " ")
  end

  it "shows a near match's record and add-as-new as rows of equal weight, the search box under them" do
    asking(sample("near_match"))
    shown = page
    choices = shown.at_css(".qube-question .qube-choices")

    expect(choices.element_children.map { |el| [el.name, el["class"]] })
      .to eq([%w[div qube-picks], ["form", "qube-choice qube-search-inline"], %w[div qube-choice-footer]])
    rows = choices.css(".qube-picks[role=list] > form[data-qube-choice-kind=pick]")
    expect(rows.map { |f| [f["data-qube-choice"], f["data-qube-choice-role"], f.key?("hidden")] })
      .to eq([["use:1", "pick", false], ["use", "search", true], ["none", "decline", false]])

    decline = rows.last
    expect(text(decline.at_css(".qube-pick-label"))).to eq("Riverbend")
    expect(text(decline.at_css(".qube-pick-line"))).to eq("new customer in QuickBooks")
    expect(text(decline.at_css(".qube-pick-action"))).to eq("Add as new")
    expect(shown.css(".qube-picks [data-qube-button]").map { |b| b["data-qube-button"] }.uniq).to eq(["secondary"])
    expect(shown.css("[data-qube-button=primary]")).to be_empty

    # The search: its box alone, "Search QuickBooks…", not required, no submit
    search = choices.at_css("> form.qube-search-inline[data-qube-choice=use][data-qube-choice-role=search]")
    input = search.at_css("input[data-qube-search-input]")
    expect([input["placeholder"], input.key?("required")]).to eq(["Search QuickBooks…", false])
    expect(search.at_css("button")).to be_nil

    # Cancel alone in the footer; no branches, no divider
    expect(choices.css(".qube-choice-footer form").map { |f| f["data-qube-choice"] }).to eq(%w[cancel])
    expect(shown.css("[data-qube-branch], [data-qube-branch-part], .qube-branch-back, .qube-choice-divider")).to be_empty
  end

  it "renders the row a pick in the search box fills, posting the search's choice with the match" do
    asking(sample("near_match"))
    slot = page.at_css(".qube-picks > form[data-qube-choice=use][data-qube-choice-kind=pick][hidden]")

    expect(slot["action"]).to eq("/qube/questions/runs/#{QubeRails::Run.last.id}")
    expect(slot.css("input[type=hidden]").map { |i| [i["name"], i["value"]] }.drop(1))
      .to eq([%w[choice use], ["data[list_id]", ""]])
    expect(slot.at_css("button[type=submit] > .qube-pick-text > .qube-pick-label + .qube-pick-detail")).not_to be_nil
    action = slot.at_css(".qube-pick-action[data-qube-button=secondary]")
    expect(text(action)).to eq("Use this one")
  end

  it "answers with the match the row holds, as the search's choice" do
    run = asking(sample("near_match"))
    answered = stub_request(:post, decisions).with(body: { choice: "use", data: { list_id: "80000002" } })
                                             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

    post "/qube/questions/runs/#{run.id}", params: { choice: "use", data: { list_id: "80000002" } },
                                            headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
    expect(answered).to have_been_requested
  end

  it "marks the search box after QuBe Sync refused the search's answer" do
    run = asking(sample("near_match"))
    stub_request(:post, decisions)
      .to_return(status: 422, body: JSON.generate("errors" => { "detail" => "that customer is inactive" }),
                 headers: { "Content-Type" => "application/json" })

    post "/qube/questions/runs/#{run.id}", params: { choice: "use", data: { list_id: "80000001" } },
                                            headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
    follow_redirect!(headers: signed_in)
    shown = Nokogiri::HTML(response.body)

    expect(shown.at_css(".qube-question .qube-error[role=alert]").text).to include("that customer is inactive")
    expect(shown.at_css("form.qube-search-inline [data-qube-search-input]")["aria-invalid"]).to eq("true")
  end

  it "keeps the first offered record the main action without a decline, the search box under them" do
    asking(sample("record_search"))
    shown = page

    expect(shown.css(".qube-picks > form").map { |f| f["data-qube-choice"] }).to eq(%w[use:1 use:2 use:3 use])
    expect(shown.css("[data-qube-button=primary]").map { |b| b.ancestors("form").first["data-qube-choice"] }).to eq(%w[use:1])
    expect(shown.at_css(".qube-picks + form.qube-search-inline[data-qube-choice=use]")).not_to be_nil
    expect(shown.css(".qube-choice-footer form").map { |f| f["data-qube-choice"] }).to eq(%w[cancel])
  end

  it "puts a decline with no row of its own just under the offered records, with their weight" do
    asking(sample("choose"))
    shown = page

    expect(shown.css(".qube-picks + .qube-choice-alongside > form").map { |f| [f["data-qube-choice"], f.at_css("button")["data-qube-button"]] })
      .to eq([%w[none secondary]])
    expect(shown.css(".qube-choice-footer form").map { |f| f["data-qube-choice"] }).to eq(%w[cancel])
    expect(shown.css("[data-qube-button=primary]")).to be_empty
  end

  it "without the script, shows the offered records, the decline and cancel as forms that post" do
    asking(sample("near_match"))
    shown = page

    expect(shown_without_script(shown, ".qube-picks form[data-qube-choice]").map { |f| f["data-qube-choice"] }).to eq(%w[use:1 none])
    expect(shown_without_script(shown, ".qube-choice-footer form").map { |f| [f["data-qube-choice"], f["method"]] })
      .to eq([%w[cancel post]])
  end

  it "leads a name clash with the existing record; the rename waits behind a disclosure" do
    asking(sample("name_clash"))
    shown = page
    row = shown.at_css(".qube-picks > form[data-qube-choice=use_existing]")

    # The record as a row: QuickBooks' name for it, its lines, its facts, "Use existing"
    expect(text(row.at_css(".qube-pick-label"))).to eq("RIVERBEND ELECTRIC")
    expect(row.css(".qube-pick-line .qube-detail-part").size).to eq(3)
    expect(row.css(".qube-pick-facts > .qube-pick-fact > .qube-pick-fact-label").map(&:text)).to eq(%w[Company Balance Added])
    expect(text(row.at_css(".qube-pick-fact"))).to eq("Company Riverbend Electric LLC")
    expect(row.at_css(".qube-pick-description")).to be_nil
    expect(text(row.at_css(".qube-pick-action[data-qube-button=primary]"))).to eq("Use existing")
    expect(shown.at_css(".qube-choice-divider")).to be_nil

    disclosure = shown.at_css(".qube-choices > details.qube-choice-disclosure[data-qube-disclosure]:not([open])")
    expect(text(disclosure.at_css("> summary.qube-choice-button[data-qube-button=ghost]"))).to eq("or add it under another name…")
    expect(disclosure.at_css("> form[data-qube-choice=rename] button[type=submit][data-qube-button=primary]")).not_to be_nil
    expect(shown.css(".qube-choice-footer form").map { |f| f["data-qube-choice"] }).to eq(%w[cancel])
  end

  it "opens the name clash's rename on what was typed when QuBe Sync refused it" do
    run = asking(sample("name_clash"))
    stub_request(:post, decisions)
      .to_return(status: 422, body: JSON.generate("errors" => { "detail" => "that name is taken" }),
                 headers: { "Content-Type" => "application/json" })

    post "/qube/questions/runs/#{run.id}", params: { choice: "rename", data: { name: "Riverbend" } },
                                            headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
    follow_redirect!(headers: signed_in)

    expect(Nokogiri::HTML(response.body).at_css("details.qube-choice-disclosure[open] input[value=Riverbend]")).not_to be_nil
  end

  it "leaves a question without offered records or a promoted row as it was" do
    prompt = sample("near_match")
    no_roles = prompt.merge("choices" => prompt["choices"].map { |c| c.except("role") })

    [sample("enum_select"), sample("refusal"), no_roles].each do |question|
      QubeRails::Run.delete_all
      asking(question)
      shown = page

      expect(shown.css(".qube-search-inline, .qube-choice-alongside, .qube-choice-disclosure")).to be_empty
      expect(shown.css(".qube-choices [hidden]:not(form[data-qube-choice-kind=exit])")).to be_empty
    end
  end
end
