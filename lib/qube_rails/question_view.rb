# frozen_string_literal: true

require "qube_rails/rows_view"

module QubeRails
  # The open question of a run, as the question partials render it: the override contract, kept
  # stable across versions (README, "Styling"). Built from the prompt QuBe Sync sent.
  class QuestionView
    attr_reader :prompt, :message, :details, :choices, :token, :action_url, :search_url, :error

    # The question run is asking, or nil when it isn't asking. urls answers question_path(run):
    # the engine's route proxy (qube_rails) in a view.
    def self.from_run(run, urls, error: nil)
      prompt = run && run.open_question
      return nil unless prompt

      action = urls.question_path(run)
      new(prompt, action_url: action, search_url: "#{action}/search", error: error)
    end

    def initialize(prompt, action_url:, search_url:, error: nil)
      @prompt = prompt
      @message = prompt["message"].to_s
      @token = prompt["token"].to_s
      @details = Array(prompt["details"]).select { |row| row.is_a?(Hash) }
                                         .map { |row| DetailView.new(row["label"], row["value"]) }
      @action_url = action_url
      @search_url = search_url
      @error = error
      @choices = Array(prompt["choices"]).select { |c| c.is_a?(Hash) }.each_with_index.map do |choice, n|
        ChoiceView.new(choice, n, self)
      end
      arrange
    end

    # The choices by where they show: picks (option rows), forms (a section each, "or" between),
    # then exits (a footer row). plain? when there's neither a pick nor a form: one row, the first
    # choice primary.
    def picks
      choices.select { |c| c.kind == :pick }
    end

    def forms
      choices.select { |c| c.kind == :form }
    end

    def exits
      choices.select { |c| c.kind == :exit }
    end

    def plain?
      picks.empty? && forms.empty?
    end

    private

    # Kinds and button styles. With no picks but a form, a plain choice before the first form
    # (name clash's "Use the existing record") is an option row too. One filled button at most:
    # the first form's submit, or in a plain question the first choice.
    def arrange
      if @choices.none? { |c| c.kind == :pick } && (first_form = @choices.index { |c| c.kind == :form })
        @choices.first(first_form).each { |c| c.arrange(:pick, nil) unless c.secondary? }
      end
      primary = plain? ? @choices.find { |c| !c.secondary? } : forms.first
      @choices.each do |choice|
        style = if choice.kind == :pick then nil
                elsif choice.equal?(primary) then :primary
                elsif choice.secondary? then :ghost
                else :secondary
                end
        choice.arrange(choice.kind, style)
      end
    end
  end

  # One label and value row of what the question is about.
  DetailView = Struct.new(:label, :value)

  # One of a select's options.
  OptionView = Struct.new(:value, :label)

  # One thing the user can pick: a form of its own, posting choice=<id> and data[...] for its
  # fields to the question's action_url.
  class ChoiceView
    attr_reader :id, :label, :detail, :description, :fields, :index, :action_url, :kind, :style

    def initialize(choice, index, question)
      @id = choice["id"].to_s
      @label = choice["label"].to_s
      @detail = presence(choice["detail"])
      @description = presence(choice["description"])
      @index = index
      @action_url = question.action_url
      @fields = Array(choice["fields"]).select { |f| f.is_a?(Hash) }.map do |field|
        FieldView.from_prompt(field, question, index)
      end
      @kind = if fields.any? then :form
              elsif @id.match?(/:\d+\z/) then :pick
              else :exit
              end
    end

    # kind is :pick (an option row: an item of a choose list, id "<option>:<n>", no fields), :form
    # (a choice with fields) or :exit (none, cancel and the like). style is its button's: :primary,
    # :secondary or :ghost (cancel), nil for a pick. Set by the QuestionView.
    def arrange(kind, style)
      @kind = kind
      @style = style
    end

    # The ui_classes piece for its button.
    def button_piece
      case style
      when :primary then :button
      when :ghost then QubeRails.config.ui_classes.key?(:button_ghost) ? :button_ghost : :button_secondary
      else :button_secondary
      end
    end

    # A choice that stops (cancel): the ui_classes button_secondary rather than button.
    def secondary?
      id == "cancel"
    end

    private

    def presence(value)
      text = value.to_s
      text.strip.empty? ? nil : text
    end
  end

  # One input: a choice's field, a rows field's cell, or a rows column's "Set selected" control.
  # type is "text", "number", "boolean", "select", "search" or "rows"; partial is the piece that
  # renders it (qube_rails/question/fields/_<type>).
  class FieldView
    TYPES = %w[text number boolean select search rows].freeze

    attr_reader :name, :input_name, :dom_id, :type, :label, :required, :options, :kind,
                :search_url, :search_field, :row_key, :when, :rows, :context, :disabled

    # A choice's field, as QuBe Sync sends it.
    def self.from_prompt(field, question, choice_index)
      name = field["name"].to_s
      input_name = "data[#{name}]"
      type = type_of(field, record_type: "search")
      rows = if type == "rows"
               RowsView.new(field, input_name: input_name, search_url: question.search_url)
             end
      new(name: name, input_name: input_name, dom_id: "qube-#{question.token}-#{choice_index}-#{name}",
          type: type, label: field["label"] || name, required: field["required"] == true,
          options: options_of(field), kind: field["kind"], search_url: question.search_url,
          search_field: name, rows: rows)
    end

    # What a prompt field shows as: a record a search, an enum a select, else by its type.
    def self.type_of(field, record_type:)
      return "rows" if field["type"] == "rows"
      return record_type if field["type"] == "record"
      return "select" if field["enum"].is_a?(Array) && !field["enum"].empty?
      return field["type"] if %w[boolean number].include?(field["type"])

      "text"
    end

    def self.options_of(field)
      Array(field["enum"]).select { |e| e.is_a?(Hash) }.map do |e|
        OptionView.new(e["value"], (e["label"] || e["value"]).to_s)
      end
    end

    # context is :choice (a field of its own, labelled), :cell (a rows cell: aria-label only) or
    # :bulk (a "Set selected" control, posted with nothing).
    def initialize(name:, type:, label:, input_name: nil, dom_id: nil, required: false, options: [], kind: nil,
                   search_url: nil, search_field: nil, row_key: nil, when_values: nil, rows: nil,
                   context: :choice, disabled: false)
      raise ArgumentError, "QuBe Sync: no field type #{type.inspect}" unless TYPES.include?(type)

      @name = name
      @type = type
      @label = label.to_s
      @input_name = input_name
      @dom_id = dom_id
      @required = required
      @options = options
      @kind = kind
      @search_url = search_url
      @search_field = search_field
      @row_key = row_key
      @when = when_values || {}
      @rows = rows
      @context = context
      @disabled = disabled
    end

    def partial
      "qube_rails/question/fields/#{type}"
    end

    def cell?
      context == :cell
    end

    def bulk?
      context == :bulk
    end

    # Whether it's shown with its own label (a choice's field), not inside a table.
    def labelled?
      context == :choice
    end

    # The input's data attributes the behaviour script keys on.
    def data
      if cell? then { "qube-rows-input" => "" }
      elsif bulk? then { "qube-bulk-value" => "" }
      else {}
      end
    end

    # A "Set selected" control belongs to no form, so the answer doesn't carry it.
    def form_attribute
      bulk? ? "" : nil
    end
  end
end
