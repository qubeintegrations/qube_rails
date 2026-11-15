# frozen_string_literal: true

RSpec.describe "The question partial", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account) }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:prompt) { JSON.parse(vector_body("workflow_run.awaiting_input"))["prompt"] }

  def page
    get "/invoices/#{invoice.id}", headers: { "X-Account" => account.id.to_s }
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def asking(run, question = prompt)
    run.update!(question: question, links: { "decisions" => "d", "search" => "s" })
    run
  end

  it "shows the latest run's question, with a form per choice posting to that run's route" do
    travel_to(1.hour.ago) { asking(make_run(invoice, connection), prompt.merge("message" => "An older question")) }
    latest = asking(make_run(invoice, connection))
    action = "/qube/questions/runs/#{latest.id}"
    shown = page

    expect(shown.at_css("section.qube-question .qube-question-message").text).to eq(prompt["message"])
    expect(shown.css(".qube-question").size).to eq(1)
    expect(shown.at_css(".qube-question-details")).to be_nil # nothing beside what the message says
    forms = shown.css("form.qube-choice")
    expect(forms.map { |f| f["action"] }.uniq).to eq([action])
    expect(forms.map { |f| f.at_css("input[name=choice]")["value"] }).to eq(%w[use:1 use cancel none])
    expect(forms.first.at_css("button.qube-pick").text).to include("Riverbend Electric", "similar name")

    search = shown.at_css(".qube-search")
    expect(search["data-qube-search"]).to eq("#{action}/search")
    expect(search["data-qube-field"]).to eq("list_id")
    expect(search.at_css("input.qube-search-value")["name"]).to eq("data[list_id]")
  end

  it "shows nothing when the latest run has stopped asking, even if an older one asked" do
    travel_to(1.hour.ago) { asking(make_run(invoice, connection)) }
    make_run(invoice, connection)

    expect(page.at_css(".qube-question")).to be_nil
  end

  it "escapes what it prints" do
    asking(make_run(invoice, connection), prompt.merge("message" => "<script>alert(1)</script>"))

    expect(page.at_css(".qube-question-message").inner_html).to include("&lt;script&gt;")
  end

  it "starts a select on \"Choose…\", and gives a search box its words for a question that changed" do
    asking(make_run(invoice, connection), QubeRails::Storyboard.find("enum_select").sample["prompt"])
    shown = page

    first = shown.at_css("select.qube-select option")
    expect([first["value"], first.text]).to eq(["", "Choose…"])

    asking(QubeRails::Run.last, prompt)
    expect(page.at_css("[data-qube-search]")["data-qube-text-search-changed"])
      .to eq("This question has changed. Reload the page to see the latest.")
  end

  it "puts a lone form's submit and the exits in one row: cancel at the start, the rest at the end" do
    asking(make_run(invoice, connection), QubeRails::Storyboard.find("refusal").sample["prompt"]
             .then { |p| p.merge("choices" => p["choices"] + [{ "id" => "skip", "label" => "Skip it", "fields" => [], "role" => "decline" }]) })
    shown = page
    form = shown.at_css("form[data-qube-choice=rename]")
    row = form.at_css(".qube-choice-actions")

    cancel = row.at_css(".qube-choice-actions-start > button[data-qube-exit=cancel]")
    expect(cancel["form"]).to eq(shown.at_css("form[data-qube-choice=cancel]")["id"])
    expect(cancel["data-qube-button"]).to eq("ghost")
    expect(row.css(".qube-choice-actions-end > button").map { |b| [b["data-qube-exit"], b["form"], b.text.strip] })
      .to eq([["skip", shown.at_css("form[data-qube-choice=skip]")["id"], "Skip it"], [nil, nil, "Add it under another name"]])
    # The exits' own forms are there, empty and hidden, for those buttons to submit; no footer
    expect(shown.css("form[data-qube-choice=cancel][hidden], form[data-qube-choice=skip][hidden]").size).to eq(2)
    expect(shown.at_css("form[data-qube-choice=cancel] button")).to be_nil
    expect(shown.at_css(".qube-choice-footer")).to be_nil
  end

  it "keeps the exits in their own row when there are picks, or an exit has a description" do
    asking(make_run(invoice, connection), prompt)
    shown = page
    expect(shown.at_css(".qube-choice-footer-start form[data-qube-choice=cancel] button")).not_to be_nil
    expect(shown.at_css(".qube-choice-footer-end form[data-qube-choice=none] button")).not_to be_nil
    expect(shown.at_css("[data-qube-exit]")).to be_nil

    asking(QubeRails::Run.last, QubeRails::Storyboard.find("name_clash").sample["prompt"]
             .then { |p| p.merge("choices" => [p["choices"][1], p["choices"][2].merge("description" => "Stop here.")]) })
    expect(page.at_css(".qube-choice-footer-start form[data-qube-choice=cancel] .qube-choice-description").text).to eq("Stop here.")
  end

  it "says \"(optional)\" after the label of a field that isn't required" do
    asking(make_run(invoice, connection), QubeRails::Storyboard.find("number_boolean").sample["prompt"]
             .then { |p| p.merge("choices" => [p["choices"][0].merge("fields" => [
               { "name" => "name", "type" => "string", "label" => "Name", "required" => true },
               { "name" => "note", "type" => "string", "label" => "Note" },
               { "name" => "flag", "type" => "boolean", "label" => "Taxable" }
             ])] + p["choices"][1..]) })
    shown = page
    labels = shown.css("form[data-qube-choice=adjust] label.qube-label").to_h { |l| [l["for"].split("-").last, l.at_css(".qube-optional")&.text] }

    expect(labels).to eq("name" => nil, "note" => "(optional)", "flag" => nil)
  end

  it "hides a rows field and its submit until the script shows them, and says why without it" do
    asking(make_run(invoice, connection), QubeRails::Storyboard.find("rows").sample["prompt"])
    shown = page
    form = shown.at_css("form[data-qube-choice=proceed]")

    expect(form.at_css("[data-qube-rows][data-qube-needs-script][hidden]")).not_to be_nil
    expect(form.at_css("button[type=submit]:not([form])")["hidden"]).not_to be_nil
    expect(form.at_css("button[type=submit]:not([form])")["data-qube-needs-script"]).not_to be_nil
    expect(form.at_css("noscript").text).to include("needs JavaScript")
    expect(form.at_css("button[data-qube-exit=cancel]")["hidden"]).to be_nil # cancel works without it
    # No rows field's step label "(optional)": each column says it for itself
    expect(form.css(".qube-optional")).to be_empty
  end

  it "shows nothing for a record with no runs" do
    expect(page.at_css(".qube-question")).to be_nil
  end
end
