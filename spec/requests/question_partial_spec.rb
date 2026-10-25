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
    expect(shown.at_css(".qube-question-details th").text).to eq("Customer")
    forms = shown.css("form.qube-choice")
    expect(forms.map { |f| f["action"] }.uniq).to eq([action])
    expect(forms.map { |f| f.at_css("input[name=choice]")["value"] }).to eq(%w[use:1 use none cancel])
    expect(forms.first.at_css("button.qube-choice-button").text).to include("Riverbend Electric", "similar name")

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

  it "shows nothing for a record with no runs" do
    expect(page.at_css(".qube-question")).to be_nil
  end
end
