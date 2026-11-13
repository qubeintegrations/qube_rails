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
    # then exits (a footer row, cancel last). plain? when there's neither a pick nor a form: one
    # row, the first choice primary.
    def picks
      choices.select { |c| c.kind == :pick }
    end

    # The forms shown as sections. A search under offered records is left out: it's behind
    # "Search QuickBooks…" at the end of the picks (searches).
    def forms
      choices.select { |c| c.kind == :form && !disclosed?(c) }
    end

    # The search choices shown behind "Search QuickBooks…" under the possible matches.
    def searches
      choices.select { |c| disclosed?(c) }
    end

    def disclosed?(choice)
      choice.kind == :form && choice.role == "search" && matches?
    end

    def exits
      choices.select { |c| c.kind == :exit }.partition { |c| !c.cancel? }.flatten
    end

    def plain?
      picks.empty? && forms.empty?
    end

    # Whether QuBe Sync said each choice's role (prompt.choices[].role): then the picks are the
    # records it offers, under "Possible matches".
    def roles?
      choices.any?(&:role)
    end

    def matches?
      picks.any? { |c| c.role == "pick" }
    end

    # One of the engine's own words for this question (question.<key> in the locale files). The one
    # place they're looked up, so a later QuBe Sync can send them with the prompt.
    def ui_text(key, **options)
      QubeRails.t("question.#{key}", **options)
    end

    private

    def arrange
      roles? ? arrange_by_role : arrange_by_shape
    end

    # By role: the offered records are picks, the first the one primary action; a search is a form,
    # secondary; decline and cancel are exits. An answer shows by its shape, as without roles.
    def arrange_by_role
      @choices.each do |c|
        kind = case c.role
               when "pick" then :pick
               when "search" then :form
               when "decline", "cancel" then :exit
               else c.fields.any? ? :form : :exit
               end
        c.arrange(kind, nil)
      end
      promote_rows
      offered = @choices.select { |c| c.role == "pick" }
      all_forms = @choices.select { |c| c.kind == :form }
      plain = picks.empty? && all_forms.empty?
      primary = offered.first || (plain ? @choices.find { |c| !c.cancel? } : all_forms.find { |c| c.role != "search" } || all_forms.first)
      @choices.each do |choice|
        style = if choice.kind == :pick then (offered.include?(choice) ? button_style(choice, primary) : nil)
                elsif choice.equal?(primary) then :primary
                elsif choice.cancel? then :ghost
                else :secondary
                end
        choice.arrange(choice.kind, style)
      end
    end

    def button_style(choice, primary)
      choice.equal?(primary) ? :primary : :secondary
    end

    # Kinds and button styles from each choice's shape (a prompt without roles). One filled button
    # at most: the first form's submit, or in a plain question the first choice.
    def arrange_by_shape
      promote_rows
      primary = plain? ? @choices.find { |c| !c.cancel? } : forms.first
      @choices.each do |choice|
        style = if choice.kind == :pick then nil
                elsif choice.equal?(primary) then :primary
                elsif choice.cancel? then :ghost
                else :secondary
                end
        choice.arrange(choice.kind, style)
      end
    end

    # With no picks but a form, a plain choice before the first form (name clash's "Use the
    # existing record") is an option row too.
    def promote_rows
      return if @choices.any? { |c| c.kind == :pick }
      return unless (first_form = @choices.index { |c| c.kind == :form })

      @choices.first(first_form).each do |c|
        c.arrange(:pick, nil) unless c.cancel? || %w[decline cancel].include?(c.role)
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
    ROLES = %w[pick search decline cancel answer].freeze

    attr_reader :id, :label, :detail, :description, :fields, :index, :action_url, :kind, :style, :role

    def initialize(choice, index, question)
      @id = choice["id"].to_s
      # QuBe Sync's role for it, nil when the prompt has none; one this version doesn't know is answer.
      @role = (ROLES.include?(choice["role"]) ? choice["role"] : "answer") if choice.key?("role")
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
    # :secondary or :ghost (cancel); for a pick nil, or with roles its "Use this one" button's.
    # Set by the QuestionView.
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

    # A choice that ends the request: its role cancel, or without roles its id.
    def cancel?
      role ? role == "cancel" : id == "cancel"
    end

    alias secondary? cancel?

    private

    def presence(value)
      text = value.to_s
      text.strip.empty? ? nil : text
    end
  end

  # One input: a choice's field, or a field of a rows field's row.
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
               RowsView.new(field, input_name: input_name, search_url: question.search_url, question: question)
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

    # context is :choice (a choice's field) or :cell (a field of a rows field's row); both show
    # their label.
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

    # Whether it's shown with its own label: always, now that a row's fields stack.
    def labelled?
      true
    end

    # The input's data attributes the behaviour script keys on.
    def data
      cell? ? { "qube-rows-input" => "" } : {}
    end

    # A select with at most three options in a row shows as a segmented control.
    def segmented?
      cell? && type == "select" && options.size.between?(1, 3)
    end
  end
end
