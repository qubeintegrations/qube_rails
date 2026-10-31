# frozen_string_literal: true

# A connection's type ("realtime", "standard" or "simulated"), as onboarding made it and its events
# say since: Operation.start refuses a standard one before sending anything. Rows from 0.2.0 get
# "realtime", the default onboarding made then; the connection's next event corrects one that isn't.
class AddQubeConnectionType < ActiveRecord::Migration[5.2]
  def change
    add_column :qube_connections, :connection_type, :string, null: false, default: "realtime", limit: 20
  end
end
