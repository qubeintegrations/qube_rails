# frozen_string_literal: true

module QuickbooksDesktop
  class Connection < QubeRails::ConnectionEvents
    def self.find_record(id)
      Account.find(id)
    end

    # What each handler was called with, for the examples.
    def self.calls
      @calls ||= []
    end

    def connected(event)
      self.class.calls << [:connected, event.revision]
    end

    def setup_cancelled(event)
      self.class.calls << [:setup_cancelled, event.revision]
    end

    def stalled(event)
      self.class.calls << [:stalled, event.stall_reason]
    end

    def resumed(event)
      self.class.calls << [:resumed, event.revision]
    end
  end
end
