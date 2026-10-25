class CreateQBDCustomers < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def change
    create_table :qbd_customers do |t|
      t.string :list_id, null: false
      t.string :name, null: false
      t.string :full_name
      t.string :first_name
      t.string :last_name
      t.string :company_name
      t.string :email
      t.string :phone
      t.string :fax
      t.boolean :is_active, default: true
      t.text :notes
      t.json :bill_address
      t.json :ship_address
      t.references :qube_connection, null: false, foreign_key: { to_table: :qube_connections }

      t.timestamps
    end

    add_index :qbd_customers, [:qube_connection_id, :list_id], unique: true
    add_index :qbd_customers, :is_active
    add_index :qbd_customers, :name
  end
end