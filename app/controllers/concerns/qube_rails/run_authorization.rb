# frozen_string_literal: true

module QubeRails
  # Finding the run a request names (params[:id]) and asking config.authorize_question whether the
  # signed-in user may act on it, for the question routes and the start retry. The run's id comes
  # from the URL, so this is what keeps one customer's users off another's runs.
  module RunAuthorization
    private

    # [run, operation class, record] when the run, its operation and its record are there and
    # authorize_question says true; else nil, and a refusal is logged. Only true lets it through:
    # a truthy record, or a forgotten return, doesn't. A refusal answers as a run that doesn't
    # exist does (404), so a user can't tell another customer's run is there.
    def authorized_run(action)
      run = QubeRails::Run.find_by(id: params[:id])
      operation = run && QubeRails.config.operation_class(run.operation)
      record = operation && operation.record_for(run)
      return nil unless record

      unless QubeRails.config.authorize_question.call(self, record, run) == true
        QubeRails.logger.warn("QuBe Sync: refused #{action} for run #{run.id}: config.authorize_question said no")
        return nil
      end

      [run, operation, record]
    end

    # Back to the page, with message (a Symbol is an I18n key under qube_rails, a String the
    # sentence itself) in the flash for the engine's partials to show (qube_rails/_question and
    # _run_status). The forms post through Turbo in most apps, which
    # shows nothing for a plain-text 409 or 422, so a failed answer or retry says why this way.
    def back_with_error(message)
      flash[:qube_rails_error] = message.is_a?(Symbol) ? QubeRails.t(message) : message
      redirect_back fallback_location: "/", status: :see_other
    end
  end
end
