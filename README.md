# qube_rails

QuBe Sync's Rails engine, for QuickBooks Desktop through [qubesync.com](https://qubesync.com). It
holds the part of an integration that's the same in every Rails app:

- the webhook endpoint (verify the signature, check the slug, enqueue) and its job (parse, find
  the record, handle);
- onboarding: create or reuse the customer's connection, bring its webhook URL up to date, and
  send them to QuBe Sync's setup;
- the question routes (answer by choice, search a record field) and the question partial;
- `QubeRails::Operation` and `QubeRails::ConnectionEvents`, the bases of your classes, with the
  reference, revision and delivery-id checks, under the record's row lock.

Your app keeps its own code, which this gem never names: one initializer, an operation class per
way it starts a workflow, and a connection class. Update the engine with `bundle update
qube_rails`; your files stay as you wrote them.

Needs Ruby 3.3 or later and Rails 7.0 or later, and the [qube_sync](https://rubygems.org/gems/qube_sync)
gem 0.4.0 or later, which it installs.

## Install

```ruby
# Gemfile
gem "qube_rails", ">= 0.2.0"
```

```sh
bundle install
bin/rails g qube_rails:install            # or: bin/rails g qube_rails:install organizations
bin/rails db:migrate
```

The generator writes:

- `config/initializers/qube_rails.rb`, every setting, commented;
- `app/services/quickbooks_desktop/connection.rb`, your connection class;
- a migration adding `qube_connection_id` (string) and `qube_connection_revision` (integer) to
  the table it's given (`accounts` unless you name another);
- `mount QubeRails::Engine => "/"` in `config/routes.rb`.

Fill in `authorize_question` and `current_account` in the initializer before anything else: until
`authorize_question` is set, every answer and search is refused.

## Routes

Relative to where the engine is mounted (`"/"` above):

| Route | What it does |
| --- | --- |
| `POST quickbooks/connect` | Onboarding, from a "Connect QuickBooks Desktop" button. Behind your sign-in. Redirects (303) to QuBe Sync's setup. |
| `POST webhooks/qube/:operation/:record_id` | QuBe Sync's webhooks. Verifies the signature (401 if it doesn't check out), 404 for a slug none of your operations has, enqueues, 200. No sign-in, no CSRF, the raw body, any content type, up to 5 MB. |
| `POST qube/questions/:operation/:record_id` | Your user's answer to a run's question, from the partial. Behind your sign-in and CSRF. |
| `GET qube/questions/:operation/:record_id/search` | A record field's matches, as JSON. Behind your sign-in. |

`connection` is the connection's own slug (`webhooks/qube/connection/<account id>`), not an
operation's. Your views reach the routes through the engine's proxy: `qube_rails.connect_path`.

Onboarding and the question routes inherit your `ApplicationController` (the `parent_controller`
setting), so its sign-in and CSRF protection apply. The webhook endpoint is an
`ActionController::API` controller.

## Settings

In `config/initializers/qube_rails.rb`, the only place the engine reads your app from:

```ruby
QubeRails.configure do |config|
  config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
  config.connection = "QuickbooksDesktop::Connection"
  config.current_account = ->(controller) { controller.current_user.account }
  config.authorize_question = ->(controller, record, operation) {
    record.account_id == controller.current_user.account_id
  }
end
```

| Setting | What it is | Default |
| --- | --- | --- |
| `operations` | slug => operation class *name* (resolved when used, so code reloading works) | none: raises |
| `connection` | the connection class's name | none: raises |
| `current_account` | `->(controller) { account }`: the signed-in customer's account. nil answers 401. | none: raises |
| `authorize_question` | `->(controller, record, operation) { true }` when the signed-in user may answer or search that record's question. Only `true` allows. | none: refuses every answer and search, and logs why |
| `enqueue` | `->(delivery) { ... }`, handing `{ operation:, record_id:, body: }` to a queue | ActiveJob: `QubeRails::WebhookJob` on `queue` |
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

The default dedupe store is `Rails.cache`: make that a store your workers share (Redis, Solid
Cache), or a retry that reaches another worker isn't caught.

With another queue, hand the delivery on and run it from your worker:

```ruby
config.enqueue = ->(delivery) {
  QubeDeliveryWorker.perform_async(delivery[:operation], delivery[:record_id], delivery[:body])
}

# in QubeDeliveryWorker#perform(operation, record_id, body):
QubeRails.run(operation, record_id, body)
```

QuBe Sync had its 2xx when the delivery was enqueued, so a job that raises is your queue's to
retry. `QubeRails.run` raises `QubeRails::RecordMissing` when `find_record` returns nil, so the
queue retries it.

## Environment

| Variable | What it is |
| --- | --- |
| `QUBE_API_KEY` | your app's API key; `qube env --write .env` writes it |
| `QUBE_WEBHOOK_SECRET` | your app's webhook secret; `qube env --write .env` writes it |
| `QUBE_URL` | `https://qubesync.com` unless you're told otherwise |
| `QUBE_WEBHOOK_URL` | the base of each run's and each connection's webhook URL: `qube listen --write-env .env` writes it in development, and in production it's your app's `/webhooks/qube` |

## Your connection class

```ruby
module QuickbooksDesktop
  class Connection < QubeRails::ConnectionEvents
    def self.find_record(id)
      Account.find(id)
    end

    # QuickBooks is connected: mark the account connected, and start syncing.
    def connected(event)
      account.update!(quickbooks_status: "connected")
    end

    # They chose "Cancel setup": offer Connect QuickBooks Desktop again.
    def setup_cancelled(event)
      account.update!(quickbooks_status: nil)
    end

    # "not_checking_in" or "quickbooks_unavailable": show the newest.
    def stalled(event)
      account.update!(quickbooks_stall: event.stall_reason)
    end

    def resumed(event)
      account.update!(quickbooks_stall: nil)
    end
  end
end
```

Onboarding keeps the connection's id on the account (`save_connection_id`, which also forgets the
last connection's revision), and every run starts on it:
`QuickbooksDesktop::Connection.new(account).saved_connection_id`. The engine applies a connection
event only when it's for the connection saved on that account, and newer than the last one
applied. Override `saved_connection_id`, `save_connection_id`, `saved_revision` and
`save_revision` to keep them somewhere other than `qube_connection_id` and
`qube_connection_revision`.

## Writing an operation

One class per way your app starts a workflow, listed in `config.operations` by its `SLUG`:

```ruby
# app/services/quickbooks_desktop/create_invoice.rb
module QuickbooksDesktop
  class CreateInvoice < QubeRails::Operation
    WORKFLOW = "add_transaction"
    SLUG = "create_invoice"

    # Your record, by the id in its webhook URL.
    def self.find_record(id)
      Invoice.includes(lines: :item).find(id)
    end

    # The run's input, from the record. without_nils leaves out a field your record doesn't have
    # yet rather than sending it as null.
    def input
      without_nils({
        operation: "invoice.create",
        params: {
          customer_ref: { full_name: record.customer&.name },
          ref_number: record.number,
          invoice_line_add: record.lines.map { |line|
            { item_ref: { full_name: line.item&.name }, amount: line.total&.to_f }
          }
        }
      })
    end

    # How the run ended: event.outcome says which, event.output holds the result.
    def ended(event)
      record.update!(status: "sent", txn_id: event.dig("output", "record", "txn_id"))
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
connection_id = QuickbooksDesktop::Connection.new(account).saved_connection_id
QuickbooksDesktop::CreateInvoice.start(invoice, connection_id)
```

`start` saves a new reference on the record before the run starts (a webhook can come before it
returns) and sends it as the idempotency key. The record keeps it, and the run's state, in four
columns:

```ruby
add_column :invoices, :qube_reference, :string
add_column :invoices, :qube_revision, :integer
add_column :invoices, :qube_question, :json   # only when the workflow asks questions
add_column :invoices, :qube_links, :json      # likewise
```

Each event is applied under the record's row lock: one whose reference isn't the record's is
skipped and logged, a notification is taken once, and anything else only when its revision is
newer than the last applied. A handler you don't write logs.

## Questions

When a run asks your user something, `Operation#question` saves it on the record. Show it on the
record's page:

```erb
<%= render "qube_rails/question", record: @invoice, operation: "create_invoice" %>
```

Its locals are `record` and `operation` (the slug). It renders nothing when the run isn't asking.
Each choice is a form posting to the engine's question route with your CSRF token, and a record
field's box searches through your app, so the API key never reaches the browser. Style it with
its `qube-` classes, or copy the partial to `app/views/qube_rails/_question.html.erb` in your app
for other markup: Rails renders yours instead.

An answer QuBe Sync can't take (422) shows its reason; one it says has changed (409, or any 400)
forgets the question and answers 409; the run's next webhook says what came of it.

## Upgrading

From the integration kit's generated code: keep your operation classes (now
`QuickbooksDesktop::... < QubeRails::Operation`), move `account_id`, `authorize_question!` and
`QubeWebhookJob::OPERATIONS` into the initializer (`current_account`, `authorize_question`,
`operations`), move `ConnectionEvents`' handlers into your connection class, and delete the
generated controllers, job, partial, `QubeSync` module and routes in favour of the mount line.

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
