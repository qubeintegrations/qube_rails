# qube_rails

QuBe Sync's Rails engine, for QuickBooks Desktop through [qubesync.com](https://qubesync.com). It
holds the part of an integration that's the same in every Rails app:

- three tables of its own: your customers' **connections** (an account can have several, one per
  company file), the **runs** your app starts, and the **QuickBooks ids** it learns, each kept
  against its connection;
- onboarding: make a connection for the signed-in account, or send one of its connections back
  through QuBe Sync's setup;
- the webhook endpoint (verify the signature, find the row, enqueue) and its job (check the event
  is that run's or that connection's, apply it, call your handler);
- the question routes (answer by choice, search a record field) and the question partial;
- `QubeRails::Operation` and `QubeRails::ConnectionEvents`, the bases of your classes.

Your app keeps its own code, which this gem never names: one initializer, an operation class per
way it starts a workflow, and a class for a connection's events. Your own tables need no QuBe
columns. Update the engine with `bundle update qube_rails`; your files stay as you wrote them.

Needs Ruby 3.3 or later and Rails 7.0 or later, and the [qube_sync](https://rubygems.org/gems/qube_sync)
gem 0.4.0 or later, which it installs. Works on PostgreSQL, MySQL and SQLite.

## Install

```ruby
# Gemfile
gem "qube_rails", ">= 0.2.0"
```

```sh
bundle install
bin/rails g qube_rails:install
bin/rails db:migrate
```

The generator writes:

- `config/initializers/qube_rails.rb`, every setting, commented;
- `app/services/quickbooks_desktop/connection_events.rb`, your class for a connection's events;
- the engine's migration (`bin/rails qube_rails:install:migrations`), which adds
  `qube_connections`, `qube_runs` and `qube_quickbooks_records`;
- `mount QubeRails::Engine => "/"` in `config/routes.rb`.

Fill in `current_account` in the initializer before anything else: onboarding and the question
routes both need it.

## Routes

Relative to where the engine is mounted (`"/"` above):

| Route | What it does |
| --- | --- |
| `POST quickbooks/connections` | A new connection for the signed-in account (`current_account`), from a "Connect QuickBooks Desktop" button, with an optional `name`. Writes the row, makes QuBe Sync's connection with the row's webhook URL, keeps its `qube_id`, and redirects (303) to the setup. |
| `POST quickbooks/connections/:id/onboarding` | One of the signed-in account's connections, back through setup, with its webhook URL brought up to date (or made at QuBe Sync, for a row QuBe Sync never answered). Another account's connection answers 404. |
| `POST webhooks/qube/runs/:id` | A run's webhooks. |
| `POST webhooks/qube/connections/:id` | A connection's webhooks. |
| `POST qube/questions/runs/:id` | Your user's answer to the run's question, from the partial. Behind your sign-in and CSRF. |
| `GET qube/questions/runs/:id/search` | A record field's matches, as JSON. Behind your sign-in. |

The webhook routes verify the signature (401 if it doesn't check out), answer 404 when the row
isn't there, enqueue, and answer 200. No sign-in, no CSRF, the raw body, any content type, up to
5 MB. Each id in a URL is only a pointer: the job checks the signed event's reference and
connection id against the row.

Onboarding and the question routes inherit your `ApplicationController` (the `parent_controller`
setting), so its sign-in and CSRF protection apply. Your views reach the routes through the
engine's proxy: `qube_rails.connections_path`, `qube_rails.connection_onboarding_path(connection)`.

```erb
<%= button_to "Connect QuickBooks Desktop", qube_rails.connections_path, params: { name: "Main file" } %>
```

## Settings

In `config/initializers/qube_rails.rb`, the only place the engine reads your app from:

```ruby
QubeRails.configure do |config|
  config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
  config.connection_events = "QuickbooksDesktop::ConnectionEvents"
  config.current_account = ->(controller) { controller.current_user.account }
end
```

| Setting | What it is | Default |
| --- | --- | --- |
| `operations` | slug => operation class *name* (resolved when used, so code reloading works) | none: raises |
| `connection_events` | your `QubeRails::ConnectionEvents` class's name | none: raises |
| `current_account` | `->(controller) { account }`: the signed-in customer's account, which owns its connections. nil answers 401. | none: raises |
| `authorize_question` | `->(controller, record, run) { true }` when the signed-in user may answer or search that run's question. The run carries its `operation` and its `connection` (whose `owner` connected it). Only `true` allows; anything else answers 404 (search: `[]` with 404), as for a missing run, and is logged. | allows only when `current_account` owns the run's connection (compared by type and id, so a nil or unsaved account never matches) |
| `enqueue` | `->(delivery) { ... }`, handing `{ kind:, id:, body: }` (kind `"run"` or `"connection"`) to a queue | ActiveJob: `QubeRails::WebhookJob` on `queue` |
| `queue` | the ActiveJob queue | `:default` |
| `dedupe` | `seen?(key)` / `remember(key)` for notification delivery ids | `QubeRails::CacheDedupe`: `Rails.cache`, one day |
| `parent_controller` | the controller onboarding and the questions inherit | `"ApplicationController"` |
| `api_key` | | `QUBE_API_KEY` |
| `base_url` | | `QUBE_URL`, else `https://qubesync.com` |
| `webhook_secret` | a secret, or a list while one rotates | `QUBE_WEBHOOK_SECRET` |
| `webhook_url` | the base of every webhook URL | `QUBE_WEBHOOK_URL` |

A setting your app hasn't written raises `QubeRails::NotConfigured`, naming the initializer, the
first time it's needed, so nothing silently passes. The environment is read at first use.
Secrets are never logged, and `QubeRails.config.inspect` hides them.

`controller` is the engine's controller handling the request, a subclass of your
`ApplicationController`, so `current_user` and your other helpers are on it.

Set `authorize_question` only to change who may answer. The default lets the account that owns
the run's connection answer it, which is right for most apps. Set your own to check more (that
this user may see the record) or less (staff who act for any account):

```ruby
config.authorize_question = ->(controller, record, run) {
  run.connection.owner == controller.current_user.account && controller.current_user.can_edit?(record)
}
```

The default dedupe store is `Rails.cache`: make that a store your workers share (Redis, Solid
Cache), or a retry that reaches another worker isn't caught.

## Background work

QuBe Sync's webhooks are handled in the background. The endpoint verifies a delivery, answers 200
at once, and hands the work to `QubeRails::WebhookJob`, an ActiveJob, so it runs on whatever queue
your app's ActiveJob uses (Sidekiq, Solid Queue, GoodJob...). Most apps change nothing here; set
`queue` to put it on a queue other than `:default`.

If your app's workers don't run ActiveJob (plain Sidekiq workers, say), set `enqueue` to hand the
delivery to your own worker, and have that worker call `QubeRails.run` with what it was given:

```ruby
# config/initializers/qube_rails.rb
config.enqueue = ->(delivery) {
  QubeDeliveryWorker.perform_async(delivery[:kind], delivery[:id], delivery[:body])
}

# app/workers/qube_delivery_worker.rb
class QubeDeliveryWorker
  include Sidekiq::Job

  def perform(kind, id, body)
    QubeRails.run(kind, id, body)
  end
end
```

Retries are your queue's. QuBe Sync stops sending a delivery once your endpoint has answered 200,
so if the work fails later, your queue is the only thing that will run it again. `QubeRails.run`
raises when it can't do the work (a handler of yours raised, the database is down, or the run's
operation was taken out of `operations`), so a queue that retries failed jobs will retry it.

One case isn't retried: a delivery whose run, connection or record has been deleted from your
database since it arrived. The endpoint answers 404 unless the run or connection row exists, and
your app saves a record before starting its run, so a row that's missing by the time the job runs
was deleted, and retrying would never succeed. `QubeRails.run` logs a warning ("QuBe Sync:
dropped ...") and returns.

## Environment

| Variable | What it is |
| --- | --- |
| `QUBE_API_KEY` | your app's API key; `qube env --write .env` writes it |
| `QUBE_WEBHOOK_SECRET` | your app's webhook secret; `qube env --write .env` writes it |
| `QUBE_URL` | `https://qubesync.com` unless you're told otherwise |
| `QUBE_WEBHOOK_URL` | the base of each run's and each connection's webhook URL: `qube listen --write-env .env` writes it in development, and in production it's your app's `/webhooks/qube` |

## Connections

A `QubeRails::Connection` is one company file: `owner` (your account), `qube_id` (QuBe Sync's
id, nil until it answers), `name`, `status` (`pending`, `connected`, `setup_cancelled`,
`stalled`), `stall_reason` and `revision`. `QubeRails::Connection.owned_by(account)` lists an
account's.

Its own events (QUBE_WEBHOOK_URL/connections/<id>) update `status`, `stall_reason` and `revision`
when the event is for that connection (`qube_id`) and newer than the last one applied, under the
row's lock. Then your class runs, with `connection` and `owner`:

```ruby
module QuickbooksDesktop
  class ConnectionEvents < QubeRails::ConnectionEvents
    # QuickBooks is connected: start syncing.
    def connected(event)
      InitialImport.start(owner, connection)
    end

    # They chose "Cancel setup": offer to set it up again.
    def setup_cancelled(event)
      log_event(event)
    end

    # connection.stall_reason: "not_checking_in" (turn on the QuickBooks computer and check the
    # Web Connector runs) or "quickbooks_unavailable" (open QuickBooks with the company file).
    def stalled(event)
      AccountMailer.quickbooks_stalled(owner, connection).deliver_later
    end

    def resumed(event)
      log_event(event)
    end
  end
end
```

### QuickBooks ids

Every ListID and TxnID your app learns is kept against its connection and kind, since QuickBooks
makes one unique only within one list of one company file:

```ruby
connection.link(customer, kind: "customer", qb_id: list_id, edit_sequence: "171", name: "Riverbend Electric")
connection.qb_id_for(customer, kind: "customer")      # => "80000001-1738310400", or nil
connection.find_linked("customer", list_id)           # => your Customer, or nil
connection.quickbooks_record("customer", list_id)     # => the row, with edit_sequence and name
```

A record has one id per kind on a connection; linking it again replaces it. An id already linked
to another of your records moves to this one, and that's logged.

## Writing an operation

One class per way your app starts a workflow, listed in `config.operations` by its `SLUG`:

```ruby
# app/services/quickbooks_desktop/create_invoice.rb
module QuickbooksDesktop
  class CreateInvoice < QubeRails::Operation
    WORKFLOW = "add_transaction"
    SLUG = "create_invoice"

    # Optional: your record, by the id its run keeps. Leave it out and the run finds the record
    # by its type; write it to load what the input reads.
    def self.find_record(id)
      Invoice.includes(lines: :item).find_by(id: id)
    end

    # The run's input, from the record. without_nils leaves out a field your record doesn't have
    # yet rather than sending it as null.
    def input
      without_nils({
        operation: "invoice.create",
        params: {
          customer_ref: customer_ref,
          ref_number: record.number,
          invoice_line_add: record.lines.map { |line|
            { item_ref: { full_name: line.item&.name }, amount: line.total&.to_f }
          }
        }
      })
    end

    # How the run ended: event.outcome says which, event.output holds the result. Keep the
    # QuickBooks ids it carries on the connection.
    def ended(event)
      txn = event.dig("output", "record") || {}
      connection.link(record, kind: "invoice", qb_id: txn["txn_id"],
                              edit_sequence: txn["edit_sequence"], name: txn["ref_number"])
      record.update!(status: "sent")
    end

    # A run that failed, or that your app cancelled.
    def failed(event)
      record.update!(status: "failed")
    end

    # What a running workflow sends along (a sync's pages): taken once per delivery_id.
    def notification(event)
      log_event(event)
    end

    private

    # The customer's ListID on this connection when it's linked, else its name.
    def customer_ref
      list_id = connection.qb_id_for(record.customer, kind: "customer")
      list_id ? { list_id: list_id } : { full_name: record.customer.name }
    end
  end
end
```

```ruby
run = QuickbooksDesktop::CreateInvoice.start(invoice, connection)
```

`start` takes a connection QuBe Sync has made (it raises `QubeRails::NotConnected` for one with
no `qube_id`). It writes the run's row first, with a new reference and state `starting`, since a
webhook can come before it returns; starts the run with that reference as the idempotency key and
`QUBE_WEBHOOK_URL/runs/<run id>` as its webhook URL; keeps QuBe Sync's `qube_run_id`, `state`,
`run_url` and `cancel_url`; and returns the row. A start that raises marks the row `failed` and
raises again.

A `QubeRails::Run` keeps `operation`, `record`, `connection`, `reference`, `revision`, `state`,
`outcome`, and the open `question` and its `links`. Each event is applied under the run row's
lock: one whose reference isn't the run's, or whose `connection_id` isn't its connection's, is
skipped and logged; a notification is taken once; anything else only when its revision is newer
than the last applied. Handlers see `record`, `run` and `connection`. A handler you don't write
logs.

## Questions

When a run asks your user something, `Operation#question` keeps it on the run. Show it on the
record's page:

```erb
<%= render "qube_rails/question", record: @invoice, operation: "create_invoice" %>
```

Its locals are `record` and `operation` (the slug). It shows the open question of that record's
latest run of that operation, and nothing when that run isn't asking. Each choice is a form
posting to the run's question route with your CSRF token, and a record field's box searches
through your app, so the API key never reaches the browser. Style it with its `qube-` classes, or
copy the partial to `app/views/qube_rails/_question.html.erb` in your app for other markup: Rails
renders yours instead.

An answer QuBe Sync can't take (422) shows its reason; one it says has changed (409, or any 400)
forgets the question and answers 409; the run's next webhook says what came of it.

## Storage

`qube_runs.question` and `qube_runs.links` are JSON kept as text (`QubeRails::JSONCoder`), not a
native json column: the engine runs on PostgreSQL, MySQL and SQLite, from Rails 5.2 (vendored into
older apps) to 8.1, and the native types and what each adapter returns differ. Nothing queries
inside them. Polymorphic ids (`owner_id`, `record_id`) are strings, so integer and UUID keys both
fit.

## Upgrading

From the integration kit's generated code: keep your operation classes (now
`QuickbooksDesktop::... < QubeRails::Operation`; `start` takes the connection row and handlers
gain `run` and `connection`), move `account_id`, `authorize_question!` and
`QubeWebhookJob::OPERATIONS` into the initializer, move the connection handlers into your
`QuickbooksDesktop::ConnectionEvents`, and delete the generated controllers, job, partial,
`QubeSync` module and routes in favour of the mount line. Copy each account's connection into
`qube_connections` (its owner, `qube_id` and status) and drop the `qube_*` columns from your
tables once nothing reads them.

From qube_rails 0.1.0 (v1): 0.2.0 shares nothing with it. Its models and tables are yours to keep
or drop.

## Development

```sh
bundle install && bundle exec rspec     # RAILS_VERSION=7.0 for the oldest Rails
bin/syntax-check-2.7                     # every shipped file parses on Ruby 2.7
```

qube_sync 0.4.0 isn't published yet: the Gemfile takes it from `../wt-qube_sync_rb` (or
`QUBE_SYNC_PATH`) when that checkout is there.

The source is kept Ruby 2.7 and Rails 5.2 compatible, and every call to qube_sync goes through
`QubeRails::Backend`, so QuBe Sync's kit can vendor the same files, with an inline backend, into
an app below the gem's Ruby 3.3 floor.

## License

MIT
