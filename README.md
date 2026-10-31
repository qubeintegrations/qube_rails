# qube_rails

QuBe Sync's Rails engine, for QuickBooks Desktop through [qubesync.com](https://qubesync.com). It
holds the part of an integration that's the same in every Rails app:

- tables of its own: your customers' **connections** (an account can have several, one per
  company file), the **runs** your app starts (and any plain **requests**), and the **QuickBooks ids** it learns, each kept
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
gem 0.5.0 or later, which it installs. Works on PostgreSQL, MySQL and SQLite.

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
  `qube_connections`, `qube_runs`, `qube_notifications` and `qube_quickbooks_records`;
- `mount QubeRails::Engine => "/"` in `config/routes.rb`;
- `<%= qube_rails_assets %>` in your layout's `<head>`, the question's behaviour script
  ([Styling](#styling)).

Fill in `current_account` in the initializer before anything else: onboarding and the question
routes both need it.

## Routes

Relative to where the engine is mounted (`"/"` above):

| Route | What it does |
| --- | --- |
| `POST quickbooks/connections` | Connect, for the signed-in account (`current_account`). Sends its newest connection that has never connected (`pending` or `setup_cancelled`) back through setup, so clicking Connect again doesn't pile up connections. Makes a new one (the row, then QuBe Sync's connection with the row's webhook URL and its type, then its `qube_id`, with an optional `name`) when the account has none of that type, or with `new=1`. The type is the `type` param, `realtime` or `standard`, else `config.connection_type` (`"realtime"` by default, since workflows run only on realtime connections); any other `type` answers 422. The row keeps it as `connection_type`. Redirects (303) to the setup. With `simulated=1`, outside production, it makes a new connection to a simulated QuickBooks company file instead, connected as it's made, and redirects back: for testing with no Windows computer. In production that answers 404. |
| `POST quickbooks/connections/:id/onboarding` | One of the signed-in account's connections, back through setup, with its webhook URL brought up to date (or made at QuBe Sync, for a row QuBe Sync never answered). Another account's connection answers 404. |
| `DELETE quickbooks/connections/:id` | Disconnects one of the signed-in account's connections: QuBe Sync deletes its connection (already gone counts), then the row goes, with its runs, requests and QuickBooks links. Refused while a run or request hasn't ended; another account's connection answers 404. Show its message with `render "qube_rails/error"`. |
| `POST webhooks/qube/runs/:id` | A run's webhooks. |
| `POST webhooks/qube/connections/:id` | A connection's webhooks. |
| `POST webhooks/qube/requests/:id` | A plain request's webhooks ([Plain requests](#plain-requests)). |
| `POST qube/questions/runs/:id` | Your user's answer to the run's question, from the partial. Behind your sign-in and CSRF. |
| `GET qube/questions/runs/:id/search` | A record field's matches, as JSON. Behind your sign-in. |
| `POST qube/runs/:id/redeliver` | A run that looks stuck (`Run#looks_stuck?`: confirmed, not ended, and quiet for 10 minutes while running or waiting on a question this app never got): asks QuBe Sync to send its latest event again, from the run status partial's "Check for updates" button. Behind your sign-in and CSRF, and `authorize_question`. |
| `POST qube/runs/:id/retry_start` | A start QuBe Sync never confirmed, or one refused as `realtime_required`, sent again with the same reference, from the run status partial. Behind your sign-in and CSRF, and `authorize_question`. |
| `GET qube/storyboard`, `GET qube/storyboard/:screen` | Every screen the partials show, from sample data, in your layout ([Styling](#styling)). Only while `config.storyboard` is true (404 otherwise); behind your sign-in. Its search (`GET qube/storyboard/:screen/search`) answers from the samples and its forms post to a no-op (`POST qube/storyboard/:screen/answer`): nothing reaches QuBe Sync or the database. |

The webhook routes verify the signature (401 if it doesn't check out), answer 404 when the row
isn't there, enqueue, and answer 200. No sign-in, no CSRF, the raw body, any content type, up to
5 MB. Each id in a URL is only a pointer: the job checks the signed event's reference and
connection id against the row (a request's event, its id).

Onboarding and the question routes inherit your `ApplicationController` (the `parent_controller`
setting), so its sign-in and CSRF protection apply. Your views reach the routes through the
engine's proxy: `qube_rails.connections_path`, `qube_rails.connection_onboarding_path(connection)`,
`qube_rails.connection_path(connection)` (with `method: :delete`).

Two buttons cover it: Connect, for an account setting up its first company file (or finishing a
setup it started), and, once it has one, Connect another company file:

```erb
<%= button_to "Connect QuickBooks Desktop", qube_rails.connections_path,
              form: { data: { turbo: false } } %>
<%= button_to "Connect another company file", qube_rails.connections_path,
              params: { new: 1, name: "Second file" }, form: { data: { turbo: false } } %>
<% if Rails.env.development? %>
  <%= button_to "Connect a simulated QuickBooks (for testing)", qube_rails.connections_path,
                params: { simulated: 1 } %>
<% end %>
```

Connect redirects to QuBe Sync's setup, on another site, so its forms need `data-turbo="false"`
in an app with Turbo (Rails 7 and later): Turbo submits a form with `fetch`, which the browser
won't follow to another origin, and the button would do nothing.

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
| `connection_type` | the type Connect makes connections as: `"realtime"` (workflows run only on these) or `"standard"` (for an app that only queues requests); anything else raises `ArgumentError`. Connect's `type` param overrides it per click. | `"realtime"` |
| `job_attempts` | how many times `QubeRails::WebhookJob` runs a delivery whose work raised, with a growing wait, before it logs an error and raises to your adapter (read when the job class loads) | `10` |
| `dedupe` | where each run's taken notification delivery ids are kept: `once(run, delivery_id) { }`, or `seen?(key)` / `remember(key)` | `QubeRails::DatabaseDedupe`: the engine's `qube_notifications` table, in the handler's transaction |
| `parent_controller` | the controller onboarding and the questions inherit | `"ApplicationController"` |
| `ui_classes` | your CSS classes for the engine's screens, by piece (`{ button: "btn btn-primary" }`), added beside the `qube-` classes ([Styling](#styling)); an unknown piece raises, naming them | `{}` |
| `storyboard` | whether `GET qube/storyboard` shows every screen with sample data | `Rails.env.development?` |
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

A notification (e.g. one page of a sync) is taken once per run by its `delivery_id`. By default the id
goes in `qube_notifications` inside the run row's lock and the same transaction as your
`notification` handler: a redelivery finds the row and is skipped, and a handler that raises rolls
its row back with its own writes, so the retry runs it again. `QubeRails::CacheDedupe` keeps the
ids in `Rails.cache` instead (`config.dedupe = QubeRails::CacheDedupe.new(Rails.cache, expires_in:
1.day)`); it needs a cache your workers share (Redis, Solid Cache), and it isn't transactional: a
crash between the handler's commit and the cache write runs the handler again.

## Background work

QuBe Sync's webhooks are handled in the background. The endpoint verifies a delivery, answers 200
at once, and hands the work to `QubeRails::WebhookJob`, an ActiveJob, so it runs on whatever queue
your app's ActiveJob uses (Sidekiq, Solid Queue, GoodJob...). Most apps change nothing here; set
`queue` to put it on a queue other than `:default`.

If your app's workers don't run ActiveJob (e.g. plain Sidekiq workers), set `enqueue` to hand the
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
so if the work fails later, your queue is the only thing that will run it again. The endpoint
answers 200 only once the enqueue has taken the delivery: when it returns `false` (ActiveJob 7.1+
does when the adapter couldn't enqueue) or raises, the endpoint answers 503, logged without the
body, and QuBe Sync sends it again.

`QubeRails.run` raises when it can't do the work (a handler of yours raised, the database is down,
the run's operation was taken out of `operations`, or a connection's event came before the
connection's id was saved: `QubeRails::NotReady`). `QubeRails::WebhookJob` retries it itself
(`retry_on`, with a growing wait), `job_attempts` times in all, since Solid Queue, GoodJob and
`:async` don't retry a job that raises. When the attempts run out it logs an error ("QuBe Sync:
gave up on a webhook ...") and raises, so your adapter sees the failure. With Sidekiq, its own
retries (25 by default) follow ActiveJob's, so a failing delivery is tried `job_attempts` times
and then Sidekiq's; set `job_attempts` to 1 to leave retrying to Sidekiq alone, or lower it. With
your own `enqueue`, your worker's retries are the only ones.

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
`stalled`), `stall_reason`, `revision` and `connection_type` (`realtime`, `standard` or
`simulated`). `QubeRails::Connection.owned_by(account)` lists an account's.

A connection's type can't be changed through the API: the customer upgrades a standard one to
realtime from its page in the QuBe Sync dashboard. Its next event carries the new type, and
`connection.refresh_type!` reads it at once (`GET /api/v2/connections/:id`).

Its own events (QUBE_WEBHOOK_URL/connections/<id>) update `status`, `stall_reason`, `connection_type` and `revision`
when the event is for that connection (`qube_id`) and newer than the last one applied, under the
row's lock. Then your class runs, with `connection` and `owner`.

An event can come before the row has its `qube_id`: a simulated connection sends
`connection.connected` as it's made, before `create_connection` has answered. Such an event finds
QuBe Sync's connection made with the row's webhook URL and keeps its id, or raises
`QubeRails::NotReady`, so the job tries again shortly. Connect does the same for a row left
without an id (a crash between the create and the save), so one row never gets two connections.

Adopting lists the app's connections (`GET /api/v2/connections`, which isn't paged) and takes
only the one with the row's webhook URL that has never connected (`last_connected_at` is null,
or it's simulated, since a simulated connection connects as it's made),
was made at or after the row (its `created_at`, with five minutes allowed for clock difference),
and has the row's name when the row has one; if two qualify it takes neither. A connection with no
`created_at` (from a server before it sent one) is never adopted, and that's logged.
So a row id used again (MySQL 5.7 after a restart, a restored database) never takes an old
connection. The unpaged listing is acceptable because it only runs for a row without an id,
which is rare: a lost create, or an event that beat the save.

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

Every ListID and TxnID your app learns is kept against its connection and its list family.
QuickBooks gives out ListIDs from one counter per family, so an id is unique only within its
family of one company file (verified on QuickBooks Enterprise 24.0): customers, vendors,
employees and other names share one, every item type shares another, each other list (accounts,
classes, terms...) has its own, and the same counter value turns up in several families.
TxnIDs are kept per transaction type.

```ruby
connection.link(customer, kind: "customer", qb_id: list_id, edit_sequence: "171", name: "Riverbend Electric")
connection.qb_id_for(customer, kind: "customer")       # => "80000001-1738310400", or nil
connection.find_linked(list_id, kind: "customer")      # => your Customer, or nil
connection.find_linked(entity_ref_list_id)             # any family; raises if the id is in several
connection.quickbooks_record(list_id, kind: "item")    # => the row, with kind, edit_sequence and name
```

A record has one id per kind on a connection; linking it again replaces it. One contact can be
linked as a customer and as a vendor (two QuickBooks names, two ids). An id already linked in
that family to another of your records moves to this one, and that's logged; linked again with
another kind of the same family (an item converted from service to non-inventory), the row's
kind changes. `qb_id_for` finds an item linked as `item_service` when asked for `item` or
`item_non_inventory`, but never hands out a customer's id as a vendor's.

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
          # Its ListID on this connection when it's linked, otherwise its name.
          customer_ref: quickbooks_ref(record.customer, kind: "customer", name: record.customer&.name),
          ref_number: record.number,
          invoice_line_add: record.lines.map { |line|
            { item_ref: quickbooks_ref(line.item, kind: "item", name: line.item&.name), amount: line.total&.to_f }
          }
        }
      })
    end

    # How the run ended: event.outcome says which, event.output holds the result. Keep the
    # QuickBooks ids it carries on the connection.
    def ended(event)
      # The records the add named, found or made, by the input's path: linked, so the next run
      # refers to them by id. A cancelled ending can carry some too.
      link_references(event) do |path, _entry|
        if path == "customer_ref"
          record.customer
        elsif (line = path[/\Ainvoice_line_add\.(\d+)\.item_ref\z/, 1])
          record.lines[line.to_i]&.item
        end
      end
      return unless event.outcome == "added"

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
`run_url` and `cancel_url`; and returns the row. The row keeps the input it sent.

A start can fail two ways, and they're handled differently:

- **Refused** (QuBe Sync answered 4xx: bad input, a workflow that isn't published) or an input that
  raised: nothing was started. The row is marked `failed` and the error raised; start again.
- **Not realtime**: workflows run on realtime connections (and simulated ones). On a row whose
  `connection_type` is `standard`, `start` raises `QubeRails::RealtimeRequired` before writing a
  run or calling QuBe Sync. When QuBe Sync refuses the start for it anyway (a `422` whose
  `errors.code` is `realtime_required`: the connection was downgraded in the dashboard), the row
  is kept as `realtime_required`, not `failed`, with `error` `{"code", "detail"}`, and
  `RealtimeRequired` is raised with the detail. QuBe Sync stores nothing for that refusal, the
  `Idempotency-Key` included, so once the customer upgrades the connection from its page in the
  QuBe Sync dashboard, `run.retry_start!` (or `start` again, which returns that run) starts it with
  the same reference.
- **No answer** (a timeout, a 5xx, a dropped connection): the run may have started. The row stays
  `starting`, with its reference and input, and the error is raised. Send it again with
  `run.retry_start!` (or `QuickbooksDesktop::CreateInvoice.retry_start(run)`), never with a new
  `start`: a new reference would start a second run, and a second invoice.

While the record's last run of the operation on that connection hasn't ended, `start` starts
nothing new: it returns that run (`run.reused?` is true), sending its start again first when
QuBe Sync hasn't confirmed it, with the same reference and the input it was started with. The
reference is the `Idempotency-Key`, so QuBe Sync answers a repeat with the run it already started,
and a double click never adds the invoice twice. A new reference is made only once the last run
has ended. The check and the new row (with its input) are made under the connection row's lock.

`retry_start!` resends the same reference as the `Idempotency-Key`, with the same workflow, input
and webhook URL. QuBe Sync keys a start by its app and that key, and fingerprints the call
(method, path, query and JSON body). The same key with the same call answers `201` with the run
the first call started, as it is now, plus `Idempotent-Replayed: true`, and starts nothing; the
same key with a different call is a `422`; a refused call (`400`, `403`, `404`, `422`) stores no
key, so retrying it runs the checks again. A key lives as long as its run: finished runs are
purged 60 days after they end. `retry_start!` returns a run that already has its `qube_run_id`
as it is, and refuses one that `failed`; one that's `realtime_required` it sends again, unless its
connection's row still says `standard` (it raises `RealtimeRequired` without calling QuBe Sync). (The gem's client also resends a start that got no
answer twice itself, within 60 seconds, with the same key.)

A `QubeRails::Run` keeps `operation`, `record`, `connection`, `reference`, `revision`, `state`,
`outcome`, `error`, `cancel_reason`, `ended_at`, and the open `question` and its `links`. Each event is applied under the run row's
lock: one whose reference isn't the run's, or whose `connection_id` isn't its connection's, is
skipped and logged; a notification is taken once; anything else only when its revision is newer
than the last applied. Handlers see `record`, `run` and `connection`. A handler you don't write
logs.

## Plain requests

A workflow is the default: it finds or makes the records an invoice names, checks QuickBooks
before resending after a lost answer, and asks your user when something needs a choice. Use a
plain request (one v2 operation, `QubeSync::Client#queue`) for a one-off query, or a write your
app settles itself: you handle each answer, error and lost answer.

```ruby
# app/services/quickbooks_desktop/find_customer.rb
module QuickbooksDesktop
  class FindCustomer < QubeRails::Request
    OPERATION = "customer.query" # a v2 operation id
    SLUG = "find_customer"

    def params
      { full_name: record.name }
    end

    # Each answered page: event.response_json["data"], event.page.
    def answered(event)
      found = Array(event.response_json["data"]).first
      connection.link(record, kind: "customer", qb_id: found["list_id"], name: found["full_name"]) if found
    end

    # Every page 1..N is in. Optional.
    def done; end

    # error or discarded: show event.error["user_message"].
    def failed(event); end

    # QuBe Sync keeps trying (QuickBooks closed, a dialog open). Never resend. Default: logs.
    def retrying(event); end

    # The answer never came back: QuickBooks may have applied it. Default: failed(event). A query
    # can be queued again; check a write before resending it.
    def timed_out(event); end
  end
end
```

List it in `config.operations` with your operations (`"find_customer" =>
"QuickbooksDesktop::FindCustomer"`), and queue it:

```ruby
row = QuickbooksDesktop::FindCustomer.queue(customer, connection) # a QubeRails::QueuedRequest
```

`queue` works as `start` does: under the connection row's lock, a request for the same record,
slug and connection that hasn't ended is returned (`row.reused?`) rather than queued again, sent
again first, with the same params and `Idempotency-Key`, when QuBe Sync never confirmed it (no
`qube_id`). A new request, with a new key, is made only once the last has ended. The key is the
row's `reference`, saved before the call. A refusal (a 4xx but 409) marks the row `failed` and
raises; a timeout, a 5xx or a 409 leaves it `queued` and raises: queue again, or call
`row.retry_queue!`. `params` that raise mark the row `failed` before anything is sent. `find_record`
works as an operation's.

The request's webhook URL is `QUBE_WEBHOOK_URL/requests/<row id>`. Each delivery is taken once,
by `page_request_id` and `state` (in `qube_request_deliveries`, written in the handler's
transaction), under the row's lock. An event whose `id` isn't the row's `qube_id` is skipped and
logged (request webhooks carry no connection id; before the queue's answer is saved, the first
event's `id` is kept). Pages can come in any order: `done` is called once, when every page from 1
to the one whose `iteration_state` is `done` is in (`not_applicable` is one page). A `retryable`
isn't final, and one that arrives after its page's answer is skipped.

A `QubeRails::QueuedRequest` keeps `operation`, `record`, `connection`, `reference`, `qube_id`,
`params`, `state` (`queued`, `retryable`, `response_received`, `error`, `timed_out`, `discarded`,
or `failed` for a refused queue), `error` (the webhook's), `pages_answered`, `last_page` and
`ended_at` (`ended?`, `done?`). It never keeps a response body: your handler stores what it needs.
A delivery whose handler raises rolls back with it, so the job's retry runs it again.

## Typed workflow starts

```sh
bin/rails g qube_rails:workflows            # app/qube/qube_workflows.rb and sig/qube_workflows.rbs
bin/rails g qube_rails:workflows --check    # in CI: exits 1 when the file is out of date
```

The generator fetches your app's workflow input types from QuBe Sync with `config.api_key` and
writes `QubeWorkflows` (autoloaded from `app/qube`): a module per workflow, with a start method
and an input method per branch of its input, whose operation bodies have the types and field docs
of the qube_sync gem's operation methods. Check both files in, and run it again when a workflow is
published. An operation's `input` can return the workflow's input method:

```ruby
def input
  QubeWorkflows::AddTransaction.invoice_input(without_nils({
    customer_ref: quickbooks_ref(record.customer, kind: "customer", name: record.customer&.name),
    ref_number: record.number
  }))
end
```

It's still a Hash (the method leaves out nil inputs); its RBS type is
`QubeWorkflows::AddTransaction::invoice_input`. Outside an operation,
`QubeWorkflows.add_transaction.invoice(connection, params, reference:, webhook_url:)` starts a
run on `QubeRails.client` directly (a `QubeRails::Connection` or its `qube_id`), without a run row.
QuBe Sync still checks every start: a field the operation doesn't take is a 422 naming it
(`{"path": "input.params", "message": "unknown parameter: \"customer_rf\""}`).

- `--drafts` types each workflow's draft where it has one; `--check` fetches with whatever the file
  was generated with.
- `--check` exits 1 when the served digest isn't the file's (naming the workflows that changed) or
  QuBe Sync refuses the key, and warns and exits 0 when QuBe Sync can't be reached or answers 5xx.
- It needs the qube_sync gem (Ruby 3.3): an app on the kit's inline backend can't run it.

## Run status

The engine keeps every ending on the run row before your handler runs, under the same lock:
`state`, `outcome`, a failure's `error` (as the event carried it: a sentence, or its code,
message and detail), a cancel's `cancel_reason`, and `ended_at`. So a run's result is there
whether or not your `ended` and `failed` handlers write anything; those are for your own records.
`run.ended?`, `run.failed?` and `run.cancelled?` say which (a run that completed on a
`cancelled` outcome, where your app chose to stop, counts as cancelled), and `run.summary_text`
says it in a sentence for your user: "Added to QuickBooks", "Done", "Couldn't sync",
"Cancelled", "Needs your answer", "Sending to QuickBooks", "Still waiting for QuickBooks"
or "Syncing with QuickBooks" (the words are I18n's: see [Wording and translations](#wording-and-translations)). `run.reason_text` says why it failed or was cancelled, as a sentence (the error's message, or
the reason your app gave), and nil otherwise.

A start refused as `realtime_required` reads QuBe Sync's detail (how to upgrade the connection)
as its summary, has sync status `:failed`, and gets the same "Try sending again" button, for once
the connection is upgraded.

A start QuBe Sync hasn't confirmed for a minute (`run.unconfirmed?`: still `starting`, after a
start that got no answer) reads "Still waiting for QuickBooks", and the partial offers a "Try
sending again" button. It posts to `POST qube/runs/:id/retry_start`, behind your sign-in and
CSRF, which runs the same `authorize_question` policy as the questions (404 otherwise), answers
409 for a run that isn't `starting` (or `realtime_required`), calls `run.retry_start!` (same reference, so a start that did
land answers with its run) and redirects back with 303.

Show the latest run's on the record's page:

```erb
<%= render "qube_rails/run_status", record: @invoice, operation: "create_invoice" %>
```

Its locals are `record` and `operation`. It shows the summary (`.qube-run-summary`, inside
`.qube-run-status.qube-run-<state>`) and, for a failure, the error's detail
(`.qube-run-error-detail`), and nothing for a record with no runs. Its pieces are
`qube_rails/run_status/*`: see [Styling](#styling) to restyle or replace any of them.

## Sync status

Where one of your records stands with QuickBooks, per connection and operation, worked out from
the engine's own rows (the record's runs in `qube_runs`, its link in `qube_quickbooks_records`)
and never stored, so your tables need no status column:

```ruby
status = connection.sync_status(invoice, operation: "create_invoice")
status.status       # :not_sent, :sending, :needs_answer, :in_quickbooks, :done, :failed or :cancelled
status.qb_id        # its QuickBooks id on this connection, when it's linked
status.error        # a failed run's error
status.retry?       # whether starting again makes sense (failed or cancelled, and not linked)
status.unconfirmed? # a start QuBe Sync hasn't confirmed: run.retry_start!
status.summary_text # "In QuickBooks", "Needs your answer", "Couldn't sync"
status.run&.reason_text # why it failed or was cancelled, as a sentence, or nil
```

Per connection, since an invoice can be in one company file and not another.
`QubeRails::SyncStatus.latest(record, operation:)` reads it on the connection the latest run went
out on, for a page that doesn't say which.

When the run and the link disagree, the newest word wins:
1. a latest run that hasn't ended: `:sending` (an unconfirmed start too) or `:needs_answer`; a
   start refused as `realtime_required` is `:failed`;
2. a latest run that failed or was cancelled after the link was made, or with no link:
   `:failed` or `:cancelled`;
3. a link: `:in_quickbooks`, always with its `qb_id`;
4. a latest run that completed and linked nothing (an operation that doesn't link its record):
   `:done`, which a new start may follow;
5. otherwise `:not_sent`.

For list pages and filters, the connection has scopes over a model or relation of yours, one query
each (an `EXISTS` on the engine's indexes, by your primary key as text):

```ruby
connection.not_in_quickbooks(account.invoices)
connection.in_quickbooks(Invoice)
connection.needing_answer(Invoice, operation: "create_invoice")
connection.sending(Invoice, operation: "create_invoice")
```

The `qube_rails/run_status` partial shows it (`data-qube-sync-status`, `qube-sync-<status>`),
with `connection:` when the page is about one company file.

## The page updates itself

When a run's event changes it (a question, an ending), the engine tells the record's pages to
refresh, in an app with turbo-rails 2 (Turbo 8) and Action Cable: the partials subscribe with
`turbo_stream_from(record, :qube_rails)`, and the job calls `Turbo::StreamsChannel.broadcast_refresh_to`,
then once more 5 seconds later (`QubeRails::RefreshJob`, on `config.queue`), for a page that was
still loading the first time (the redirect after a start, when the question comes at once).
Without turbo-rails, nothing is sent, and a reload shows it.

A run QuBe Sync confirmed that has had no news for 10 minutes, running or waiting on a question
this app never received, may have lost a webhook (the app was down longer than QuBe Sync's
retries). The partial then offers "Check for updates", which asks QuBe Sync to send the
run's latest event again (`client.redeliver_run`); it comes back through the webhook route, and
one already applied is skipped by its revision.

While the connection a record waits on is stalled (`connection.stalled`, kept on the row as
`status` and `stall_reason`), a status waiting on QuickBooks (`:sending`) reads "Waiting for
QuickBooks" with a warning dot, says why and what to do (`qube_rails/run_status/_stall`: the Web
Connector isn't checking in, or it can't open QuickBooks), and offers no "Check for updates": the
cause is known. A question waiting on your user isn't affected. When the connection stalls or
resumes, the engine tells the pages of the records with a run still going on it to refresh (by the
runs' connection index, at most 200), so the status changes without a reload.

An answer or a start retry that can't go through (the question changed, QuBe Sync refused the
answer's data, the start was confirmed meanwhile) goes back to the page with the reason in
`flash[:qube_rails_error]`, which the partials show once, so it shows under Turbo too.

## Questions

When a run asks your user something, `Operation#question` keeps it on the run. Show it on the
record's page:

```erb
<%= render "qube_rails/question", record: @invoice, operation: "create_invoice" %>
```

Its locals are `record` and `operation` (the slug). It shows the open question of that record's
latest run of that operation, and nothing when that run isn't asking. Each choice is a form
posting to the run's question route with your CSRF token, and a record field's box searches
through your app, so the API key never reaches the browser. Its search boxes and rows fields need
the behaviour script (`qube_rails_assets` in your layout). Its pieces are `qube_rails/question/*`:
see [Styling](#styling) to restyle or replace any of them.

A rows field (`add_transaction`'s one question for every record QuickBooks doesn't have) shows as a
block per record, never a table and never scrolling sideways: the record's name, its choice (an enum
column of up to three options, such as create or use, as a segmented control), then only the fields
its answers so far call for (each column shown while its `when` holds), stacked in a grid, a search
per record column (sent with the row). "Set all to:" sets that choice on every record, and "Use for
all N" under a filled search or select copies it to the other records that ask it and are still
empty. Its answer is `{"records": {row key => {column => value}}}`.

An answer QuBe Sync can't take (422) shows its reason; one it says has changed (409, or any 400)
goes back to the page with a message; the run's next webhook says what came of it.

## Styling

The partials render plain, semantic HTML with `qube-` classes. Make them match your app three ways,
from least to most work; [the storyboard](#the-storyboard) shows every screen at once while you do.

### 1. The stylesheet and its variables

```erb
<%# app/views/layouts/application.html.erb, in <head> %>
<%= qube_rails_assets stylesheet: true %>
```

`qube_rails_assets` writes the behaviour script's tag (`qube_rails/question.js`, deferred, with
your CSP nonce when you have one) and, with `stylesheet: true`, the opt-in stylesheet's
(`qube_rails.css`). Your asset pipeline serves both: Propshaft as it is, Sprockets through the
engine's precompile list. Without `stylesheet: true` nothing of ours styles your page.

Every rule in `qube_rails.css` is inside `:where()`, so it has no specificity and any rule of
yours wins. It has no reset and no global styles. Theme it with CSS variables on `:root` or any
element around the screens:

```css
:root {
  --qube-accent: #4f46e5;      /* the primary button, focus rings, highlights; default: a calm blue */
  --qube-accent-text: #fff;    /* text on the accent */
  --qube-border: #e5e7eb;      /* hairlines; default: the text colour, faded */
  --qube-control-border: #d1d5db; /* inputs and secondary buttons */
  --qube-radius: 8px;          /* cards; controls take 2px less */
  --qube-gap: 16px;
  --qube-font: inherit;        /* default: the system font stack */
  --qube-font-size: 0.875rem;
  --qube-muted: #6b7280;
  --qube-error: #c2410c;
  --qube-success: #15803d;     /* the status dot once it's in QuickBooks */
  --qube-warning: #d97706;     /* the status dot while it needs an answer or waits on a stalled connection */
  --qube-surface: #fff;        /* cards, inputs, the matches; default: Canvas */
  --qube-max-width: 52rem;     /* the question card */
}
```

Light and dark follow your page's `color-scheme`: with `color-scheme: light dark` (or `dark`) on your
page, the accent and status colours take their dark-mode shades and the surfaces follow `Canvas`,
so `prefers-color-scheme` carries through. An app whose dark mode is a class should set
`color-scheme: dark` with it, or set the variables there.

Motion is short and only where it says something: a button gives way on press (`scale(0.97)`),
the search box's matches drop in from the input (150ms; they close at once, and moving through them
with the keyboard is instant), a rows field's field fades in as it starts to apply, what "Set all to"
or "Use for all" fills flashes a tint, and a one-shot error fades in. All of it is transform and
opacity, on `cubic-bezier(0.23, 1, 0.32, 1)`; with `prefers-reduced-motion: reduce` the fades stay
and the movement goes. Hover effects apply only on devices with a fine pointer.

### 2. Class hooks

`config.ui_classes` adds your CSS framework's classes beside the `qube-` ones, by piece:

```ruby
# Bootstrap
config.ui_classes = {
  button: "btn btn-primary", button_secondary: "btn btn-outline-secondary", input: "form-control",
  select: "form-select", checkbox: "form-check-input", label: "form-label",
  error: "alert alert-danger", status: "alert alert-light", search_result: "list-group-item list-group-item-action"
}
# Tailwind
config.ui_classes = { button: "rounded bg-indigo-600 px-3 py-1.5 text-white", input: "rounded border-gray-300" }
```

| Piece | Where |
| --- | --- |
| `question` | the question's `<section>` |
| `message`, `details` | its sentence, its label/value table |
| `choice` | each choice's `<form>` |
| `button`, `button_secondary`, `button_ghost` | the one primary button (a form choice's submit, or a plain question's first choice; the retry button), the secondary ones (other exits, later forms, redeliver, Apply), and cancel (`button_ghost`, else `button_secondary`) |
| `picks`, `pick`, `pick_detail`, `pick_action` | the picks' list, each pick's option-row button (never `button`), its detail, its "Use this one" |
| `choice_footer`, `choice_divider` | the exits' row; the "or" between picks and a form |
| `choice_detail`, `choice_description` | a choice's detail (in its button) and description |
| `field`, `label` | a field's wrapper and its label (and the rows field's) |
| `input`, `select`, `checkbox` | text, number and search inputs; selects; checkboxes |
| `search`, `search_results`, `search_result` | a search box's wrapper, its matches' container, each match (made by the script) |
| `rows`, `row`, `row_header`, `row_fields` | a rows field's list of records, each record, its name, its fields' grid |
| `segmented`, `segment` | a record's choice as a segmented control, each option |
| `use_for_all` | the "Use for all N" button under a field |
| `status`, `summary`, `detail` | the run status, its sentence, a failure's detail |
| `stall` | why it waits on a stalled connection |
| `error` | a one-shot error |

Values are a String or an Array. An unknown piece raises when the initializer runs, naming these.

### 3. Overriding a piece

Each piece is a small partial. Put a file at the same path in your app and Rails renders yours;
everything else stays the engine's. The entry points `render "qube_rails/question", record:,
operation:` and `render "qube_rails/run_status", record:, operation:` don't change.

| Partial | Local | Renders |
| --- | --- | --- |
| `qube_rails/question/_question` | `question` | the section: error, message, details, choices |
| `qube_rails/question/_message`, `_details` | `question` | the sentence; the label/value rows |
| `qube_rails/question/_picks`, `_pick` | `question`; `question`, `choice` | the picks' list; one pick, a form posting `choice` |
| `qube_rails/question/_choice` | `question`, `choice` | a form or exit choice: a form posting `choice` and `data[...]` with your CSRF token |
| `qube_rails/question/_footer` | `question` | the exits' row |
| `qube_rails/question/_field` | `field`, `control` | a field's wrapper and label around its control (HTML) |
| `qube_rails/question/fields/_text`, `_number`, `_boolean`, `_select`, `_search`, `_rows` | `field` | one field, by `field.type` |
| `qube_rails/question/rows/_row` | `rows`, `row` | one record: its name, its choice, its fields |
| `qube_rails/question/rows/_cell` | `cell` | one field of a record (shown while its `when` holds), or what it already has |
| `qube_rails/question/rows/_segmented` | `field` | a short enum as a segmented control (radios posted as `field.input_name`) |
| `qube_rails/run_status/_status` | `run_status` | the error, then the status: summary, detail, buttons |
| `qube_rails/run_status/_summary`, `_detail`, `_stall`, `_retry`, `_redeliver` | `run_status` | each part (`_stall` while its connection is stalled) |
| `qube_rails/_error` | `message` (optional) | a one-shot error; without `message:`, `flash[:qube_rails_error]` |

The locals are view-models, plain Ruby objects. Their fields are the contract, kept stable across
versions:

- `QubeRails::QuestionView`: `picks`, `forms`, `exits`, `plain?` (see "Choices" below), `message`, `details` (each `label`, `value`), `choices`, `token`,
  `action_url`, `search_url`, `error` (QuBe Sync's refusal, or nil), `prompt` (as QuBe Sync sent it).
- `QubeRails::ChoiceView`: `id`, `label`, `detail`, `description`, `fields`, `index`, `action_url`,
  `secondary?` (cancel), `kind` (`:pick`, `:form` or `:exit`), `style` (its button's: `:primary`,
  `:secondary`, `:ghost`, or nil for a pick) and `button_piece` (its `ui_classes` piece).
- `QubeRails::FieldView`: `name`, `input_name` (post your value under it), `dom_id`, `type` (`text`,
  `number`, `boolean`, `select`, `search` or `rows`), `label`, `required`, `options` (a select's,
  each `value` and `label`), `kind` (a search's record kind), `search_url`, `search_field`, `row_key`,
  `when`, `rows` (a `RowsView`), `disabled`, `partial`, and `labelled?`, `cell?` (a rows field's) and
  `segmented?` (a cell's enum of up to three options).
- `QubeRails::RowsView`: `name`, `label`, `input_name`, `search_url`, `columns` (FieldViews), `rows`,
  `set_all` (the column "Set all to:" sets, or nil).
  `QubeRails::RowView`: `key`, `label`, `detail`, `values`, `values_json`, `index`, `cells` (the
  columns it asks or already has a value for), `segmented_cells`, `field_cells`.
  `QubeRails::CellView`: `column`, `label`, `field` (nil for a value the row already has), `preset`
  (that value, read-only), `when`, `when_json`, `hidden?`, `required` (the column's; a hidden field
  isn't required until shown), `segmented?`.
- `QubeRails::RunStatusView`: `status` (`:not_sent`, `:sending`, `:needs_answer`, `:in_quickbooks`,
  `:done`, `:failed`, `:cancelled`), `state` (the run's), `summary` (a few words, for the pill), `reason` (why it failed or was cancelled, a sentence), `detail`, `quiet_text`,
  `retry_url` and `redeliver_url` (nil when the button doesn't apply; post to them), `error`,
  `stall` (the stalled connection's reason as a Symbol, such as `:not_checking_in` or
  `:quickbooks_unavailable`, while a `:sending` status waits on it; else nil), `stall_text`,
  `visible?`, `css_class` (with `qube-connection-stalled` then; the element also gets
  `data-qube-stall="<reason>"`). `RunStatusView.from_sync(sync, urls, error:, connection:)` takes the
  connection the page is about (the partial's `connection:` local), else the latest run's.

Choices show by kind. A pick (an item of a `choose` list: an id ending `:<n>`, no fields) is a quiet
option row; with no picks, a plain choice before the first form is one too (a name clash's "Use the
existing record"). Each form choice (one with fields) is its own section, "or" between it and what
comes before (`question.or`), its field's label leading and its submit the one filled button (only
the first form's; later ones are secondary). The exits (none of these, cancel) sit in a row under a
hairline, cancel as a ghost. A question with neither picks nor forms keeps its choices in one row,
the first primary. So a screen never has more than one filled button. The form gets
`data-qube-choice-kind`, the button `data-qube-button` (its style).

A field override posts its value as `field.input_name`, so the controller reads it as it reads
ours: a checkbox `"true"`, a number as typed, a rows cell `data[<field>][<row key>][<column>]`.

### The behaviour script

`qube_rails/question.js` has one set of listeners on `document`, keyed only on `data-qube-*`
attributes. It works on any markup that carries them, after Turbo navigation too, needs no build and
no CSP nonce (it's a file, not an inline script), and loads once however often it's included.

- A search: an element with `data-qube-search="<search URL>"`, `data-qube-field="<field>"` and, in a
  rows table, `data-qube-row="<row key>"`, holding a text input `data-qube-search-input`, a hidden
  input `data-qube-search-value` (the one with the name, which gets the picked `value`) and a
  container `data-qube-search-results`. Typing two characters or more asks the search URL; each
  match is a button (classes from `data-qube-result-class`, `role="option"`); picking one (a click,
  or the arrow keys and Enter) fills the hidden input and fires `change` on it and `qube:picked` on
  the box. Escape, a click outside or leaving the box closes the matches. The box gets
  `data-qube-open` while they show, and the input `aria-expanded` and `aria-activedescendant`. Until a
  match is picked, the text input is invalid, so the form isn't sent. Its words come from the box's
  `data-qube-text-no-matches`, `-searching`, `-search-failed` and `-pick-a-match` (English without).
- A rows field: `data-qube-rows` around it; each record `data-qube-row` with `data-qube-values` (JSON);
  each field `data-qube-col="<column>"` with `data-qube-when` (JSON) and, for a required column,
  `data-qube-required`; each input `data-qube-rows-input` (a radio counts when checked). A field
  whose `when` doesn't hold is `hidden` (and `data-qube-hidden`), its inputs disabled and not
  required, so it's neither sent nor asked for; the script toggles all three as answers change. Optional:
  `data-qube-rows-set-all="<column>"` holding buttons `data-qube-set-all="<value>"` (sets that column on
  every record offering the value), and a button `data-qube-use-for-all` in a field (shown, with the
  table's `data-qube-text-use-for-all`, "Use for all %{count}", while the field has a value other
  records' shown fields lack; copies it to them). What either fills gets `data-qube-filled` for the
  stylesheet's tint.
- A form choice (`data-qube-choice-kind="form"`) whose required fields are all searches: its submit
  is disabled until each has a pick, and again if the text is edited after (by the script only, so it
  still posts without it).
- The storyboard: a button `data-qube-copy="<text>"` copies its text.

#### A custom combobox

Your own component can skip the script: it needs only the search route and the hidden input.

```
GET <question action>/search?field=<field>&q=<2 to 100 characters>[&row=<row key>]
  → 200 [{"value": "80000001-1700000000", "label": "Riverbend Electric", "detail": "Customer"}, ...]
```

At most 20 matches, behind your sign-in; the question's action is `question.action_url`
(`field.search_url` is the whole URL). Post the picked `value` under `field.input_name`:

```erb
<%# app/views/qube_rails/question/fields/_search.html.erb %>
<div class="field">
  <%= label_tag field.dom_id, field.label %>
  <%= render "shared/combobox", id: field.dom_id, name: field.input_name, required: field.required,
             url: field.search_url, params: { field: field.search_field, row: field.row_key }.compact %>
</div>
```

where `shared/combobox` is your component, sending `q` with those params and submitting the
chosen `value` in a hidden input named `name`.

### The storyboard

`GET /qube/storyboard` shows every screen your users can meet, from sample data, in your own
layout, so your CSS and `ui_classes` apply: the run status (not sent, starting, an unconfirmed start
with its retry button, running, waiting on a stalled connection (QuickBooks not checking in, or
closed), waiting for an answer, looking stuck with its redeliver button, in
QuickBooks, done, failed with its detail, cancelled), the one-shot error, and a question of each
kind (a near match, a record search, a pick from a list, a fixed list, number and yes/no fields, a
name clash, a lost answer, a missing customer, records not in QuickBooks yet, and a refused answer). Each screen is a section with
the screen on a flat canvas, with a note and its "Override files" (the partials to override for it, each with a
Copy button); the canvas can be shown as your page is, light or dark. The list of screens links to
each one. `GET /qube/storyboard/<screen>` shows one.

It's on while `config.storyboard` is true (by default, in development), behind your sign-in. It
calls nothing: its searches answer from the samples (`lib/qube_rails/storyboard/*.json`, prompts
shaped as QuBe Sync sends them), its forms post to a no-op that comes back with "Storyboard:
nothing was sent.", and no row is written.

## Wording and translations

Everything the screens say to your users comes from I18n, under `qube_rails.*`, with the engine's
English in its `config/locales/en.yml`. Nothing names QuBe Sync: to your users it's QuickBooks. To
reword a string, set its key in your own locale file (yours load after the engine's); to translate
them, add your locale's keys. A key your locale lacks falls back to the engine's English.

```yaml
# config/locales/qube_rails.en.yml
en:
  qube_rails:
    status:
      running: "Syncing with your accounts"
    errors:
      unreachable: "Couldn't reach the accounting sync just now. Try again in a minute."
```

| Key | English | Where |
| --- | --- | --- |
| `status.in_quickbooks` | In QuickBooks | the status, linked |
| `status.added` | Added to QuickBooks | the status, an add that completed |
| `status.done`, `status.done_with` | Done; Done: %{outcome} | the status, completed |
| `status.failed` | Couldn't sync | the status, failed (why is `reason_text`, below it) |
| `status.realtime_required` | This company file's connection needs an upgrade to realtime before this can sync. | the status, a start refused as `realtime_required` that carried no detail |
| `status.not_started` | it couldn't be sent | a failure's message for a start that never went out |
| `status.cancelled` | Cancelled | the status, cancelled (the reason, if any, below it) |
| `status.cancel_reason` | it was stopped before it finished | `Run#cancel_reason_text` with no reason |
| `status.needs_answer` | Needs your answer | the status, asking a question |
| `status.starting` | Sending to QuickBooks | the status, just started |
| `status.unconfirmed` | Still waiting for QuickBooks | the status, a start unconfirmed for a minute |
| `status.running` | Syncing with QuickBooks | the status, running |
| `status.quiet` | No update from QuickBooks for a while. | above the redeliver button |
| `status.check_for_updates` | Check for updates | the redeliver button |
| `status.try_again` | Try sending again | the retry button |
| `status.waiting_for_quickbooks` | Waiting for QuickBooks | the status while its connection is stalled |
| `status.stalled.not_checking_in` | QuickBooks hasn't checked in for a while, so this is waiting. Make sure the computer with QuickBooks is on and the Web Connector is running. | why, when the Web Connector isn't calling in |
| `status.stalled.quickbooks_unavailable` | The Web Connector is checking in but can't open QuickBooks. Open the company file in QuickBooks on that computer. | why, when QuickBooks is closed |
| `status.stalled.other` | Syncing with QuickBooks has stopped for now. Check the computer with QuickBooks and its Web Connector. | any other stall reason |
| `errors.not_starting` | This was already sent, so there's nothing to try again. | a retry of a start that isn't waiting |
| `errors.not_quiet` | This was updated recently. Check again in a few minutes. | a redeliver of a run that isn't quiet |
| `errors.no_update_yet` | There's no update yet. Check again in a few minutes. | a redeliver with nothing to send (409) |
| `errors.checked_just_now` | That was checked a moment ago. Try again in a minute. | a redeliver asked too soon (429) |
| `errors.unreachable` | Couldn't reach QuickBooks' sync service just now. Try again in a minute. | a redeliver QuBe Sync didn't answer |
| `errors.disconnect_unreachable` | Couldn't reach QuickBooks' sync service just now. Try disconnecting again in a minute. | a disconnect QuBe Sync didn't answer |
| `errors.still_syncing` | Something is still syncing with this company file. Let it finish, or answer its question, then disconnect. | a disconnect while work is going |
| `errors.question_changed` | This question changed after the page loaded, so your answer wasn't sent. The page now shows the latest. | an answer to a changed question |
| `errors.answer_refused`, `errors.answer_refused_with` | That answer couldn't be used. Check it and try again.; That answer couldn't be used: %{detail} | an answer QuBe Sync refused (422) |
| `question.set_all` | Set all to: | before a rows field's buttons that set every record's choice (each an option's own label) |
| `question.use_for_all` | Use for all %{count} | under a filled field other records ask too |
| `question.or` | or | between picks and a form choice |
| `question.use_pick` | Use this one | at the end of each pick's row: what clicking it does |
| `question.pick_a_match` | Pick one of the matches. | a search box with text but no pick, on submit |
| `question.no_matches`, `question.searching`, `question.search_failed` | No matches; Searching…; Search isn't available right now. Try again in a moment. | the search box's matches |

`QubeRails.t(key, **options)` looks one up as the engine does. A question's own words (its message,
details, choices and field labels) are QuBe Sync's prompt, in English. The route constants
(`RunsController::NOT_QUIET` and the rest) are these keys, as Symbols.

## Storage

Rows go with their run: deleting a run deletes its notifications, and deleting a plain request
its deliveries. Disconnecting a connection deletes its runs and requests. Runs are kept until you say
otherwise. To prune ended ones, set `config.prune_runs_after = 90.days` and schedule
`QubeRails::PruneRunsJob` (Solid Queue's `config/recurring.yml`, say):

```yaml
prune_qube_runs:
  class: QubeRails::PruneRunsJob
  schedule: every day at 4am
```

It deletes only ended runs (`Run.prunable`) and ended plain requests (`QueuedRequest.prunable`,
with their deliveries), never within a day of their end: a webhook for a
deleted run answers 404, which QuBe Sync retries for hours. What a record's page shows stays
right: `in_quickbooks` comes from `qube_quickbooks_records`, which are never pruned, and a sync's
next `since` from `qube_sync_marks` (`connection.last_synced_at(workflow)`, or
`last_synced_at` in an operation), which a completed run moves forward. A pruned run's record
whose run had failed, or completed without a link, shows `not_sent` again.


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
DB=postgres DATABASE_URL=postgres://... bundle exec rspec   # or DB=mysql: the scopes' SQL there
bin/syntax-check-2.7                     # every shipped file parses on Ruby 2.7
```

Until qube_sync 0.5.0 is published, the Gemfile takes it from `../wt-qube_sync_rb` (or
`QUBE_SYNC_PATH`) when that checkout is there.

The source is kept Ruby 2.7 and Rails 5.2 compatible, and every call to qube_sync goes through
`QubeRails::Backend`, so QuBe Sync's kit can vendor the same files, with an inline backend, into
an app below the gem's Ruby 3.3 floor.

## License

MIT
