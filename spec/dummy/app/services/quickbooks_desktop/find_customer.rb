# frozen_string_literal: true

module QuickbooksDesktop
  # A plain request: timed_out is left to its default (failed).
  class FindCustomer < QubeRails::Request
    OPERATION = "customer.query"
    SLUG = "find_customer"

    def self.calls
      @calls ||= []
    end

    def params
      { full_name: record.name }
    end

    def answered(event)
      self.class.calls << [:answered, event.page]
    end

    def done
      self.class.calls << [:done, queued_request.pages_answered]
    end

    def failed(event)
      self.class.calls << [:failed, event.state]
    end

    def retrying(event)
      self.class.calls << [:retrying, event.page]
    end
  end
end
