# frozen_string_literal: true

module QubeRails
  # Deletes ended runs older than config.prune_runs_after (Run.prunable), with their
  # notifications. Links and sync marks stay. Does nothing until the setting is written.
  class PruneRunsJob < ActiveJob::Base
    queue_as { QubeRails.config.queue }

    def perform
      after = QubeRails.config.prune_runs_after
      return unless after

      QubeRails::Run.prunable(older_than: after).in_batches(of: 500).delete_all
    end
  end
end
