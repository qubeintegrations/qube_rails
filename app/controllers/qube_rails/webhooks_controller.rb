# frozen_string_literal: true

module QubeRails
  # Receives QuBe Sync's webhooks at POST /webhooks/qube/runs/<run id>, the URL each run was
  # started with (QubeRails::Run#webhook_url), and at /webhooks/qube/connections/<connection id>,
  # each connection's (QubeRails::Connection#webhook_url). It only verifies the delivery, checks
  # the row is there and enqueues it (config.enqueue), so it answers well inside the 5 seconds
  # QuBe Sync waits: the job does the rest.
  #
  # The verification is the qube_sync gem's: the signature over the raw body, with any v1
  # matching in constant time, and a timestamp within 5 minutes either way. No sign-in and no
  # CSRF token: the signature is what proves QuBe Sync sent it.
  class WebhooksController < ActionController::API
    # The largest body taken: a pull_changes page can be a few megabytes. Anything larger is
    # answered 413 before it's read.
    MAX_BODY_BYTES = 5 * 1024 * 1024

    # Any content type: the body is only ever read raw, so Rails never parses it as params.
    wrap_parameters false

    def run_event
      receive("run", QubeRails::Run)
    end

    def connection_event
      receive("connection", QubeRails::Connection)
    end

    private

    def receive(kind, model)
      return too_large if request.content_length.to_i > MAX_BODY_BYTES

      body = request.raw_post.to_s
      return too_large if body.bytesize > MAX_BODY_BYTES

      Backend.verify(body, request.headers["X-Qube-Signature"], secrets: QubeRails.config.webhook_secret)
      id = request.path_parameters[:id].to_s
      # A row that isn't there (deleted, or a wrong webhook_url): QuBe Sync retries it, and shows
      # it as a failed delivery.
      return head(:not_found) unless model.where(id: id).exists?

      # The signature covers the body, not the URL, so the id is only a pointer: the job checks
      # the event's reference and connection id against the row.
      # The body goes as text, which any queue can carry; the job parses it again.
      QubeRails.config.enqueue.call(kind: kind, id: id, body: body.dup.force_encoding(Encoding::UTF_8))
      head :ok
    rescue Backend::SignatureError => e
      # Its reason (missing, malformed, stale or mismatch) is safe to log: never the secret, the
      # signature or the body.
      QubeRails.logger.warn("QuBe Sync: refused a webhook: #{e.reason}")
      head :unauthorized
    rescue Backend::ParseError => e
      # Signed, but not a JSON object: nothing a job could take.
      QubeRails.logger.warn("QuBe Sync: refused a webhook: #{e.message}")
      head :bad_request
    end

    def too_large
      QubeRails.logger.warn("QuBe Sync: refused a webhook: its body is over #{MAX_BODY_BYTES} bytes")
      head 413
    end
  end
end
