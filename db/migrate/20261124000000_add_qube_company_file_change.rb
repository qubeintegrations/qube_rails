# frozen_string_literal: true

# For a connection switched to another company file (connection.company_file_changed): when it
# was, so runs from before it stop counting; which QuickBooks links are the old file's until
# they're checked against the new one (stale_since), which must be checked one at a time, and
# which the new file doesn't have (missing_since: kept, unused, checked again on the next change).
class AddQubeCompanyFileChange < ActiveRecord::Migration[5.2]
  def change
    add_column :qube_connections, :company_file_changed_at, :datetime
    add_column :qube_quickbooks_records, :stale_since, :datetime
    add_column :qube_quickbooks_records, :missing_since, :datetime
    add_column :qube_quickbooks_records, :check_alone, :boolean, null: false, default: false
  end
end
