# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :accounts, force: true do |t|
    t.string :name
    t.string :qube_connection_id
    t.integer :qube_connection_revision
  end

  create_table :invoices, force: true do |t|
    t.integer :account_id
    t.string :number
    t.string :status
    t.string :txn_id
    t.string :qube_reference
    t.integer :qube_revision
    t.json :qube_question
    t.json :qube_links
  end
end
