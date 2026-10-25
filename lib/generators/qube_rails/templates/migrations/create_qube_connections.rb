class CreateQubeConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :qube_connections do |t|
      t.references :<%= options[:parent_model].underscore %>, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :qube_id, null: false
      t.string :name
      t.string :onboarding_url, limit: 2048
      t.string :qb_company_name
      t.string :qb_company_file
      t.boolean :is_connected, default: false
      t.datetime :last_sync_at

      t.timestamps
    end
  end
end