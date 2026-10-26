# frozen_string_literal: true

module QubeRails
  # Tells a record's pages to refresh once more, a few seconds after an event changed its run
  # (QubeRails.broadcast_refresh). A page still loading when the first refresh went out (the
  # redirect after "Send to QuickBooks", when the simulator asks its question at once) had no
  # subscription yet; by now it has, so a question that landed meanwhile still shows.
  class RefreshJob < ActiveJob::Base
    queue_as { QubeRails.config.queue }

    # The record was deleted since: there's no page to refresh.
    discard_on ActiveJob::DeserializationError

    def perform(record)
      QubeRails.broadcast_refresh_now(record)
    end
  end
end
