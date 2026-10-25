# frozen_string_literal: true

# QuBe Sync's three tables (qube_rails): your customers' connections, the runs your app starts,
# and the QuickBooks ids it learns, each against its connection. Your own tables need nothing.
#
# The polymorphic ids (owner_id, record_id) are strings, so integer and UUID keys both fit.
# input (what the run was started with, so a start can be resent unchanged), question and links
# are JSON kept as text (QubeRails::JSONCoder says why). The 100-character
# limits keep the composite indexes inside MySQL's 3072-byte key limit under utf8mb4.
class CreateQubeTables < ActiveRecord::Migration[5.2]
  def change
    create_table :qube_connections do |t|
      t.string :owner_type, null: false, limit: 100
      t.string :owner_id, null: false
      t.string :qube_id
      t.string :name
      t.string :status, null: false, default: "pending"
      t.string :stall_reason
      t.integer :revision
      t.timestamps null: false
    end
    add_index :qube_connections, :qube_id, unique: true, name: "index_qube_connections_on_qube_id"
    add_index :qube_connections, [:owner_type, :owner_id], name: "index_qube_connections_on_owner"

    create_table :qube_runs do |t|
      t.bigint :connection_id, null: false
      t.string :operation, null: false, limit: 100
      t.string :record_type, null: false, limit: 100
      t.string :record_id, null: false
      t.string :reference, null: false
      t.string :qube_run_id
      t.text :input
      t.integer :revision, null: false, default: 0
      t.string :state, null: false, default: "starting"
      t.string :outcome
      t.text :question
      t.text :links
      t.string :run_url
      t.string :cancel_url
      t.timestamps null: false
    end
    add_index :qube_runs, :reference, unique: true, name: "index_qube_runs_on_reference"
    add_index :qube_runs, :connection_id, name: "index_qube_runs_on_connection_id"
    add_index :qube_runs, [:record_type, :record_id, :operation, :created_at],
              name: "index_qube_runs_on_record_and_operation"
    add_foreign_key :qube_runs, :qube_connections, column: :connection_id

    create_table :qube_quickbooks_records do |t|
      t.bigint :connection_id, null: false
      t.string :kind, null: false, limit: 100
      t.string :list, null: false, limit: 100
      t.string :qb_id, null: false, limit: 100
      t.string :edit_sequence
      t.string :name
      t.string :record_type, limit: 100
      t.string :record_id
      t.timestamps null: false
    end
    # A ListID is unique within its list family (QubeRails::QuickbooksRecord.family_for), not
    # within one kind: every item type shares a counter, and so do customers, vendors, employees
    # and other names.
    add_index :qube_quickbooks_records, [:connection_id, :list, :qb_id], unique: true,
              name: "index_qube_quickbooks_records_on_qb_id"
    add_index :qube_quickbooks_records, [:connection_id, :kind, :record_type, :record_id], unique: true,
              name: "index_qube_quickbooks_records_on_record"
    add_foreign_key :qube_quickbooks_records, :qube_connections, column: :connection_id
  end
end
