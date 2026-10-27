# frozen_string_literal: true

RSpec.describe QubeRails::JSONCoder do
  it "round-trips a Hash through text, and nil as nil" do
    expect(described_class.load(described_class.dump("a" => [1, { "b" => nil }]))).to eq("a" => [1, { "b" => nil }])
    expect(described_class.dump(nil)).to be_nil
    expect(described_class.load(nil)).to be_nil
    expect(described_class.load("")).to be_nil
  end

  it "keeps a run's question and links as text in the database" do
    account = Account.create!(name: "Riverbend")
    run = make_run(Invoice.create!(account: account), make_connection(account))
    run.update!(question: { "token" => "t" }, links: { "decisions" => "d" })

    raw = ActiveRecord::Base.connection.select_value("SELECT question FROM qube_runs WHERE id = #{run.id}")
    expect(raw).to eq('{"token":"t"}')
    expect(QubeRails::Run.find(run.id).question).to eq("token" => "t")
    expect(QubeRails::Run.columns_hash["question"].type).to eq(:text)
  end
end
