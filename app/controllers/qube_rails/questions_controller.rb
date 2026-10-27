# frozen_string_literal: true

require "json"

module QubeRails
  # Your user's answers to the questions a run asks, from the question partial
  # (qube_rails/_question) on the record's page:
  #   POST /qube/questions/runs/<run id>         a choice, with its fields
  #   GET  /qube/questions/runs/<run id>/search  a record field's matches, as JSON
  # Each finds the run, its operation (config.operations) and its record, as the webhooks do, and
  # asks config.authorize_question(controller, record, run) before anything is sent: by default,
  # whether the signed-in account owns the run's connection. The calls to QuBe Sync are made here, with
  # the API key, so the browser only ever talks to your app.
  #
  # Behind your sign-in, as your ApplicationController (config.parent_controller) is. The answers
  # come from forms, so they carry your CSRF token, as the partial writes it.
  class QuestionsController < QubeRails.config.parent_controller.constantize
    CHANGED = "This question changed since the page showed it, so that answer was not sent: " \
              "the page now shows where it stands."

    include RunAuthorization

    before_action :find_question

    # Posts your user's choice, with what they filled in for its fields, to the question's
    # links.decisions, and sends them back to the page; when it can't, back with why (the
    # partial shows it). The question is forgotten once it's
    # answered, or once QuBe Sync says it was answered or asked again since (a 409, or a 400 such
    # as not_awaiting_input); the run's next webhook says what came of it.
    def create
      choices = Array(@question && @question["choices"])
      choice = choices.find { |c| c["id"] == params[:choice] }
      return back_with_error(CHANGED) unless choice && @links["decisions"]

      QubeRails.client.answer(@links["decisions"], choice: choice["id"], data: answer_data(choice))
      @operation.answered(@question["token"], taken: true)
      redirect_back fallback_location: "/", status: :see_other
    rescue Backend::APIError => e
      raise unless [400, 409, 422].include?(e.status)
      # A field QuBe Sync couldn't take: its errors.detail says which.
      return back_with_error(refusal(e)) if e.status == 422

      @operation.answered(@question["token"])
      back_with_error(CHANGED)
    end

    # The matches for a record field, for what your user typed: [{value, label, detail}], at most
    # 20, from the question's links.search, which a run sets while it asks with one. q of 2 to 100
    # characters and a field name of at most 100 are asked about; anything else has no matches.
    def search
      q = params[:q].to_s.strip
      field = params[:field].to_s
      return render(json: [], status: :conflict) unless @links["search"]
      return render(json: []) unless searchable?(q, field)

      row = params[:row].to_s
      row = nil if row.empty? || row.length > 200
      render json: QubeRails.client.search(@links["search"], field: field, q: q, row: row)
    rescue Backend::APIError => e
      raise unless e.status.between?(400, 499)

      render json: [], status: e.status # the question has changed (409), say
    end

    private

    # What a search is asked about: q of 2 to 100 characters, a field name of 1 to 100.
    # A rows field's answer: each row's filled columns, by row key. QuBe Sync drops a column the
    # row's other answers say doesn't apply, and names any required one left out.
    def rows_data(field, form)
      form = form.respond_to?(:to_unsafe_h) ? form.to_unsafe_h : {}
      field["rows"].to_a.each_with_object({}) do |row, rows|
        given = form[row["key"]].is_a?(Hash) ? form[row["key"]] : {}
        columns = field["columns"].to_a.select { |column| row["columns"].to_a.include?(column["name"]) }
        rows[row["key"]] = columns.each_with_object({}) do |column, values|
          text = given[column["name"]].to_s.strip
          values[column["name"]] = column["type"] == "number" ? number(text) : text unless text.empty?
        end
      end
    end

    def searchable?(q, field)
      q.length.between?(2, 100) && field.length.between?(1, 100)
    end

    def find_question
      run, operation, record = authorized_run("an answer or search")
      return refuse unless run

      @operation = operation.new(record, run)
      @question = run.open_question
      @links = run.links || {}
    end

    def refuse
      if action_name == "search"
        render json: [], status: :not_found
      else
        head :not_found
      end
    end

    # The choice's own fields from the form, each as its type: a checkbox true or false, a number
    # as a number (or as typed, for QuBe Sync's 422 to name), and a blank one left out.
    def answer_data(choice)
      form = params.fetch(:data, {})
      choice["fields"].to_a.each_with_object({}) do |field, data|
        name = field["name"]
        next data[name] = rows_data(field, form[name]) if field["type"] == "rows"

        text = form[name].to_s.strip
        if field["type"] == "boolean"
          data[name] = text == "true"
        elsif !text.empty?
          data[name] = field["type"] == "number" ? number(text) : text
        end
      end
    end

    def number(text)
      text.match?(/\A-?\d+\z/) ? text.to_i : Float(text, exception: false) || text
    end

    # What QuBe Sync said was wrong with an answer, in words (its errors.detail).
    def refusal(error)
      detail = JSON.parse(error.body.to_s).dig("errors", "detail")
      detail ? "QuBe Sync couldn't take that answer: #{detail}" : "QuBe Sync couldn't take that answer."
    rescue JSON::ParserError, TypeError, NoMethodError
      "QuBe Sync couldn't take that answer."
    end
  end
end
