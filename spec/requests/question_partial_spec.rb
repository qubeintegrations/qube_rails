# frozen_string_literal: true

RSpec.describe "The question partial", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:prompt) { JSON.parse(vector_body("workflow_run.awaiting_input"))["prompt"] }

  def page_for(invoice)
    get "/invoices/#{invoice.id}", headers: { "X-Account" => account.id.to_s }
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  it "shows the question with a form per choice, posting to the engine's question route" do
    invoice = Invoice.create!(account: account, number: "1001", qube_question: prompt,
                              qube_links: { "decisions" => "d", "search" => "s" })
    page = page_for(invoice)
    action = "/qube/questions/create_invoice/#{invoice.id}"

    expect(page.at_css("section.qube-question .qube-question-message").text).to eq(prompt["message"])
    expect(page.at_css(".qube-question-details th").text).to eq("Customer")
    forms = page.css("form.qube-choice")
    expect(forms.map { |f| f["action"] }.uniq).to eq([action])
    expect(forms.map { |f| f.at_css("input[name=choice]")["value"] }).to eq(%w[use:1 use none cancel])
    expect(forms.first.at_css("button.qube-choice-button").text).to include("Riverbend Electric", "similar name")

    search = page.at_css(".qube-search")
    expect(search["data-qube-search"]).to eq("#{action}/search")
    expect(search["data-qube-field"]).to eq("list_id")
    expect(search.at_css("input.qube-search-value")["name"]).to eq("data[list_id]")
  end

  it "escapes what it prints" do
    invoice = Invoice.create!(account: account, number: "1001",
                              qube_question: prompt.merge("message" => "<script>alert(1)</script>"))

    expect(page_for(invoice).at_css(".qube-question-message").inner_html).to include("&lt;script&gt;")
  end

  it "shows nothing when the run isn't asking" do
    invoice = Invoice.create!(account: account, number: "1001")

    expect(page_for(invoice).at_css(".qube-question")).to be_nil
  end
end
