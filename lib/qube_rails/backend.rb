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
  #   a JSON object.
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
  end
end
