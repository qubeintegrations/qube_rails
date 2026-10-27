# frozen_string_literal: true

# When each connection's last completed run of a workflow started: a sync's next since, kept
# apart from qube_runs so pruning runs never loses it.
class CreateQubeSyncMarks < ActiveRecord::Migration[5.2]
  def change
    create_table :qube_sync_marks do |t|
      t.bigint :connection_id, null: false
      t.string :workflow, null: false, limit: 100
      t.datetime :started_at, null: false
      t.timestamps
    end
    add_index :qube_sync_marks, [:connection_id, :workflow], unique: true,
              name: "index_qube_sync_marks_on_connection_and_workflow"
    add_foreign_key :qube_sync_marks, :qube_connections, column: :connection_id, on_delete: :cascade
  end
end
