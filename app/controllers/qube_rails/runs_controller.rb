# frozen_string_literal: true

module QubeRails
  # POST /qube/runs/<run id>/retry_start, from the run status partial's "Try the start again"
  # button: sends a start QuBe Sync never confirmed (a run still "starting") again, with the same
  # reference as its Idempotency-Key (QubeRails::Run#retry_start!), so a start that did land
  # answers with its run rather than making another. Behind your sign-in and CSRF, as your
  # ApplicationController (config.parent_controller) is, and config.authorize_question decides
  # who may, as for answering the run's questions.
  class RunsController < QubeRails.config.parent_controller.constantize
    include RunAuthorization

    NOT_STARTING = "This run isn't waiting for its start to be confirmed."

    def retry_start
      run, = authorized_run("a start retry")
      return head(:not_found) unless run
      return render(plain: NOT_STARTING, status: :conflict) unless run.state == "starting"

      begin
        run.retry_start!
      rescue Backend::APIError, *Backend::NETWORK_ERRORS => e
        # Refused (the run is now failed) or no answer again (still unconfirmed): the status on
        # the page says which.
        QubeRails.logger.warn("QuBe Sync: run #{run.id}'s start retry didn't go through (#{e.class})")
      end
      redirect_back fallback_location: "/", status: :see_other
    end
  end
end
