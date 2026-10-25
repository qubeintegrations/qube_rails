# frozen_string_literal: true

module QubeRails
  # Runs each verified QuBe Sync webhook on your ActiveJob queue (Sidekiq, Solid Queue,
  # delayed_job, whichever your app uses), on config.queue: the operation its URL names finds its
  # record and handles the event (QubeRails::Operation#handle), or, for a connection's own
  # events, your connection class finds the account (QubeRails.run). It's config.enqueue's
  # default; an app with another queue sets enqueue and calls QubeRails.run from its worker.
  #
  # QuBe Sync had its 2xx when the event was enqueued, so it won't send it again: a job that
  # raises is your queue's to retry (your adapter's own retries, or retry_on in a subclass you
  # enqueue instead).
  #
  # With more than one worker, a run's events can run in any order, a later one first. handle
  # applies a run event only when its revision is newer than the last applied, under the record's
  # row lock, and takes a notification once, by its delivery_id.
  #
  # A workflow that sends notifications (pull_changes's pages) waits for each one's 2xx before it
  # sends the next. The endpoint answers at once, so they come as fast as it answers, not after
  # each is saved: see each operation's notification handler.
  class WebhookJob < ActiveJob::Base
    queue_as { QubeRails.config.queue }

    def perform(operation, record_id, body)
      QubeRails.run(operation, record_id, body)
    end
  end
end
