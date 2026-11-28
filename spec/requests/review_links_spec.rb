# frozen_string_literal: true

# A link the new company file has under another name, settled by the customer from the
# review_links partial: "Same record" (confirm_link) or "Not the same" (reject_link).
RSpec.describe "Links under review", type: :request do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:signed_in) { { "X-Account" => account.id.to_s, "HTTP_REFERER" => "/account" } }
  let(:connection) { make_connection(account) }
  let(:customer) { Customer.create!(account: account, name: "Riverbend Electric") }

  def under_review(conn = connection, record = customer, qb_id: "80000024-1760999990")
    conn.link(record, kind: "customer", qb_id: qb_id, name: "Riverbend Electric")
        .tap { |link| link.update!(review_since: Time.now, review_name: "Riverbend Plumbing") }
  end

  def shown
    get "/account", headers: signed_in
    Nokogiri::HTML(response.body).at_css("#qube-review-links-#{connection.id}")
  end

  describe "the review_links partial" do
    it "lists each link under review with its record, old name and QuickBooks' new name, and two buttons" do
      link = under_review
      row = shown.at_css("#qube-review-link-#{link.id}")

      expect(row.at_css(".qube-review-link-text").text).to include("Riverbend Electric", "Riverbend Plumbing", "Customer")
      same = row.at_css("form.qube-confirm-link-form")
      not_same = row.at_css("form.qube-reject-link-form")
      expect(same["action"]).to eq("/quickbooks/connections/#{connection.id}/links/#{link.id}/confirm")
      expect(not_same["action"]).to eq("/quickbooks/connections/#{connection.id}/links/#{link.id}/reject")
      expect(same.at_css("button").text.strip).to eq("Same record")
      expect(not_same.at_css("button").text.strip).to eq("Not the same")
      expect(same["data-turbo"]).to be_nil # a redirect back on the same site: Turbo can stay on
    end

    it "renders nothing with no link under review" do
      connection.link(customer, kind: "customer", qb_id: "80000024-1760999990", name: "Riverbend Electric")

      expect(shown).to be_nil
    end
  end

  describe "POST /quickbooks/connections/:id/links/:link_id/confirm and /reject" do
    it "confirms a link: current again, with QuickBooks' name, and back to the page" do
      link = under_review

      post "/quickbooks/connections/#{connection.id}/links/#{link.id}/confirm", headers: signed_in

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/account")
      expect(link.reload).to have_attributes(review_since: nil, name: "Riverbend Plumbing", missing_since: nil)
      expect(connection.qb_id_for(customer, kind: "customer")).to eq("80000024-1760999990")
    end

    it "rejects a link: kept as missing, so the record is matched by name when it's next sent" do
      link = under_review

      post "/quickbooks/connections/#{connection.id}/links/#{link.id}/reject", headers: signed_in

      expect(response).to have_http_status(:see_other)
      expect(link.reload).to have_attributes(review_since: nil, name: "Riverbend Electric")
      expect(link.missing_since).not_to be_nil
      expect(connection.qb_id_for(customer, kind: "customer")).to be_nil
    end

    it "answers 404 for another account's connection, a link on another connection, or one not under review" do
      other = make_connection(Account.create!(name: "Other"), qube_id: "conn-q-2")
      theirs = under_review(other, Customer.create!(account: other.owner, name: "Theirs"))
      mine_elsewhere = make_connection(account, qube_id: "conn-q-3")
      elsewhere = under_review(mine_elsewhere, customer, qb_id: "80000030-1760999999")
      current = connection.link(Customer.create!(account: account, name: "Current"), kind: "customer", qb_id: "80000031-1")

      %w[confirm reject].each do |how|
        post "/quickbooks/connections/#{other.id}/links/#{theirs.id}/#{how}", headers: signed_in
        expect(response).to have_http_status(:not_found)
        post "/quickbooks/connections/#{connection.id}/links/#{elsewhere.id}/#{how}", headers: signed_in
        expect(response).to have_http_status(:not_found)
        post "/quickbooks/connections/#{connection.id}/links/#{current.id}/#{how}", headers: signed_in
        expect(response).to have_http_status(:not_found)
      end
      expect([theirs.reload, elsewhere.reload].map(&:review_since)).to all(be_present)
      expect(current.reload.missing_since).to be_nil
    end

    it "is behind the app's sign-in, and POST only" do
      link = under_review

      post "/quickbooks/connections/#{connection.id}/links/#{link.id}/confirm"
      expect(response).to have_http_status(:unauthorized)
      expect { get "/quickbooks/connections/#{connection.id}/links/#{link.id}/confirm", headers: signed_in }
        .to raise_error(ActionController::RoutingError)
      expect(link.reload.review_since).not_to be_nil
    end
  end
end
