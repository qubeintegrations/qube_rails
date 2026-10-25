# frozen_string_literal: true

module QubeRails
  # Runs each verified QuBe Sync webhook on your ActiveJob queue (Sidekiq, Solid Queue,
  # delayed_job, whichever your app uses), on config.queue: a run's event goes to its operation,
  # with its record (QubeRails::Operation#handle), and a connection's to your connection_events
  # class (QubeRails.run). It's config.enqueue's
  # default; an app with another queue sets enqueue and calls QubeRails.run from its worker.
  #
  # QuBe Sync had its 2xx when the event was enqueued, so it won't send it again: a job that
  # raises is retried here, config.job_attempts times in all (10 unless set) with a growing wait,
  # since Solid Queue, GoodJob and :async don't retry a job that raises. When the attempts run
  # out it logs an error and raises, so your adapter's own handling (Sidekiq's retries and dead
  # set) sees it.
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

    # :polynomially_longer since Rails 7.1, which deprecates :exponentially_longer (the same wait).
    BACKOFF = ActiveJob.gem_version >= Gem::Version.new("7.1") ? :polynomially_longer : :exponentially_longer

    ATTEMPTS = QubeRails.config.job_attempts

    retry_on StandardError, wait: BACKOFF, attempts: ATTEMPTS do |job, error|
      kind, id = job.arguments
      QubeRails.logger.error("QuBe Sync: gave up on a webhook for #{kind} #{id} after #{ATTEMPTS} " \
                             "attempts: #{error.class}: #{error.message}")
      raise error
    end

    # kind is "run" or "connection", id the row's.
    def perform(kind, id, body)
      QubeRails.run(kind, id, body)
    end
  end
end
