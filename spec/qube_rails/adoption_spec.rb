# frozen_string_literal: true

RSpec.describe "Adopting QuBe Sync's connection for a row without a qube_id" do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:row) { QubeRails::Connection.create!(owner: account, status: "pending", name: "Main file") }

  def listing(*connections)
    stub_request(:get, api_url("/connections")).to_return(json_data(connections))
  end

  it "adopts the one connection made for the row: its webhook URL, never connected, made after it" do
    listing(qube_connection_for(row))

    expect(row.adopt_qube_connection).to eq("conn-q-lost")
    expect(row.reload.qube_id).to eq("conn-q-lost")
  end

  it "skips a connection made before the row (a row id used again)" do
    listing(qube_connection_for(row, "created_at" => (row.created_at - 3600).utc.iso8601))

    expect(row.adopt_qube_connection).to be_nil
  end

  it "allows five minutes of clock difference" do
    listing(qube_connection_for(row, "created_at" => (row.created_at - 240).utc.iso8601))

    expect(row.adopt_qube_connection).to eq("conn-q-lost")
  end

  it "never adopts a connection with no created_at (an older server), and logs it once" do
    listing(qube_connection_for(row, "created_at" => nil), qube_connection_for(row, "id" => "conn-q-2", "created_at" => nil))

    expect(row.adopt_qube_connection).to be_nil
    expect(log_output.scan("carry no created_at").size).to eq(1)
  end

  it "skips one that has connected" do
    listing(qube_connection_for(row, "last_connected_at" => Time.now.utc.iso8601))

    expect(row.adopt_qube_connection).to be_nil
  end

  it "adopts a simulated one, which connects as it's made" do
    listing(qube_connection_for(row, "type" => "simulated", "last_connected_at" => Time.now.utc.iso8601))

    expect(row.adopt_qube_connection).to eq("conn-q-lost")
  end

  it "skips one whose name isn't the row's" do
    listing(qube_connection_for(row, "name" => "Another file"))

    expect(row.adopt_qube_connection).to be_nil
  end

  it "takes any name when the row has none" do
    row.update!(name: nil)
    listing(qube_connection_for(row, "name" => "Riverbend Electric"))

    expect(row.adopt_qube_connection).to eq("conn-q-lost")
  end

  it "skips one with another webhook URL" do
    listing(qube_connection_for(row, "webhook_url" => "https://elsewhere.example/webhooks/qube/connections/1"))

    expect(row.adopt_qube_connection).to be_nil
  end

  it "adopts none, and says so, when two could be the row's" do
    listing(qube_connection_for(row), qube_connection_for(row, "id" => "conn-q-2"))

    expect(row.adopt_qube_connection).to be_nil
    expect(log_output).to include("2 of QuBe Sync's connections could be its; adopted none")
  end
end
