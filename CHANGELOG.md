# Changelog

## 0.2.0 (unreleased)

A rewrite on QuBe Sync's v2 API, holding the code QuBe Sync's integration kit used to generate
into every Rails app, so the app keeps only its own.

### Added
- Three engine tables and models, from `bin/rails qube_rails:install:migrations`:
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
- Every ending kept on the run row (state, outcome, error, cancel_reason, ended_at) before the
  app's handler runs; `Run#ended?`, `#failed?`, `#cancelled?`, `#summary_text`, and the
  `qube_rails/run_status` partial.
- Adoption takes only a never-connected QuBe Sync connection made after the row, with its name.
- `rails g qube_rails:install`: the initializer, the app's `QuickbooksDesktop::ConnectionEvents`,
  the engine's migrations and the mount line.

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
