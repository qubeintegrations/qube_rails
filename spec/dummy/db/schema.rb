# frozen_string_literal: true

# The app's own tables, with no QuBe columns: the engine's migration (loaded after this, in
# rails_helper) adds its three.
ActiveRecord::Schema.define do
  create_table :accounts, force: true do |t|
    t.string :name
  end

  create_table :invoices, force: true do |t|
    t.integer :account_id
    t.string :number
    t.string :status
  end

  create_table :customers, force: true do |t|
    t.integer :account_id
    t.string :name
  end
end
