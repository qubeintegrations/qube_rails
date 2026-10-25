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
- `Connection#link`, `#qb_id_for`, `#find_linked` and `#quickbooks_record`.
- The question partial, `qube_rails/_question.html.erb`, showing a record's latest run's question,
  which the app can override.
- `QubeRails.configure` in `config/initializers/qube_rails.rb`: operations, connection_events,
  current_account, authorize_question, enqueue, queue, dedupe, parent_controller and the API
  settings. An unset setting raises `QubeRails::NotConfigured` naming that file.
  `authorize_question` defaults to allowing only the account that owns the run's connection.
- A delivery whose run, connection or record was deleted is logged and dropped, not retried.
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
