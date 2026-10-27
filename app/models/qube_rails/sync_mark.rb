# frozen_string_literal: true

module QubeRails
  # When a connection's last completed run of a workflow started (Connection#last_synced_at).
  class SyncMark < ApplicationRecord
    self.table_name = "qube_sync_marks"

    belongs_to :connection, class_name: "QubeRails::Connection"

    # Moves the mark to started_at, never back: runs can complete out of order.
    def self.advance(connection, workflow, started_at)
      mark = find_or_create_by!(connection_id: connection.id, workflow: workflow) do |made|
        made.started_at = started_at
      end
      where(id: mark.id).where("started_at < ?", started_at)
                        .update_all(started_at: started_at, updated_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
