# frozen_string_literal: true

QubeRails::Engine.routes.draw do
  # A "Connect QuickBooks Desktop" button posts here (with an optional name), for a new
  # connection; a connection's "Set up again" posts to its onboarding. QuBe Sync's setup doesn't
  # come back to your app: it tells the connection by webhook.
  post "quickbooks/connections", to: "connections#create", as: :connections
  post "quickbooks/connections/:id/onboarding", to: "connections#onboarding", as: :connection_onboarding

  # Each run's webhook URL is QUBE_WEBHOOK_URL/runs/<run id> (QubeRails::Run#webhook_url), and a
  # connection's is QUBE_WEBHOOK_URL/connections/<connection id>.
  post "webhooks/qube/runs/:id", to: "webhooks#run_event", as: :run_webhook
  post "webhooks/qube/connections/:id", to: "webhooks#connection_event", as: :connection_webhook

  # A start QuBe Sync never confirmed, sent again, from the run status partial.
  post "qube/runs/:id/retry_start", to: "runs#retry_start", as: :retry_start

  # Your user's answer to a run's question, from the question partial, and a record field's
  # search.
  post "qube/questions/runs/:id", to: "questions#create", as: :question
  get "qube/questions/runs/:id/search", to: "questions#search", as: :question_search
end
