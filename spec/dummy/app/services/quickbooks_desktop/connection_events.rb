# frozen_string_literal: true

module QuickbooksDesktop
  class ConnectionEvents < QubeRails::ConnectionEvents
    # What each handler was called with, for the examples.
    def self.calls
      @calls ||= []
    end

    def connected(event)
      self.class.calls << [:connected, connection.id, owner.id, connection.status]
    end

    def setup_cancelled(event)
      self.class.calls << [:setup_cancelled, connection.id, owner.id, connection.status]
    end

    def stalled(event)
      self.class.calls << [:stalled, connection.id, owner.id, connection.stall_reason]
    end

    def resumed(event)
      self.class.calls << [:resumed, connection.id, owner.id, connection.stall_reason]
    end

    def company_file_changed(event)
      self.class.calls << [:company_file_changed, connection.id, owner.id, connection.status]
    end

    def links_checked(kind:, found:, relinked:, renamed:, missing:, stale_left:)
      self.class.calls << [:links_checked, kind, found, relinked.map(&:qb_id),
                           renamed.map { |r| [r[:record].id, r[:old_name], r[:new_name]] },
                           missing.map { |link| link.record.id }, stale_left]
    end
  end
end
