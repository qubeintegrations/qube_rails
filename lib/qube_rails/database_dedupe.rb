# frozen_string_literal: true

module QubeRails
  # The default dedupe setting: the notification delivery ids each run has taken, in
  # qube_notifications. once runs inside the run row's lock and transaction (Operation#handle), so
  # the row and the handler's writes commit together: a redelivery finds the row and is skipped,
  # and a handler that raised rolls its row back with it, so the retry runs it again.
  class DatabaseDedupe
    # Runs the block unless run has taken delivery_id already.
    def once(run, delivery_id)
      notifications = QubeRails::Notification.where(run_id: run.id)
      # Under the run row's lock no other worker inserts for this run, so this check is enough;
      # the savepoint keeps a unique violation from a lock-free caller from aborting a
      # PostgreSQL transaction.
      return false if notifications.where(delivery_id: delivery_id.to_s).exists?

      begin
        QubeRails::Notification.transaction(requires_new: true) do
          notifications.create!(delivery_id: delivery_id.to_s)
        end
      rescue ActiveRecord::RecordNotUnique
        return false
      end
      yield
      true
    end
  end
end
