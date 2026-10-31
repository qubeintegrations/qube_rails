# Changelog

## 0.2.1 (unreleased)

Connections keep their type, so workflows aren't started on standard ones, and run webhooks are
read as QuBe Sync now sends them. Run `bin/rails qube_rails:install:migrations` and
`bin/rails db:migrate`.

### Added

**Connections and onboarding**
- `qube_connections.connection_type` (`realtime`, `standard` or `simulated`), set when Connect
  makes the connection and kept up to date by the connection's events; `Connection#standard?` and
  `Connection#refresh_type!` (reads it from QuBe Sync after an upgrade in the dashboard).
- Connect (`POST quickbooks/connections`) takes `type=realtime` or `type=standard`, else
  `config.connection_type`; any other type answers 422. It sends back through setup only a
  never-connected connection of that type.

**Starting workflows**
- `Operation.start` on a standard connection raises `QubeRails::RealtimeRequired` before writing a
  run or calling QuBe Sync.
- A start QuBe Sync refuses with 422 `realtime_required` keeps its run, as state
  `realtime_required` with `error` `{code, detail}`, rather than failing it. The run status shows
  the detail and the "Try sending again" button, and `run.retry_start!` (or starting again) sends
  it with the same Idempotency-Key once the connection is upgraded: QuBe Sync stores nothing for
  that refusal.

**Run status**
- `run.headline`, every event's sentence for a person (`qube_runs.headline`), shown for an ended
  run whose reason doesn't already say it (`.qube-run-headline`).
- `Run#with_errors?`: an outcome such as `push_records`' `pushed_with_errors` reads "Done, but some
  didn't go through" (`status.done_with_errors`) and adds `.qube-run-with-errors`.

### Changed

- A failed run's `error` is QuBe Sync's `{code, type, message, quickbooks_message, hint}`:
  `reason_text` is its message and `error_detail` its hint. An error stored by 0.2.0 (a sentence,
  or code, message and detail) still reads.
- A run's `cancel_url` is cleared when it ends; `links.decisions` and `links.search` may be absent.
- A `rows` field's boolean columns answer `true` or `false`, not the text `"true"`.
- The storyboard's sample prompts drop `options`, which run webhooks no longer carry.

### Compatibility

Matches QuBe Sync's reshaped workflow-run webhooks (qube PR #61): the error object, `headline`,
an `output` per outcome without `output.outcome` (add_transaction's `added` keeps `record` and
`references`, so `link_references` is unchanged), links only while they work, no
`prompt.options`, and `summary.changes` in place of `summary.side_effects` (the engine read
neither). Webhooks in the old shape are still read. The start's 422 `realtime_required` answer is
the same before and after that change.

## 0.2.0 (2026-10-27)

A rewrite on QuBe Sync's v2 API. The engine now holds the code QuBe Sync's integration kit used to
generate into every Rails app (the webhook endpoint, onboarding, questions, connections, runs and
QuickBooks ids), so your app keeps only its own operations, its connection events class and one
initializer, and gets fixes with `bundle update qube_rails`. Nothing from 0.1.0 carries over.

### Added

**Install and configure**
- `rails g qube_rails:install`: the initializer, your app's `QuickbooksDesktop::ConnectionEvents`,
  the engine's migrations and the mount line (`mount QubeRails::Engine => "/"`).
- `QubeRails.configure` in `config/initializers/qube_rails.rb`: operations, connection_events,
  current_account, authorize_question, enqueue, queue, dedupe, parent_controller and the API
  settings. A setting left unset raises `QubeRails::NotConfigured` naming that file.

**Connections and onboarding**
- Engine tables and models, from `bin/rails qube_rails:install:migrations`:
  `QubeRails::Connection` (`qube_connections`; an account can have any number, one per company
  file), `QubeRails::Run` (`qube_runs`: each run's reference, revision, state and question) and
  `QubeRails::QuickbooksRecord` (`qube_quickbooks_records`: QuickBooks ids by connection). Your
  own tables need no QuBe Sync columns. JSON is stored as text, the same on PostgreSQL, MySQL and
  SQLite.
- Onboarding routes: `POST quickbooks/connections` (Connect) and
  `POST quickbooks/connections/:id/onboarding`. Connect reuses the account's newest
  never-connected connection; `new=1` makes another.
- Onboarding makes realtime connections (`config.connection_type`, `"realtime"` by default),
  since workflows run only on realtime connections.
- Connect with `simulated=1`, outside production, makes a connection to a simulated QuickBooks
  company file, connected as soon as it's made, for testing without a Windows computer.
- A connection event for a row that doesn't have its QuBe Sync id yet adopts the QuBe Sync
  connection made with that row's webhook URL and name, created at or after the row (a
  never-connected or simulated one), or raises `QubeRails::NotReady` to be retried.
- `DELETE quickbooks/connections/:id` (`connection_path`) disconnects a connection: QuBe Sync's
  first, then the row with its runs, requests and links (`Connection#disconnect!`), after
  `ConnectionEvents#disconnected`, where your app deletes its own rows that point at it.

**Starting workflows**
- `QubeRails::Operation`, the base of your operations: `start(record, connection)` returns the
  run. A record's run that hasn't ended on that connection is returned (`run.reused?`) rather
  than a second one started, so a double click can't add an invoice twice; an unconfirmed start
  is sent again with the same reference (the Idempotency-Key) and input.
- A start that gets no answer stays `starting` with its input; `Run#retry_start!` and
  `Operation.retry_start` resend it with the same Idempotency-Key. Only a 4xx, or an input that
  raised, marks a run failed.
- `Operation#quickbooks_ref` and `#link_references`, and `QubeRails::MissingReference`, raised
  from `input` when a reference QuickBooks requires has no link and no name, so the start fails
  before anything is sent.
- Typed workflow starts: `bin/rails g qube_rails:workflows [--drafts] [--check]` writes
  `app/qube/qube_workflows.rb` (`QubeWorkflows`, autoloaded) and `sig/qube_workflows.rbs` from
  your app's workflow input types, with a typed start and input method per workflow and branch.
  `Operation#input` can return one of those input methods' Hashes. `--check` exits 1 when the
  file is out of date or the API key is refused, and warns but passes when QuBe Sync can't be
  reached.
- A start QuBe Sync refuses because the connection isn't realtime raises
  `QubeRails::RealtimeRequired`, whose message says how to upgrade.

**Plain requests**
- `QubeRails::Request`, the base of a plain v2 request (`OPERATION`, `SLUG`, `params`, and the
  handlers `answered`, `done`, `failed`, `retrying`, `timed_out`). `.queue(record, connection)`
  returns a `QubeRails::QueuedRequest`: one at a time per record, slug and connection, its
  reference the Idempotency-Key, `retry_queue!` to send it again. Their webhooks arrive at
  `POST webhooks/qube/requests/:id`; each delivery is taken once by `page_request_id:state`, and
  `done` fires once every page is in.

**Webhooks**
- The webhook endpoint, `POST webhooks/qube/runs/:id` and `POST webhooks/qube/connections/:id`,
  verifies each delivery and hands it to `QubeRails::WebhookJob` (ActiveJob), or to
  `QubeRails.run(kind, id, body)` from your own queue. It answers 503 when the enqueue fails, so
  QuBe Sync retries. A refused delivery's log line names its path and what to check (the webhook
  secret, the clock, or a sender that isn't QuBe Sync).
- The reference, connection id, revision and delivery id are checked under the row's lock, and
  notifications are deduplicated in the engine's `qube_notifications` table in the same
  transaction as your handler, so a handler that raises runs again on the redelivery
  (`QubeRails::CacheDedupe` is an option). `WebhookJob` retries (`job_attempts`, default 10) and
  logs when it gives up. A delivery for a deleted run, connection or record is logged and dropped.
- `QubeRails::ConnectionEvents`, the base of your connection events class.

**Questions**
- The question routes, `POST qube/questions/runs/:id` and `GET .../search`, and the
  `qube_rails/_question.html.erb` partial showing a record's latest run's question, which you can
  override. `authorize_question` defaults to allowing only the account that owns the run's
  connection; a refused one answers 404.
- When a question changed after the page showed it, the answer isn't sent and the page says
  where it stands now.
- A rows field (the missing-records question) shows a block per record: its choice ("Create it",
  "Use an existing one") as a segmented control, then only the fields that choice needs, with a
  search per record column. "Set all to" and "Use for all N" fill every record at once. It never
  scrolls sideways. A fixed list shows as a select.
- A question whose answer QuBe Sync took is `running` again at once (`Operation#answered(token,
  taken: true)`), rather than waiting for the Web Connector's next poll.

**Runs and sync status**
- Every ending is kept on the run (state, outcome, error, cancel reason, ended at) before your
  handler runs: `Run#ended?`, `#failed?`, `#cancelled?`, `#summary_text`, and the
  `qube_rails/run_status` partial (taking `connection:`). A start unconfirmed for a minute reads
  "Still waiting for QuickBooks" with a "Try sending again" button
  (`POST qube/runs/:id/retry_start`).
- A run that looks stuck (`Run#looks_stuck?`) gets a "Check for updates" button, which has QuBe
  Sync send its latest event again (`POST qube/runs/:id/redeliver`).
- While the connection a sending run waits on is stalled, the status reads "Waiting for
  QuickBooks" and says why and what to do. `connection.stalled` and `connection.resumed` refresh
  the pages of records with a run going on that connection.
- Sync status, derived from runs and links and never stored:
  `connection.sync_status(record, operation:)` (`QubeRails::SyncStatus`: `:not_sent`,
  `:sending`, `:needs_answer`, `:in_quickbooks`, `:done`, `:failed`, `:cancelled`, with `qb_id`,
  `error` and `retry?`), `SyncStatus.latest`, and the connection's scopes `in_quickbooks`,
  `not_in_quickbooks`, `needing_answer` and `sending`. Tested on SQLite, PostgreSQL and MySQL.
- The partials show why an answer or a retried start didn't go through, and with turbo-rails 2
  a record's pages refresh when an event changes its run, and once more 5 seconds later
  (`QubeRails::RefreshJob`) for a page that was still loading.
- `config.prune_runs_after` and `QubeRails::PruneRunsJob`: opt-in pruning of ended runs and
  requests (`Run.prunable`), never within a day of their end; links stay. `qube_sync_marks` keeps
  when each connection's last completed run of a workflow started
  (`Connection#last_synced_at(workflow)`, `Operation#last_synced_at`), so a sync's next `since`
  outlives pruned runs.

**Screens and styling** (README, "Styling")
- The question and run status partials (`render "qube_rails/question"`, `render
  "qube_rails/run_status"`) are made of small pieces under `qube_rails/question/*`,
  `qube_rails/run_status/*` and `qube_rails/_error`, each overridable at its path and rendered
  from view-models whose fields are the contract (`QubeRails::QuestionView`, `ChoiceView`,
  `FieldView`, `RowsView`, `RowView`, `CellView`, `RunStatusView`). A question's choices show by
  kind: suggested records as option rows, each form in its own section with the one filled
  button, and "None of these" and "Cancel" in a footer.
- `config.ui_classes`: your CSS framework's classes by piece, beside the `qube-` classes; an
  unknown piece raises.
- `<%= qube_rails_assets %>` in your layout (`rails g qube_rails:install` adds it) serves the
  behaviour script `qube_rails/question.js` (search boxes, rows fields), keyed only on
  `data-qube-*` attributes, so it works on any markup, after Turbo navigation, with no CSP nonce.
  `qube_rails_assets stylesheet: true` adds the opt-in stylesheet `qube_rails.css`: zero
  specificity, themed by `--qube-*` variables, light and dark, no global styles.
- The screens never name QuBe Sync, runs, webhooks or ListIDs to your users, and every word comes
  from I18n under `qube_rails.*` (`config/locales/en.yml`; `QubeRails.t`), so you can reword or
  translate them.
- The storyboard, `GET qube/storyboard(/:screen)` (`config.storyboard`, on in development):
  every screen from sample data, in your layout, with each piece's override path. Nothing is sent
  or saved.

**QuickBooks ids**
- `Connection#link`, `#qb_id_for`, `#find_linked(qb_id, kind: nil)` and
  `#quickbooks_record(qb_id, kind: nil)`. QuickBooks ids are kept by connection and list family
  (`QuickbooksRecord.family_for`: one family for customers, vendors, employees and other names,
  one for items, and each other list or transaction type its own), since QuickBooks gives out
  ListIDs that way.

### Changed
- Needs Ruby 3.3, Rails 7.0 and qube_sync 0.5.0 or later. The source stays Ruby 2.7 and Rails
  5.2 compatible, and every call to qube_sync goes through `QubeRails::Backend`, so the kit can
  vendor it into older apps.

### Removed
- Everything from 0.1.0 (v1): the generator's models, migrations, controllers and jobs, and the
  path dependency on qube_sync.

## 0.1.0 (2024-01-21)

The v1 engine: generated QuickBooks entity models, connection and request tables, and a webhook
job for customer queries.
