# frozen_string_literal: true

require "qube_rails/rows_view"

module QubeRails
  # The open question of a run, as the question partials render it: the override contract, kept
  # stable across versions (README, "Styling"). Built from the prompt QuBe Sync sent.
  class QuestionView
    attr_reader :prompt, :message, :details, :choices, :token, :action_url, :search_url, :error,
                :refused_choice, :refused_values

    # The question run is asking, or nil when it isn't asking. urls answers question_path(run):
    # the engine's route proxy (qube_rails) in a view. refusal is flash[:qube_rails_refusal] (a
    # 422 for one of its choices: token, choice, message, values), used when it's this question's.
    def self.from_run(run, urls, error: nil, refusal: nil)
      prompt = run && run.open_question
      return nil unless prompt

      action = urls.question_path(run)
      new(prompt, action_url: action, search_url: "#{action}/search", error: error, refusal: refusal)
    end

    def initialize(prompt, action_url:, search_url:, error: nil, refusal: nil)
      @prompt = prompt
      @message = prompt["message"].to_s
      @token = prompt["token"].to_s
      if refusal.is_a?(Hash) && refusal["token"].to_s == @token
        error ||= refusal["message"]
        @refused_choice = refusal["choice"].to_s
        @refused_values = refusal["values"].is_a?(Hash) ? refusal["values"] : {}
      end
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

    # The choices by where they show: picks (option rows), the search boxes under offered records
    # (searches), declines beside them (alongside), forms (a section each, "or" between), forms
    # behind "or <its label>…" (disclosed), then exits (a footer row, cancel last). plain? when
    # there's neither a pick nor a form: one row, the first choice primary.
    # The picks are the offered records, a slot per search box for its picked match (hidden until
    # the script fills it), then the rest.
    def picks
      offered = choices.select { |c| c.kind == :pick && c.role == "pick" }
      offered + searches.map { |c| PickedView.new(c) } + choices.select { |c| c.kind == :pick && c.role != "pick" }
    end

    def forms
      choices.select { |c| c.kind == :form && !searches.include?(c) && !disclosed.include?(c) }
    end

    # With records offered, a search is a box under them; its picked match becomes a row.
    def searches
      @searches || []
    end

    # A decline beside offered records with no row of its own ("None of them: add it again"): a
    # button just under them, weighing the same.
    def alongside
      @alongside || []
    end

    # The forms after a promoted row (a name clash's rename), each behind "or <its label>…".
    def disclosed
      @disclosed || []
    end

    def exits
      choices.select { |c| c.kind == :exit && !alongside.include?(c) }.partition { |c| !c.cancel? }.flatten
    end

    def plain?
      picks.empty? && forms.empty?
    end

    # The one form whose button row also holds the exits (cancel left, the rest beside its
    # submit): a question with no picks, one form, and exits without descriptions. Else nil, and
    # the exits have a footer row of their own.
    def joined_form
      return nil unless picks.empty? && forms.size == 1 && exits.none?(&:description)

      forms.first
    end

    # How many records QuBe Sync offers.
    def offered_count
      choices.count { |c| c.kind == :pick && c.role == "pick" }
    end

    # Whether an "or" goes before form n: another form before it, or the picks.
    def divided?(_choice, n)
      n.positive? || picks.any?
    end

    # A label as it reads after "or": its first letter lowercased.
    def mid_sentence(label)
      text = label.to_s
      text.empty? ? "" : text[0].downcase + text[1..-1]
    end

    # Whether QuBe Sync said each choice's role (prompt.choices[].role): then the picks are the
    # records it offers (option rows, no heading).
    def roles?
      choices.any?(&:role)
    end

    def matches?
      offered_count.positive?
    end

    # One of the engine's own words for this question (question.<key> in the locale files). The one
    # place they're looked up, so a later QuBe Sync can send them with the prompt.
    def ui_text(key, **options)
      QubeRails.t("question.#{key}", **options)
    end

    # The id of the refusal's message, which the refused choice's fields point at (aria-describedby).
    def error_id
      "qube-error-#{token}"
    end

    private

    # Kinds and button styles. With roles: the offered records are picks, the first the one
    # primary action; a search is a form; decline and cancel are exits; an answer shows by its
    # shape. Without roles, every choice by its shape. Offered records beside a decline weigh the
    # same as it; a promoted row (a name clash's "Use the existing record") leads, the forms after
    # it behind "or <its label>…".
    def arrange
      roles = roles?
      @choices.each { |c| c.arrange(roles ? kind_by_role(c) : c.kind, nil) }
      promoted = promote_rows
      offered = @choices.select { |c| c.kind == :pick && c.role == "pick" }
      all_forms = @choices.select { |c| c.kind == :form }
      plain = @choices.none? { |c| c.kind == :pick } && all_forms.empty?
      promoted_first = promoted.first
      primary = offered.first || promoted_first ||
                (plain ? @choices.find { |c| !c.cancel? } : all_forms.find { |c| c.role != "search" } || all_forms.first)
      level = offered.any? && @choices.any? { |c| c.role == "decline" }
      @choices.each do |choice|
        kind = choice.kind
        style = if kind == :pick then (offered.include?(choice) || promoted.include?(choice) ? button_style(choice, primary) : nil)
                elsif choice.equal?(primary) || (kind == :form && promoted_first) then :primary
                elsif choice.cancel? then :ghost
                else :secondary
                end
        if level && choice.role == "decline"
          kind = :pick if choice.row?
          style = :secondary
        elsif level && offered.include?(choice)
          style = :secondary
        end
        choice.arrange(kind, style)
      end
      @alongside = level ? @choices.select { |c| c.role == "decline" && c.kind == :exit } : []
      @searches = offered.any? ? @choices.select { |c| c.kind == :form && c.role == "search" } : []
      @searches.each { |c| c.fields.each(&:inline!) }
      @disclosed = promoted_first ? @choices.select { |c| c.kind == :form && c.role != "search" } : []
    end

    def kind_by_role(choice)
      case choice.role
      when "pick" then :pick
      when "search" then :form
      when "decline", "cancel" then :exit
      else choice.fields.any? ? :form : :exit
      end
    end

    def button_style(choice, primary)
      choice.equal?(primary) ? :primary : :secondary
    end

    # With no picks but a form, a plain choice before the first form (a name clash's "Use the
    # existing record") is an option row too. Returns those.
    def promote_rows
      return [] if @choices.any? { |c| c.kind == :pick }
      return [] unless (first_form = @choices.index { |c| c.kind == :form })

      @choices.first(first_form).reject { |c| c.cancel? || %w[decline cancel].include?(c.role) }.each do |c|
        c.arrange(:pick, nil)
      end
    end
  end

  # One label and value row of what the question is about.
  DetailView = Struct.new(:label, :value)

  # One of a select's options.
  OptionView = Struct.new(:value, :label)

  # One fact of a record a choice is about ("Balance", "1,250.00"): label and value side by side.
  FactView = Struct.new(:label, :value)

  # One thing the user can pick: a form of its own, posting choice=<id> and data[...] for its
  # fields to the question's action_url.
  class ChoiceView
    ROLES = %w[pick search decline cancel answer].freeze

    attr_reader :id, :label, :title, :action, :detail, :lines, :facts, :description, :fields, :index, :action_url,
                :kind, :style, :role

    # A text's parts (QuBe Sync joins them with " · "), each but the last ending in its " ·", so a
    # line breaks between parts and never starts with the separator. The detail's by default.
    def detail_parts(text = detail)
      parts = text.to_s.split(" · ")
      parts.each_with_index.map { |part, i| i < parts.size - 1 ? "#{part} ·" : part }
    end

    def initialize(choice, index, question)
      @id = choice["id"].to_s
      # QuBe Sync's role for it, nil when the prompt has none; one this version doesn't know is answer.
      @role = (ROLES.include?(choice["role"]) ? choice["role"] : "answer") if choice.key?("role")
      @label = choice["label"].to_s
      # A choice about one record can say what it is as a row: title in place of its label, action
      # as its button, lines and facts in place of detail.
      @title = presence(choice["title"])
      @action = presence(choice["action"])
      @detail = presence(choice["detail"])
      @lines = Array(choice["lines"]).map { |line| presence(line) }.compact
      @facts = Array(choice["facts"]).select { |f| f.is_a?(Hash) }.map do |f|
        FactView.new(presence(f["label"]), presence(f["value"]))
      end.select { |f| f.label && f.value }
      @description = presence(choice["description"])
      @index = index
      @action_url = question.action_url
      @token = question.token
      @refused = question.refused_choice == @id
      @fields = Array(choice["fields"]).select { |f| f.is_a?(Hash) }.map do |field|
        FieldView.from_prompt(field, question, index, refused: @refused)
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
      when :ghost then :button_ghost # no host class unless ui_classes has one: the engine's ghost look
      else :button_secondary
      end
    end

    # A choice that ends the request: its role cancel, or without roles its id.
    def cancel?
      role ? role == "cancel" : id == "cancel"
    end

    alias secondary? cancel?

    # Its form's id: an exit's button in another form's row names it (the form attribute).
    def form_id
      "qube-#{@token}-choice-#{index}"
    end

    # The id of an offered record's name, which its button is described by.
    def label_id
      "qube-#{@token}-pick-#{index}#{"-picked" if slot?}"
    end

    # Whether one of its fields is a rows field (which needs the behaviour script).
    def rows?
      fields.any? { |f| f.type == "rows" }
    end

    # A search's submit ("Use this one"): hidden until a match is picked, which the script shows.
    def waits_for_pick?
      role == "search" && fields.any? { |f| f.type == "search" }
    end

    # Whether QuBe Sync just refused this choice's answer (a 422): its fields are marked invalid.
    def refused?
      @refused
    end

    # Whether it says what it is as a row of its own (title, action, lines or facts).
    def row?
      !title.nil? || !action.nil? || lines.any? || facts.any?
    end

    # The hidden data[...] inputs its pick's form posts (a picked match's value).
    def data
      {}
    end

    # Whether it's a slot the script fills (a search box's picked match), hidden until then.
    def slot?
      false
    end

    protected

    # The question's token, for a picked row made from this search.
    attr_reader :token

    private

    def presence(value)
      text = value.to_s
      text.strip.empty? ? nil : text
    end
  end

  # The row a search box under offered records shows its picked match in: an option row whose
  # "Use this one" answers the search's choice with the match. Rendered empty and hidden; the
  # script fills it (a second pick replaces the first).
  class PickedView < ChoiceView
    def initialize(search)
      @search = search
      @id = search.id
      @role = search.role
      @label = ""
      @lines = []
      @facts = []
      @fields = []
      @index = search.index
      @token = search.token
      @action_url = search.action_url
      @kind = :pick
      @style = :secondary
    end

    def data
      @search.fields.select { |f| f.type == "search" }.map { |f| [f.input_name, ""] }.to_h
    end

    def slot?
      true
    end
  end

  # One input: a choice's field, or a field of a rows field's row.
  # type is "text", "number", "boolean", "select", "search" or "rows"; partial is the piece that
  # renders it (qube_rails/question/fields/_<type>).
  class FieldView
    TYPES = %w[text number boolean select search rows].freeze

    attr_reader :name, :input_name, :dom_id, :type, :label, :required, :options, :kind,
                :search_url, :search_field, :row_key, :when, :rows, :context, :disabled, :value,
                :error_id

    # A choice's field, as QuBe Sync sends it; refused: its choice's answer was just refused, so
    # it's marked invalid and holds what was typed.
    def self.from_prompt(field, question, choice_index, refused: false)
      name = field["name"].to_s
      input_name = "data[#{name}]"
      type = type_of(field, record_type: "search")
      rows = if type == "rows"
               RowsView.new(field, input_name: input_name, search_url: question.search_url, question: question)
             end
      new(name: name, input_name: input_name, dom_id: "qube-#{question.token}-#{choice_index}-#{name}",
          type: type, label: field["label"] || name, required: field["required"] == true,
          options: options_of(field), kind: field["kind"], search_url: question.search_url,
          search_field: name, rows: rows,
          value: (refused && type != "rows" ? question.refused_values.to_h[name] : nil),
          error_id: (refused ? question.error_id : nil))
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
                   context: :choice, disabled: false, value: nil, error_id: nil, optional: nil)
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
      @value = value
      @error_id = error_id
      @optional = optional.nil? ? !required : optional
    end

    # A search box under offered records: never required (its pick is a row of its own), and it
    # says "Search QuickBooks…".
    def inline!
      @inline = true
    end

    def inline?
      @inline == true
    end

    def required
      @required && !inline?
    end

    def placeholder
      inline? ? QubeRails.t("question.search_quickbooks") : nil
    end

    # Whether it may be left empty: its label says "(optional)". A rows cell's column decides it,
    # though a hidden cell isn't required in the markup yet.
    def optional?
      @optional && !%w[boolean rows].include?(type)
    end

    # Whether it's in a refused answer: aria-invalid, described by the refusal.
    def invalid?
      !error_id.nil?
    end

    # The aria attributes that say so.
    def aria_invalid
      invalid? ? { "aria-invalid": "true", "aria-describedby": error_id } : {}
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
