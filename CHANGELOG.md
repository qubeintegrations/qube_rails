# Changelog

## 0.2.0 (unreleased)

A rewrite on QuBe Sync's v2 API, holding the code QuBe Sync's integration kit used to generate
into every Rails app, so the app keeps only its own.

### Added
- A rows field is a block per record, not a table: the record's choice as a segmented control (an
  enum of up to three options), then only the fields its answers call for, stacked; never scrolling
  sideways. "Set all to:" and "Use for all N" replace the checkboxes and "Set selected": the
  `table` and `bulk` `ui_classes` keys, `RowsView#bulk`, `FieldView#bulk?` / `#form_attribute` and
  `qube_rails/question/rows/_bulk` are gone; new pieces `rows/_row` and `rows/_segmented`, keys `rows`,
  `row`, `row_header`, `segmented`, `segment`, `row_fields`, `use_for_all`. A hidden field is neither
  required nor enabled, so the browser points at the first missing shown one. Posted names are
  unchanged.
- A question's choices show by kind (`ChoiceView#kind`, `#style`; `QuestionView#picks`, `#forms`,
  `#exits`, `#plain?`): picks as option rows, each form choice its own section ("or" between) with
  the one filled button, exits in a footer row with cancel as a ghost; never more than one filled
  button. New pieces `qube_rails/question/_picks`, `_pick`, `_footer`; `ui_classes` keys `picks`,
  `pick`, `pick_detail`, `button_ghost`, `choice_footer`, `choice_divider`. A form choice whose
  required fields are all searches keeps its submit disabled until they're picked (script only).
  The storyboard's screens sit on a flat canvas, so the screen's own card is the only card.
- The screens never name QuBe Sync (or runs, webhooks, revisions or ListIDs) to an app's users, and
  every word they say comes from I18n under `qube_rails.*` (`config/locales/en.yml`, README,
  "Wording and translations"), so an app can reword or translate them; `QubeRails.t`. New wording:
  "Sending to QuickBooks", "Syncing with QuickBooks", "Still waiting for QuickBooks" (was "Not
  confirmed by QuBe Sync yet"), "Needs your answer", "Couldn't sync: ..." (was "Failed: ..."), "Check
  for updates" (was "Send its latest news again"), "Try sending again" (was "Try the start again"),
  and the routes' messages. The route constants are now I18n keys (Symbols); `RunStatusView::QUIET_TEXT`
  is gone (`QubeRails.t("status.quiet")`).
- A design pass on the stylesheet, the partials and the storyboard: system font, a 4/8/12/16/24
  spacing scale, hairline borders, one accent, light and dark through `color-scheme`; the first choice
  is the primary action and cancel the quietest; the status as a pill with a coloured dot; calm
  inline errors; buttons that give on press; the search box as a full combobox (arrows, Enter,
  Escape, closes on blur, `aria-expanded` / `aria-activedescendant` / `listbox` / `option`, a quiet
  "Searching…" only for a slow answer, its words from `data-qube-text-*`); 40px touch targets; short transform/opacity motion that respects reduced motion.
  The storyboard is a gallery: a sticky list of screens by group, each screen a card on a canvas
  (as your page, light or dark) with its override files behind a disclosure, each copyable. Every
  `data-qube-*` attribute, posted name, route and view-model field is unchanged.
- Styling (README, "Styling"). The question and run status partials are made of small pieces
  (`qube_rails/question/*`, `qube_rails/question/fields/*`, `qube_rails/question/rows/*`,
  `qube_rails/run_status/*`, `qube_rails/_error`), each overridable at its path, rendered from
  view-models whose fields are the contract (`QubeRails::QuestionView`, `ChoiceView`, `FieldView`,
  `RowsView`, `RowView`, `CellView`, `RunStatusView`). The entry points `render "qube_rails/question"`
  and `render "qube_rails/run_status"` and the posted names are unchanged.
- `config.ui_classes`: your CSS framework's classes by piece, beside the `qube-` classes; an unknown
  piece raises.
- The behaviour script `qube_rails/question.js` (search boxes, a rows field), served by the app's
  asset pipeline and keyed only on `data-qube-*` attributes, so it works on any markup, after Turbo
  navigation, with no CSP nonce. The inline scripts are gone: add `<%= qube_rails_assets %>` to your
  layout (`rails g qube_rails:install` does). The search route and hidden-input contract are
  documented for a custom combobox.
- The opt-in stylesheet `qube_rails.css` (`qube_rails_assets stylesheet: true`): zero specificity
  (`:where()`), themed by `--qube-*` variables, no global styles.
- The storyboard, `GET qube/storyboard(/:screen)` (`config.storyboard`, on in development): every
  screen from sample data in your layout, with each piece's override path; nothing is sent or saved.
- The question partial shows a rows field: the columns each row asks, a search per record column with
  its row; a fixed list (`enum`) as a select.
- Onboarding makes realtime connections (`config.connection_type`, `"realtime"` by default): workflows run
  only on realtime connections. A start QuBe Sync refuses as `realtime_required` raises
  `QubeRails::RealtimeRequired`, its message saying how to upgrade.
- A run whose question QuBe Sync took an answer to is `running` again at once (`Operation#answered(token,
  taken: true)`), not `needs_answer` until the Web Connector's next poll brings its next webhook.
- Plain v2 requests: `QubeRails::Request` (`OPERATION`, `SLUG`, `params`, and the handlers
  `answered`, `done`, `failed`, `retrying`, `timed_out`), `.queue(record, connection)` returning a
  `QubeRails::QueuedRequest` (one at a time per record, slug and connection; its reference is the
  `Idempotency-Key`; `retry_queue!`), and their webhook route `POST webhooks/qube/requests/:id`.
  Deliveries are taken once by `page_request_id:state`, and `done` fires once every page is in.
  `PruneRunsJob` and `Connection#disconnect!` delete requests too. New tables `qube_requests` and
  `qube_request_deliveries`: run `bin/rails qube_rails:install:migrations`.
- `config.prune_runs_after` and `QubeRails::PruneRunsJob`: opt-in pruning of ended runs
  (`Run.prunable`), never within a day of their end; links stay.
- `qube_sync_marks`: when each connection's last completed run of a workflow started
  (`Connection#last_synced_at(workflow)`, `Operation#last_synced_at`), a sync's next `since` that
  outlives pruned runs. Run `bin/rails qube_rails:install:migrations`.
- `DELETE quickbooks/connections/:id` (`connection_path`) disconnects a connection: QuBe Sync's,
  then the row with its runs and links (`Connection#disconnect!`), after
  `ConnectionEvents#disconnected`, where the app deletes its own rows that point at it. The `qube_rails/error` partial
  shows a route's message on a page without the run partials.
- A changed question's message no longer asks for a reload: "This question changed since the
  page showed it, so that answer was not sent: the page now shows where it stands."
- `POST qube/runs/:id/redeliver` and the run status partial's "Check for updates" for a
  run that looks stuck (`Run#looks_stuck?`): QuBe Sync sends its latest event again
  (qube_sync's `redeliver_run`). `SyncStatus` has `:done` for a run that completed and linked
  nothing, so `:in_quickbooks` always means a link with a `qb_id`.
- Sync status, derived and never stored: `connection.sync_status(record, operation:)`
  (`QubeRails::SyncStatus`: `:not_sent`, `:sending`, `:needs_answer`, `:in_quickbooks`, `:failed`,
  `:cancelled`, with `qb_id`, `error`, `retry?`), `SyncStatus.latest`, and the connection's scopes
  `in_quickbooks`, `not_in_quickbooks`, `needing_answer` and `sending`. A migration adds the
  indexes they use (`bin/rails qube_rails:install:migrations` again). The run status partial reads
  it, and takes `connection:`. Tested on SQLite, PostgreSQL and MySQL (whose cast takes the
  column's collation).
- A record's pages are told to refresh once more 5 seconds after an event (`QubeRails::RefreshJob`),
  for a page that was still loading the first time.
- `Operation.start` returns the record's run that hasn't ended on that connection (`run.reused?`),
  sending its start again with the same reference and input when it's unconfirmed, rather than
  starting another: the reference is the Idempotency-Key, so a double click can't add an invoice
  twice. Checked, and the new row written with its input, under the connection row's lock. A 409
  (the key in use by the other click) leaves the run "starting".
- The partials show why an answer or a start retry didn't go through (`flash[:qube_rails_error]`,
  once), which a plain-text 409 or 422 didn't under Turbo; and with turbo-rails 2 the job tells
  the record's pages to refresh when an event changes the run (`QubeRails.broadcast_refresh`).
- Connect with `simulated=1`, outside production: a connection to a simulated QuickBooks company
  file, connected as it's made, for testing with no Windows computer (qube_sync's
  `create_connection(type: "simulated")`).
- A refused webhook's log line names its path and what to check (the webhook secret, the clock,
  or a sender that isn't QuBe Sync).
- `QubeRails::MissingReference`, which the kit's mapped operations raise from `input` when a
  reference QuickBooks requires has no link and no name, so the start fails before anything is sent.
- Engine tables and models, from `bin/rails qube_rails:install:migrations`:
  `QubeRails::Connection` (`qube_connections`: an account can have any number, one per company
  file), `QubeRails::Run` (`qube_runs`: each run's reference, revision, state and question) and
  `QubeRails::QuickbooksRecord` (`qube_quickbooks_records`: QuickBooks ids by connection and kind).
  The app's tables need no QuBe columns. JSON is kept as text (`QubeRails::JSONCoder`), the same
  on PostgreSQL, MySQL and SQLite.
- `QubeRails::Engine`, mounted with `mount QubeRails::Engine => "/"`: onboarding
  (`POST quickbooks/connections`, `POST quickbooks/connections/:id/onboarding`), the webhook
  endpoint (`POST webhooks/qube/runs/:id`, `POST webhooks/qube/connections/:id`) and the question
  routes (`POST qube/questions/runs/:id`, `GET .../search`).
- `QubeRails::WebhookJob` (ActiveJob) and `QubeRails.run(kind, id, body)`, for an app with another
  queue.
- `QubeRails::Operation` (`start(record, connection)` returns the run) and
  `QubeRails::ConnectionEvents`, the bases of the app's classes, with the reference, connection
  id, revision and delivery-id checks under the row's lock.
- `Connection#link`, `#qb_id_for`, `#find_linked(qb_id, kind: nil)` and
  `#quickbooks_record(qb_id, kind: nil)`. QuickBooks ids are unique by connection and list family
  (`QubeRails::QuickbooksRecord.family_for`: one family for names, one for items, and each other
  list or transaction type its own), as QuickBooks gives out ListIDs (verified on QuickBooks
  Enterprise 24.0).
- The question partial, `qube_rails/_question.html.erb`, showing a record's latest run's question,
  which the app can override.
- `QubeRails.configure` in `config/initializers/qube_rails.rb`: operations, connection_events,
  current_account, authorize_question, enqueue, queue, dedupe, parent_controller and the API
  settings. An unset setting raises `QubeRails::NotConfigured` naming that file.
  `authorize_question` defaults to allowing only the account that owns the run's connection.
- A delivery whose run, connection or record was deleted is logged and dropped, not retried.
- Connect (`POST quickbooks/connections`) reuses the account's newest never-connected connection;
  `new=1` makes another. A connection's event for a row without its `qube_id` adopts QuBe Sync's
  connection made with the row's webhook URL, or raises `QubeRails::NotReady` to be retried.
- A start that gets no answer stays `starting` with its input; `Run#retry_start!` /
  `Operation.retry_start` resend it with the same Idempotency-Key. Only a 4xx, or an input that
  raised, marks a run `failed`.
- The webhook endpoint answers 503 when the enqueue returns false or raises.
  `QubeRails::WebhookJob` retries (`retry_on`, `job_attempts`, default 10) and logs when it gives
  up.
- `Operation#quickbooks_ref` and `#link_references`.
- Notification dedupe by default in the engine's `qube_notifications` table
  (`QubeRails::DatabaseDedupe`), in the same transaction as the handler, so a handler that raises
  runs again on the redelivery. `QubeRails::CacheDedupe` stays as an option.
- Every ending kept on the run row (state, outcome, error, cancel_reason, ended_at) before the
  app's handler runs; `Run#ended?`, `#failed?`, `#cancelled?`, `#summary_text`, and the
  `qube_rails/run_status` partial. A completed run on a `cancelled` outcome reads as cancelled; a
  start unconfirmed for a minute reads "Still waiting for QuickBooks", with a "Try sending
  again" button posting to `POST qube/runs/:id/retry_start`.
- Adoption takes only a never-connected (or simulated) QuBe Sync connection whose `created_at` is at or after the
  row's, with its webhook URL and name; one with no `created_at` is never adopted.
- `rails g qube_rails:install`: the initializer, the app's `QuickbooksDesktop::ConnectionEvents`,
  the engine's migrations and the mount line.
- `bin/rails g qube_rails:workflows [--drafts] [--check]` writes `app/qube/qube_workflows.rb`
  (`QubeWorkflows`, autoloaded) and `sig/qube_workflows.rbs` from the app's workflow input types,
  through qube_sync's renderer: typed start and input methods per workflow and branch, starting
  runs on `QubeRails.client`. `--check` exits 1 when the file is out of date or the key is refused,
  and warns and passes when QuBe Sync can't be reached. `QubeRails::Backend` gains
  `workflow_types`, `render_workflow_types` and `check_workflow_types`.
- `QubeRails::Operation#input` is documented as able to return a generated input method's Hash
  (`QubeWorkflows::AddTransaction.invoice_input(...)`, RBS type
  `QubeWorkflows::AddTransaction::invoice_input`); it still returns a Hash.

### Changed
- Needs Ruby 3.3, Rails 7.0 and qube_sync 0.4.0 or later. The source stays Ruby 2.7 and Rails
  5.2 compatible, and every call to qube_sync goes through `QubeRails::Backend`, so the kit can
  vendor it into older apps.

### Removed
- Everything from 0.1.0 (v1): the generator's models, migrations, controllers and jobs, and the
  path dependency on qube_sync.

## 0.1.0 (2024-01-21)

The v1 engine: generated QuickBooks entity models, connection and request tables, and a webhook
job for customer queries.
