# frozen_string_literal: true

# For a connection switched to another company file (connection.company_file_changed): when it
# was, so runs from before it stop counting, and the revision of the change applied last; which
# QuickBooks links are the old file's until they're checked against the new one (stale_since),
# which the new file doesn't have (missing_since: kept, unused, checked again on the next change),
# and which it has under another name (review_since, review_name: unused until the app decides).
class AddQubeCompanyFileChange < ActiveRecord::Migration[5.2]
  def change
    add_column :qube_connections, :company_file_changed_at, :datetime
    add_column :qube_connections, :company_file_revision, :integer
    add_column :qube_quickbooks_records, :stale_since, :datetime
    add_column :qube_quickbooks_records, :missing_since, :datetime
    add_column :qube_quickbooks_records, :review_since, :datetime
    add_column :qube_quickbooks_records, :review_name, :string
  end
end
