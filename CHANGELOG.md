# Changelog

## 0.2.0 (unreleased)

A rewrite on QuBe Sync's v2 API, holding the code QuBe Sync's integration kit used to generate
into every Rails app, so the app keeps only its own.

### Added
- `QubeRails::Engine`, mounted with `mount QubeRails::Engine => "/"`: the webhook endpoint
  (`POST /webhooks/qube/:operation/:record_id`), onboarding (`POST /quickbooks/connect`) and the
  question routes (`POST /qube/questions/:operation/:record_id`, `GET .../search`).
- `QubeRails::WebhookJob` (ActiveJob) and `QubeRails.run`, for an app with another queue.
- `QubeRails::Operation` and `QubeRails::ConnectionEvents`, the bases of the app's operation and
  connection classes, with the reference, revision and delivery-id checks under the row lock.
- The question partial, `qube_rails/_question.html.erb`, which the app can override.
- `QubeRails.configure` in `config/initializers/qube_rails.rb`: operations, connection,
  current_account, authorize_question, enqueue, queue, dedupe, parent_controller and the API
  settings. An unset setting raises `QubeRails::NotConfigured` naming that file.
- `rails g qube_rails:install [table]`: the initializer, a connection class, its migration and
  the mount line.

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
