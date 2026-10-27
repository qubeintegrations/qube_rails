# frozen_string_literal: true

require "json"

module QubeRails
  # Every screen the engine's partials show, from sample data, for GET qube/storyboard: the run
  # status in each state, the one-shot error, and a question of each kind (lib/qube_rails/
  # storyboard/*.json, prompts shaped as QuBe Sync sends them). Nothing is read from or written
  # to QuBe Sync or the database: runs are built, never saved.
  module Storyboard
    DIR = File.expand_path("storyboard", __dir__)

    Screen = Struct.new(:key, :group, :title, :note, :partials, :kind, :sample)

    QUESTIONS = %w[near_match record_search choose enum_select number_boolean name_clash ask_about_add missing_record rows
                   refusal].freeze

    # key, title, SyncStatus status, the run's attributes (ages in seconds), extra pieces, note.
    RUN_STATUSES = [
      ["not_sent", "Not sent", :not_sent, nil, [],
       "A record with no run: the run status partial renders nothing."],
      ["starting", "Starting", :sending, { state: "starting", age: 5 }, [],
       "A start QuBe Sync is confirming."],
      ["unconfirmed", "A start not confirmed", :sending, { state: "starting", age: 120 }, ["run_status/retry"],
       "QuBe Sync hasn't confirmed the start for a minute: the retry button sends it again, same reference."],
      ["running", "Running", :sending, { state: "running", qube_run_id: "run-sample", age: 30 }, [],
       "QuBe Sync confirmed it; the Web Connector is working through it."],
      ["stalled_not_checking_in", "Waiting: QuickBooks isn't checking in", :sending,
       { state: "running", qube_run_id: "run-sample", age: 30 * 60, stall: "not_checking_in" }, ["run_status/stall"],
       "A run going on a connection QuBe Sync says stalled (not_checking_in): the Web Connector hasn't called in. " \
       "No redeliver button: the cause is known."],
      ["stalled_quickbooks_unavailable", "Waiting: QuickBooks is closed", :sending,
       { state: "running", qube_run_id: "run-sample", age: 30 * 60, stall: "quickbooks_unavailable" },
       ["run_status/stall"],
       "The same, stalled as quickbooks_unavailable: the Web Connector calls in but can't open the company file."],
      ["needs_answer", "Waiting for an answer", :needs_answer,
       { state: "awaiting_input", qube_run_id: "run-sample", age: 30, question: { "message" => "?" } }, [],
       "The run asks a question: the question partial shows it (below)."],
      ["looks_stuck", "Looks stuck", :sending, { state: "running", qube_run_id: "run-sample", age: 15 * 60 },
       ["run_status/redeliver"],
       "No news for 10 minutes: the redeliver button asks QuBe Sync to send its latest event again."],
      ["in_quickbooks", "In QuickBooks", :in_quickbooks, { state: "completed", outcome: "added", ended: true }, [],
       "The record is linked to its QuickBooks id."],
      ["done", "Done", :done, { state: "completed", outcome: "completed", ended: true }, [],
       "Completed, linking nothing (an operation that doesn't link its record)."],
      ["failed", "Failed", :failed,
       { state: "failed", ended: true,
         error: { "message" => "QuickBooks refused the invoice because Riverbend Electric is inactive",
                  "detail" => "Make Riverbend Electric active in QuickBooks, then send it again." } },
       ["run_status/detail"], "A failure: the pill says it couldn't sync; below it, why (the error's message) and what to do (its detail)."],
      ["cancelled", "Cancelled", :cancelled,
       { state: "cancelled", ended: true, cancel_reason: "The order was cancelled in the app." }, [],
       "Cancelled by your app, with its reason."]
    ].freeze

    # Stands in for the engine's routes: every form posts to the storyboard's no-op answer.
    class Urls
      def initialize(answer_path)
        @answer_path = answer_path
      end

      def question_path(_run)
        @answer_path
      end

      def retry_start_path(_run)
        @answer_path
      end

      def redeliver_path(_run)
        @answer_path
      end
    end

    class << self
      def screens
        run_status_screens + [error_screen] + QUESTIONS.map { |key| question_screen(key) }
      end

      def find(key)
        screens.find { |screen| screen.key == key.to_s }
      end

      def run_status_view(screen, urls)
        RunStatusView.from_sync(sync_status(screen.sample), urls)
      end

      def question_view(screen, answer_path, search_path)
        QuestionView.new(screen.sample["prompt"], action_url: answer_path, search_url: search_path,
                                                  error: screen.sample["error"])
      end

      # The sample's matches for a search: at most 20 whose label holds q.
      def matches(screen, field, q)
        list = screen && screen.kind == :question ? Array(screen.sample["search"][field.to_s]) : []
        q = q.to_s.strip.downcase
        list.select { |m| m["label"].to_s.downcase.include?(q) }.first(20)
      end

      # The file an app puts at that path to override a piece.
      def override_path(partial)
        dir, _, name = partial.rpartition("/")
        "app/views/qube_rails/#{dir.empty? ? "" : "#{dir}/"}_#{name}.html.erb"
      end

      private

      def run_status_screens
        RUN_STATUSES.map do |key, title, status, run, pieces, note|
          partials = %w[run_status/status run_status/summary] + pieces
          partials = [] if status == :not_sent
          Screen.new(key, "Run status", title, note, partials, :run_status, { status: status, run: run })
        end
      end

      def error_screen
        Screen.new("error", "Run status", "A one-shot error",
                   "A route's message (flash[:qube_rails_error]), shown once by whichever partial comes first, " \
                   "or by render \"qube_rails/error\" on a page without them.", ["error"], :error,
                   { message: QubeRails.t("errors.question_changed") })
      end

      def question_screen(key)
        sample = JSON.parse(File.read(File.join(DIR, "#{key}.json")))
        Screen.new(key, "Questions", sample["title"], sample["note"], question_partials(sample), :question, sample)
      end

      def question_partials(sample)
        prompt = sample["prompt"]
        list = %w[question/question question/message]
        list << "question/details" if Array(prompt["details"]).any?
        view = QuestionView.new(prompt, action_url: "", search_url: "")
        list.concat(%w[question/picks question/pick]) if view.picks.any?
        list << "question/choice" if view.forms.any? || view.exits.any?
        list << "question/footer" if view.exits.any?
        list << "error" if sample["error"]
        fields = Array(prompt["choices"]).flat_map { |choice| Array(choice["fields"]) }
        fields.each do |field|
          type = FieldView.type_of(field, record_type: "search")
          list << "question/field" unless type == "rows"
          list << "question/fields/#{type}"
          next unless type == "rows"

          list.concat(%w[question/rows/row question/rows/cell question/rows/segmented question/field])
          Array(field["columns"]).each { |c| list << "question/fields/#{FieldView.type_of(c, record_type: "search")}" }
        end
        list.uniq
      end

      def sync_status(sample)
        attrs = sample[:run]
        return SyncStatus.new(:not_sent, nil, nil) unless attrs

        now = Time.now
        created = now - attrs[:age].to_i
        run = Run.new(state: attrs[:state], outcome: attrs[:outcome], error: attrs[:error],
                      cancel_reason: attrs[:cancel_reason], qube_run_id: attrs[:qube_run_id],
                      question: attrs[:question], operation: "storyboard", reference: "storyboard",
                      created_at: created, updated_at: created, ended_at: attrs[:ended] ? now : nil)
        run.connection = Connection.new(status: attrs[:stall] ? "stalled" : "connected", stall_reason: attrs[:stall])
        SyncStatus.new(sample[:status], run, nil)
      end
    end
  end
end
