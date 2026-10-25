# frozen_string_literal: true

module QubeRails
  # The base of the engine's models. Their tables are qube_connections, qube_runs,
  # qube_notifications and qube_quickbooks_records, from the engine's migration
  # (`bin/rails qube_rails:install:migrations`).
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # The type and id a polymorphic column keeps for record: its base class's name (as Rails
    # writes it) and its id as a string, so an app's integer and UUID keys both fit.
    def self.key_for(record)
      [record.class.base_class.name, record.id.to_s]
    end
  end
end
