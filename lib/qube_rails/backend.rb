# frozen_string_literal: true

require "qube_sync/webhooks"
require "qube_sync/client"

module QubeRails
  # Every call qube_rails makes to the qube_sync gem goes through here, and nowhere else: the
  # client, verifying and parsing a webhook, and the errors they raise. An app on a Ruby the gem
  # doesn't run on (it needs 3.3) gets a copy of qube_rails whose Backend does the same inline,
  # with Net::HTTP and OpenSSL, so the rest of these files stay the same in both.
  #
  # What the rest of qube_rails relies on:
  # - client(api_key:, base_url:, on_retry:) answers create_connection, update_connection,
  #   regenerate_onboarding, start_run, answer and search as QubeSync::Client does, returning the
  #   response's data, and raises APIError (status, body) for anything outside 2xx;
  # - verify(raw_body, header, secrets:) raises SignatureError (with a reason: missing, malformed,
  #   stale or mismatch) unless the delivery checks out;
  # - parse(raw_body) returns the typed event (QubeSync::Webhooks' WorkflowRunEvent,
  #   NotificationEvent, ConnectionEvent and the rest), raising ParseError for a body that isn't
  #   a JSON object;
  # - workflow_types(client, include_drafts:, etag:), render_workflow_types(document, ...) and
  #   check_workflow_types(existing, ...) are `bin/rails g qube_rails:workflows`'s: the app's
  #   workflow input types as QuBe Sync serves them, rendered into app/qube/qube_workflows.rb and
  #   its RBS, and compared with a written file (QubeSync::WorkflowTypes). They need the gem's
  #   renderer, so the inline backend raises for them, saying typed workflows need the qube_sync
  #   gem (Ruby 3.3).
  module Backend
    APIError = QubeSync::APIError
    SignatureError = QubeSync::Webhooks::SignatureError
    ParseError = QubeSync::Webhooks::ParseError
    # What a call that got no answer raises (a timeout, a refused or dropped connection).
    NETWORK_ERRORS = QubeSync::Client::NETWORK_ERRORS

    module_function

    def client(api_key:, base_url:, on_retry: nil)
      QubeSync::Client.new(api_key: api_key, base_url: base_url, on_retry: on_retry)
    end

    def verify(raw_body, header, secrets:)
      QubeSync::Webhooks.verify(raw_body, header, secrets: secrets)
    end

    def parse(raw_body)
      QubeSync::Webhooks.parse(raw_body)
    end

    # The app's workflow types document, or :not_modified when etag (its digest) is still current.
    def workflow_types(client, include_drafts: false, etag: nil)
      client.workflow_types(include_drafts: include_drafts, etag: etag)
    end

    # The Ruby and the RBS for a document (ruby, rbs, digest, drafts, warnings). source is the URL
    # the header names, command the one it says to run again, client_expression what a start's
    # client defaults to.
    def render_workflow_types(document, source:, drafts:, command:, client_expression:)
      require "qube_sync/workflow_types"
      QubeSync::WorkflowTypes.render(document, source: source, drafts: drafts, command: command,
                                               client: client_expression)
    end

    # A written file (its Ruby source) against what QuBe Sync serves now: status (:current,
    # :stale, :unreachable or :error), message, changes, warnings and exit_status.
    def check_workflow_types(existing, client:, source:, path:, command:, client_expression:)
      require "qube_sync/workflow_types"
      QubeSync::WorkflowTypes.check(existing, client: client, source: source, path: path, command: command,
                                              client_expression: client_expression)
    end
  end
end
