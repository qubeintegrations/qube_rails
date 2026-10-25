# frozen_string_literal: true

require "json"

module QubeRails
  # Your user's answers to the questions a run asks, from the question partial
  # (qube_rails/_question) on the record's page:
  #   POST /qube/questions/<operation>/<record id>         a choice, with its fields
  #   GET  /qube/questions/<operation>/<record id>/search  a record field's matches, as JSON
  # Each finds the record through config.operations, as the webhooks do, and asks
  # config.authorize_question before anything else. The calls to QuBe Sync are made here, with
  # the API key, so the browser only ever talks to your app.
  #
  # Behind your sign-in, as your ApplicationController (config.parent_controller) is. The answers
  # come from forms, so they carry your CSRF token, as the partial writes it.
  class QuestionsController < QubeRails.config.parent_controller.constantize
    CHANGED = "This question has changed; reload."
    REFUSED = "You can't answer this question."

    before_action :find_question

    # Posts your user's choice, with what they filled in for its fields, to the question's
    # links.decisions, and sends them back to the page. The question is forgotten once it's
    # answered, or once QuBe Sync says it was answered or asked again since (a 409, or a 400 such
    # as not_awaiting_input); the run's next webhook says what came of it.
    def create
      choices = Array(@question && @question["choices"])
      choice = choices.find { |c| c["id"] == params[:choice] }
      return render(plain: CHANGED, status: :conflict) unless choice && @links["decisions"]

      QubeRails.client.answer(@links["decisions"], choice: choice["id"], data: answer_data(choice))
      @operation.answered(@question["token"])
      redirect_back fallback_location: "/", status: :see_other
    rescue Backend::APIError => e
      raise unless [400, 409, 422].include?(e.status)
      # A field QuBe Sync couldn't take: its errors.detail says which.
      return render(plain: refusal(e), status: 422) if e.status == 422

      @operation.answered(@question["token"])
      render plain: CHANGED, status: :conflict
    end

    # The matches for a record field, for what your user typed: [{value, label, detail}], at most
    # 20, from the question's links.search, which a run sets while it asks with one. q of 2 to 100
    # characters and a field name of at most 100 are asked about; anything else has no matches.
    def search
      q = params[:q].to_s.strip
      field = params[:field].to_s
      return render(json: [], status: :conflict) unless @links["search"]
      return render(json: []) unless q.length.between?(2, 100) && field.length.between?(1, 100)

      render json: QubeRails.client.search(@links["search"], field: field, q: q)
    rescue Backend::APIError => e
      raise unless e.status.between?(400, 499)

      render json: [], status: e.status # the question has changed (409), say
    end

    private

    def find_question
      slug = params[:operation].to_s
      operation = QubeRails.config.operation_class(slug)
      # A slug none of your operations has: the connection's own events ask nothing.
      return head(:not_found) unless operation && operation <= QubeRails::Operation

      authorize = QubeRails.config.authorize_question
      unless authorize
        # The record's id comes from the URL, so authorize_question is all that keeps one
        # customer's users off another's records: until it's written, nothing is let through.
        QubeRails.logger.error("QuBe Sync: refused an answer or search for #{slug} " \
                               "#{params[:record_id]}: config.authorize_question isn't set in " \
                               "#{Configuration::FILE}, so every one is refused until it is")
        return refuse(:forbidden)
      end

      # nil, or ActiveRecord::RecordNotFound, answers 404.
      record = operation.find_record(params[:record_id])
      return head(:not_found) unless record

      # Only true lets it through: a truthy record, or a forgotten return, doesn't. Refused, it
      # answers 404, as for a record that doesn't exist, so a user can't tell another customer's
      # record is there.
      unless authorize.call(self, record, slug) == true
        QubeRails.logger.warn("QuBe Sync: refused an answer or search for #{slug} " \
                              "#{params[:record_id]}: config.authorize_question said no")
        return refuse(:not_found)
      end

      @operation = operation.new(record)
      @question = @operation.saved_question
      @links = @operation.saved_links || {}
    end

    def refuse(status)
      if action_name == "search"
        render json: [], status: status
      elsif status == :not_found
        head :not_found
      else
        render plain: REFUSED, status: status
      end
    end

    # The choice's own fields from the form, each as its type: a checkbox true or false, a number
    # as a number (or as typed, for QuBe Sync's 422 to name), and a blank one left out.
    def answer_data(choice)
      form = params.fetch(:data, {})
      choice["fields"].to_a.each_with_object({}) do |field, data|
        name = field["name"]
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
