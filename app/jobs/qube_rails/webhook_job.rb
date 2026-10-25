# frozen_string_literal: true

module QubeRails
  # Runs each verified QuBe Sync webhook on your ActiveJob queue (Sidekiq, Solid Queue,
  # delayed_job, whichever your app uses), on config.queue: a run's event goes to its operation,
  # with its record (QubeRails::Operation#handle), and a connection's to your connection_events
  # class (QubeRails.run). It's config.enqueue's
  # default; an app with another queue sets enqueue and calls QubeRails.run from its worker.
  #
  # QuBe Sync had its 2xx when the event was enqueued, so it won't send it again: a job that
  # raises is your queue's to retry (your adapter's own retries, or retry_on in a subclass you
  # enqueue instead).
  #
  # With more than one worker, a run's events can run in any order, a later one first. handle
  # applies a run event only when its revision is newer than the last applied, under the run row's
  # lock, and takes a notification once, by its delivery_id.
  #
  # A workflow that sends notifications (pull_changes's pages) waits for each one's 2xx before it
  # sends the next. The endpoint answers at once, so they come as fast as it answers, not after
  # each is saved: see each operation's notification handler.
  class WebhookJob < ActiveJob::Base
    queue_as { QubeRails.config.queue }

    # kind is "run" or "connection", id the row's.
    def perform(kind, id, body)
      QubeRails.run(kind, id, body)
    end
  end
end
