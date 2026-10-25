class CreateQubeRequests < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def change
    create_table :qube_requests do |t|
      t.string :state, null: false
      t.string :qube_id, null: false
      t.text :request_types
      t.json :request_json
      t.json :response_json
      t.references :qube_connection, null: false, foreign_key: { to_table: :qube_connections }

      t.timestamps
    end

    add_index :qube_requests, :qube_id, unique: true
    add_index :qube_requests, :state
  end
end