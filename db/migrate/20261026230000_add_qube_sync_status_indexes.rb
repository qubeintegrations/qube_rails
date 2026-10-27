# frozen_string_literal: true

# Indexes for QubeRails::SyncStatus and the connection's scopes (in_quickbooks, not_in_quickbooks,
# needing_answer, sending): a record's link on a connection whatever its kind, and its runs of an
# operation on a connection by state. Within MySQL's 3072-byte key limit under utf8mb4.
class AddQubeSyncStatusIndexes < ActiveRecord::Migration[5.2]
  def change
    add_index :qube_quickbooks_records, [:connection_id, :record_type, :record_id],
              name: "index_qube_quickbooks_records_on_connection_and_record"
    add_index :qube_runs, [:connection_id, :record_type, :record_id, :operation, :state],
              name: "index_qube_runs_on_connection_record_and_state"
  end
end
