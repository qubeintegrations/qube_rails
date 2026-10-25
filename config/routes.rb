# frozen_string_literal: true

QubeRails::Engine.routes.draw do
  # A "Connect QuickBooks Desktop" button posts here. QuBe Sync's setup doesn't come back to your
  # app: it tells your connection class by webhook.
  post "quickbooks/connect", to: "connections#create", as: :connect

  # Each run's webhook URL is QUBE_WEBHOOK_URL/<operation>/<record id>
  # (QubeRails::Operation#webhook_url), and a connection's is
  # QUBE_WEBHOOK_URL/connection/<account id>.
  post "webhooks/qube/:operation/:record_id", to: "webhooks#create", as: :webhook

  # Your user's answers to a run's questions, from the question partial, and a record field's
  # search.
  post "qube/questions/:operation/:record_id", to: "questions#create", as: :question
  get "qube/questions/:operation/:record_id/search", to: "questions#search", as: :question_search
end
