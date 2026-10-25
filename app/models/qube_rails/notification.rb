# frozen_string_literal: true

module QubeRails
  # A notification a run's handler has taken, by its delivery_id: QubeRails::DatabaseDedupe
  # writes it in the same transaction as the handler, so a redelivery is skipped and a handler
  # that raised runs again. Deleted with its run.
  class Notification < ApplicationRecord
    self.table_name = "qube_notifications"

    belongs_to :run, class_name: "QubeRails::Run"
  end
end
