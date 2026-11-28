# frozen_string_literal: true

module QubeRails
  # A record's last run or plain request, made before its connection last switched company file
  # (company_file_changed_at) and not ended here: settled with QuBe Sync before the record is sent
  # again, so the old file's ids and input never go out twice. README, "Work from the old file".
  #
  # Known at QuBe Sync (a qube id, or found by its reference): cancelled there (a request
  # discarded) and ended here once QuBe Sync says it failed or was cancelled. One QuBe Sync ran to
  # the end waits for its own webhook (its links come in stale, for LinkCheck). Never known: ended
  # here once UNCONFIRMED_AFTER has passed since its last send. Otherwise OldFileWorkPending.
  # Called outside the connection's lock: it calls QuBe Sync.
  module OldFileWork
    # Seconds after its last send by which a start or queue QuBe Sync never acknowledged can't
    # still land (the client gives up after 60).
    UNCONFIRMED_AFTER = 5 * 60
    # How long a request QuickBooks answered waits for its webhook (QuBe Sync retries for ~8 hours)
    # before it's ended here without it.
    DELIVERY_WINDOW = 24 * 60 * 60
    REASON = "The connection was switched to another company file."
    RUN_ENDED = %w[completed failed cancelled].freeze
    REQUEST_ENDED = %w[response_received error timed_out discarded].freeze
    REQUEST_WAITING = %w[waiting retryable].freeze

    module_function

    def old?(row, connection)
      !row.nil? && !row.ended? && connection.before_company_file_change?(row)
    end

    # Ends run here once QuBe Sync confirms it's over, or raises OldFileWorkPending.
    def settle_run(run, connection)
      return unless old?(run, connection)
      return end_run(run, "cancelled") if run.realtime_required? # QuBe Sync stored nothing

      remote = run.qube_run_id ? nil : find_by_reference(run, connection)
      if run.qube_run_id.nil? && remote.nil?
        return end_run(run, "cancelled") if last_sent(run) < Time.now - UNCONFIRMED_AFTER

        pending!(run, "its start may still reach QuBe Sync")
      end
      remote = run.cancel_url ? cancel_run(run, connection, run.cancel_url) : (remote || read_run(run, connection))
      if remote && !RUN_ENDED.include?(remote["state"]) && run.cancel_url.nil?
        url = remote["links"].is_a?(Hash) ? remote["links"]["cancel"] : nil
        remote = cancel_run(run, connection, url) if url
      end
      return end_run(run, "cancelled") if remote.nil? # QuBe Sync no longer has it
      return await_ending(run, connection) if remote["state"] == "completed"
      return end_run(run, remote["state"]) if RUN_ENDED.include?(remote["state"])

      pending!(run, "QuBe Sync hasn't ended it yet")
    rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
      pending!(run, "QuBe Sync didn't answer (#{e.class})")
    end

    # Ends row here once QuBe Sync confirms it's over (or discards it), or raises OldFileWorkPending.
    def settle_request(row, connection)
      return unless old?(row, connection)

      unless row.qube_id
        return end_row(row, "failed", nil) if last_sent(row) < Time.now - UNCONFIRMED_AFTER

        pending!(row, "its queue may still reach QuBe Sync")
      end
      remote = request_at_qube(row, connection)
      if remote && REQUEST_WAITING.include?(remote["state"])
        QubeRails.client.discard_request(connection.qube_id, row.qube_id)
        remote = request_at_qube(row, connection)
      end
      return end_row(row, "failed", nil) if remote.nil? # QuBe Sync no longer has it
      if remote["state"] == "response_received" && last_sent(row) > Time.now - DELIVERY_WINDOW
        pending!(row, "QuickBooks answered it; its webhook brings the answer")
      end
      return end_row(row, remote["state"], remote["error"]) if REQUEST_ENDED.include?(remote["state"])

      pending!(row, "QuickBooks has it (#{remote["state"]})")
    rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
      pending!(row, "QuBe Sync didn't answer (#{e.class})")
    end

    # A run QuBe Sync completed: its ending webhook is asked for again, and the record waits for it,
    # since the run may have added it to the file the connection opens now.
    def await_ending(run, connection)
      begin
        QubeRails.client.redeliver_run(connection.qube_id, run.qube_run_id)
      rescue Backend::APIError => e
        raise unless [409, 429].include?(e.status)
      end
      pending!(run, "QuBe Sync completed it; waiting for its ending")
    end

    def last_sent(row)
      [row.created_at, row.updated_at].compact.max
    end

    # After an old file's event wrote links stale: checked at once when the connection is connected.
    def check_held_links(connection)
      connection = connection.reload
      LinkCheck.start(connection) if connection.connected? && connection.stale_links.exists?
    rescue Backend::APIError, OldFileWorkPending, *Backend::NETWORK_ERRORS => e
      QubeRails.logger.warn("QuBe Sync: connection #{connection.id}: couldn't check the links an old run wrote (#{e.class})")
    end

    def find_by_reference(run, connection)
      found = Array(QubeRails.client.list_runs(connection.qube_id, reference: run.reference))
              .find { |made| made.is_a?(Hash) && made["reference"] == run.reference }
      return nil unless found

      links = found["links"].is_a?(Hash) ? found["links"] : {}
      run.update_columns(qube_run_id: found["id"], run_url: links["self"], cancel_url: links["cancel"])
      found
    end

    # nil when QuBe Sync no longer has it.
    def read_run(run, connection)
      QubeRails.client.get_run(connection.qube_id, run.qube_run_id)
    rescue Backend::APIError => e
      raise unless e.status == 404

      nil
    end

    # Its answer once cancelled; one already over (409) or gone (404) is read again.
    def cancel_run(run, connection, url)
      QubeRails.client.cancel_run(url, reason: REASON)
    rescue Backend::APIError => e
      raise unless [404, 409].include?(e.status)

      read_run(run, connection)
    end

    def request_at_qube(row, connection)
      QubeRails.client.get_request(connection.qube_id, row.qube_id)
    rescue Backend::APIError => e
      raise unless e.status == 404

      nil
    end

    # Under its lock, and only if nothing ended it meanwhile. The revision stays, so its webhooks
    # still apply (with links held).
    def end_run(run, state)
      run.with_lock do
        next if run.ended?

        state = RUN_ENDED.include?(state) ? state : "cancelled"
        # Columns only: the record may be gone, and nothing else about the run changes.
        reason = state == "cancelled" ? QubeRails.t("status.company_file_changed") : run.cancel_reason
        run.update_columns(state: state, ended_at: Time.now, updated_at: Time.now, cancel_url: nil,
                           question: nil, links: nil, cancel_reason: reason)
        QubeRails.logger.warn("QuBe Sync: run #{run.id}, from before its connection's company file changed, " \
                              "ended as #{state}")
      end
      nil
    end

    def end_row(row, state, error)
      row.with_lock do
        next if row.ended?

        row.update_columns(state: state, ended_at: Time.now, updated_at: Time.now,
                           error: error || { "error_type" => "company_file_changed" })
        QubeRails.logger.warn("QuBe Sync: request #{row.id}, from before its connection's company file changed, " \
                              "ended as #{state}")
      end
      nil
    end

    def pending!(row, why)
      what = row.is_a?(QubeRails::Run) ? "run" : "request"
      raise OldFileWorkPending, "QuBe Sync: #{what} #{row.id} is from before its " \
                                "connection's company file changed and isn't over yet: #{why}; try again shortly"
    end
  end
end
