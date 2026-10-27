# frozen_string_literal: true

module QubeRails
  # POST /qube/runs/<run id>/retry_start, from the run status partial's "Try sending again"
  # button: sends a start QuBe Sync never confirmed (a run still "starting") again, with the same
  # reference as its Idempotency-Key (QubeRails::Run#retry_start!), so a start that did land
  # answers with its run rather than making another. Behind your sign-in and CSRF, as your
  # ApplicationController (config.parent_controller) is, and config.authorize_question decides
  # who may, as for answering the run's questions.
  class RunsController < QubeRails.config.parent_controller.constantize
    include RunAuthorization

    # What the page says when it can't, as I18n keys under qube_rails (config/locales/en.yml).
    NOT_STARTING = :"errors.not_starting"
    NOT_QUIET = :"errors.not_quiet"
    REDELIVERY_REFUSED = { 409 => :"errors.no_update_yet", 429 => :"errors.checked_just_now" }.freeze
    NO_ANSWER = :"errors.unreachable"

    def retry_start
      run, = authorized_run("a start retry")
      return head(:not_found) unless run
      return back_with_error(NOT_STARTING) unless run.state == "starting"

      begin
        run.retry_start!
      rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
        # Refused (the run is now failed) or no answer again (still unconfirmed): the status on
        # the page says which.
        QubeRails.logger.warn("QuBe Sync: run #{run.id}'s start retry didn't go through (#{e.class})")
      end
      redirect_back fallback_location: "/", status: :see_other
    end

    # POST /qube/runs/<run id>/redeliver, from the run status partial's "Check for updates"
    # button on a run that looks stuck (QubeRails::Run#looks_stuck?): asks QuBe Sync to
    # send the run's latest event again (its question, or how it ended) to the run's webhook URL,
    # for a webhook this app missed. The event comes back through the webhook route as usual;
    # one this app already applied is skipped by its revision.
    def redeliver
      run, = authorized_run("a redelivery")
      return head(:not_found) unless run
      return back_with_error(NOT_QUIET) unless run.looks_stuck?

      QubeRails.client.redeliver_run(run.connection.qube_id, run.qube_run_id)
      redirect_back fallback_location: "/", status: :see_other
    rescue Backend::APIError => e
      raise unless REDELIVERY_REFUSED.key?(e.status)

      back_with_error(REDELIVERY_REFUSED.fetch(e.status))
    rescue *Backend::NETWORK_ERRORS
      back_with_error(NO_ANSWER)
    end
  end
end
