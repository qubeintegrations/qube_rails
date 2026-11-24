# frozen_string_literal: true

# For a connection switched to another company file (connection.company_file_changed): when it
# was, so runs from before it stop counting, and which QuickBooks links are the old file's until
# they're checked against the new one (stale_since), and which must be checked one at a time.
class AddQubeCompanyFileChange < ActiveRecord::Migration[5.2]
  def change
    add_column :qube_connections, :company_file_changed_at, :datetime
    add_column :qube_quickbooks_records, :stale_since, :datetime
    add_column :qube_quickbooks_records, :check_alone, :boolean, null: false, default: false
  end
end
