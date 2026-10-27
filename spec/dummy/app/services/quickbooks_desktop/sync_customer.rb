# frozen_string_literal: true

module QuickbooksDesktop
  # An operation with no find_record: its record comes from the run's record_type.
  class SyncCustomer < QubeRails::Operation
    WORKFLOW = "ensure_customer"
    SLUG = "sync_customer"

    def self.calls
      @calls ||= []
    end

    def input
      { name: record.name }
    end

    def ended(event)
      self.class.calls << [:ended, record]
    end
  end
end
