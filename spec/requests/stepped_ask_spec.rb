# frozen_string_literal: true

# Offered records with a search (a chain) show a branch at a time: the offered records first, with
# "Not this one" / "None of these", then the search with the decline beside it and a way back.
RSpec.describe "A question's offered records and search, a branch at a time", type: :request do
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

  it "renders a chain's offered branch, and its search branch hidden for the script" do
    asking(sample("near_match"))
    shown = page
    choices = shown.at_css(".qube-question .qube-choices")

    expect(choices.element_children.map { |el| [el.name, el["data-qube-branch-part"], el.key?("hidden")] })
      .to eq([["button", "search", true], ["div", "offered", false], ["form", "search", true], ["div", "offered", false]])

    back = choices.at_css("> button.qube-branch-back[type=button][data-qube-branch=offered][data-qube-button=ghost]")
    expect(back.text).to eq("← Back to the possible match")
    expect(choices.css("> .qube-picks[role=list] > form[data-qube-choice-kind=pick]").map { |f| f["data-qube-choice"] }).to eq(%w[use:1])

    # The search's row: cancel at the start, the decline and "Use this one" at the end, the exits
    # submitting the footer's forms (no second cancel or decline form)
    search = choices.at_css("> form[data-qube-choice=use]")
    footer = choices.at_css("> .qube-choice-footer")
    cancel = footer.at_css(".qube-choice-footer-start > form[data-qube-choice=cancel]")
    decline = footer.at_css(".qube-choice-footer-end > form[data-qube-choice=none]")
    expect(search.css(".qube-choice-actions-start > button").map { |b| [b["data-qube-exit"], b["form"]] }).to eq([["cancel", cancel["id"]]])
    expect(search.css(".qube-choice-actions-end > button").map { |b| [b["data-qube-exit"], b["form"], b["data-qube-button"], b.key?("hidden")] })
      .to eq([["none", decline["id"], "secondary", false], [nil, nil, "primary", true]])
    expect(search.at_css(".qube-choice-actions-end > button[type=submit]:not([form])").text.strip).to eq("Use this one")
    expect(shown.css("form[data-qube-choice=cancel]").size).to eq(1)
    expect(shown.css("form[data-qube-choice=none]").size).to eq(1)

    # The footer ends in "Not this one", for the script to show
    expect(footer.at_css(".qube-choice-footer-end > button[type=button][data-qube-branch=search][data-qube-button=secondary][hidden]").text)
      .to eq("Not this one")
    expect(shown.css(".qube-choice-divider")).to be_empty
  end

  it "says \"None of these\" and counts the way back with several offered records" do
    asking(sample("record_search"))
    shown = page

    expect(shown.at_css("[data-qube-branch=search]").text).to eq("None of these")
    expect(shown.at_css("[data-qube-branch=offered]").text).to eq("← Back to the 3 possible matches")
    # No decline: the search's row holds cancel and its submit
    expect(shown.css("form[data-qube-choice=use] .qube-choice-actions button").map { |b| b["data-qube-exit"] }).to eq(["cancel", nil])
  end

  it "without the script, shows the offered records and a footer of cancel and the decline, as forms that post" do
    asking(sample("near_match"))
    shown = page

    expect(shown_without_script(shown, "[data-qube-branch], form[data-qube-choice=use], [data-qube-search]")).to be_empty
    expect(shown_without_script(shown, "form[data-qube-choice]").map { |f| f["data-qube-choice"] }).to eq(%w[use:1 cancel none])
    footer = shown_without_script(shown, ".qube-choice-footer").first
    expect(footer.css("form").map { |f| [f["data-qube-choice"], f["method"], f.at_css("button[type=submit]:not([form])") ? :button : nil] })
      .to eq([["cancel", "post", :button], ["none", "post", :button]])
    expect(shown_without_script(shown, "[data-qube-button=primary]").map { |b| b.text.strip }).to eq(["Use this one"])
  end

  it "starts on the search after QuBe Sync refused the search's answer" do
    run = asking(sample("near_match"))
    stub_request(:post, decisions)
      .to_return(status: 422, body: JSON.generate("errors" => { "detail" => "that customer is inactive" }),
                 headers: { "Content-Type" => "application/json" })

    post "/qube/questions/runs/#{run.id}", params: { choice: "use", data: { list_id: "80000001" } },
                                            headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
    follow_redirect!(headers: signed_in)
    shown = Nokogiri::HTML(response.body)

    expect(shown.at_css(".qube-question .qube-error[role=alert]").text).to include("that customer is inactive")
    parts = shown.css(".qube-choices > [data-qube-branch-part]").map { |el| [el["data-qube-branch-part"], el.key?("hidden")] }
    expect(parts).to eq([["search", true], ["offered", true], ["search", false], ["offered", true]]) # Back waits for the script
    expect(shown.at_css("form[data-qube-choice=use] [data-qube-search-input]")["aria-invalid"]).to eq("true")

    # A refusal of an offered record keeps the offered branch
    post "/qube/questions/runs/#{run.id}", params: { choice: "use:1" },
                                            headers: signed_in.merge("HTTP_REFERER" => "/invoices/#{invoice.id}")
    follow_redirect!(headers: signed_in)
    expect(Nokogiri::HTML(response.body).at_css(".qube-picks[data-qube-branch-part=offered]")["hidden"]).to be_nil
  end

  it "hides a search's submit until a match is picked when nothing is offered, with no branches" do
    prompt = sample("near_match")
    asking(prompt.merge("choices" => prompt["choices"].reject { |c| c["role"] == "pick" }))
    shown = page

    expect(shown.css("[data-qube-branch], [data-qube-branch-part], .qube-branch-back")).to be_empty
    form = shown.at_css(".qube-choices > form[data-qube-choice=use]:not([hidden])")
    expect(form.css(".qube-choice-actions button").map { |b| [b["data-qube-exit"], b["data-qube-button"], b.key?("hidden")] })
      .to eq([["cancel", "ghost", false], ["none", "secondary", false], [nil, "primary", true]])
    expect(shown.at_css(".qube-choice-footer")).to be_nil
  end

  it "leaves other questions as they were" do
    prompt = sample("near_match")
    no_roles = prompt.merge("choices" => prompt["choices"].map { |c| c.except("role") })

    [sample("choose"), sample("name_clash"), sample("ask_about_add"), sample("enum_select"), no_roles].each do |question|
      QubeRails::Run.delete_all
      asking(question)
      shown = page

      expect(shown.css("[data-qube-branch], [data-qube-branch-part], .qube-branch-back")).to be_empty
      expect(shown.css(".qube-choices [hidden]:not(form[data-qube-choice-kind=exit])")).to be_empty
    end
  end
end
