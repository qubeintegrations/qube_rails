# frozen_string_literal: true

# Plain v2 requests your app queues (QubeRails::Request), and the deliveries each has taken, by
# page_request_id and state. params and error are JSON kept as text; never a response body.
class CreateQubeRequests < ActiveRecord::Migration[5.2]
  def change
    create_table :qube_requests do |t|
      t.bigint :connection_id, null: false
      t.string :operation, null: false, limit: 100
      t.string :record_type, null: false, limit: 100
      t.string :record_id, null: false
      t.string :reference, null: false
      t.string :qube_id
      t.string :state, null: false, default: "queued", limit: 50
      t.text :params
      t.text :error
      t.integer :pages_answered, null: false, default: 0
      t.integer :last_page
      t.datetime :ended_at
      t.timestamps null: false
    end
    add_index :qube_requests, :reference, unique: true, name: "index_qube_requests_on_reference"
    add_index :qube_requests, [:connection_id, :record_type, :record_id, :operation, :created_at],
              name: "index_qube_requests_on_connection_and_record"
    add_foreign_key :qube_requests, :qube_connections, column: :connection_id

    create_table :qube_request_deliveries do |t|
      t.bigint :request_id, null: false
      t.string :dedupe_key, null: false, limit: 200
      t.integer :page
      t.string :state, null: false, limit: 50
      t.datetime :created_at, null: false
    end
    add_index :qube_request_deliveries, [:request_id, :dedupe_key], unique: true,
              name: "index_qube_request_deliveries_on_request_and_key"
    add_foreign_key :qube_request_deliveries, :qube_requests, column: :request_id, on_delete: :cascade
  end
end
