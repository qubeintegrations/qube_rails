# frozen_string_literal: true

# When the customer last switched a connection to another company file
# (connection.company_file_changed): runs from before it say nothing about the new file.
class AddQubeConnectionCompanyFileChangedAt < ActiveRecord::Migration[5.2]
  def change
    add_column :qube_connections, :company_file_changed_at, :datetime
  end
end
