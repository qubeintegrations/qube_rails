# frozen_string_literal: true

module QubeRails
  # Receives QuBe Sync's webhooks at POST /webhooks/qube/<operation>/<record id>, the URL each
  # run was started with (QubeRails::Operation#webhook_url), and at
  # /webhooks/qube/connection/<account id>, the customer's connection's
  # (QubeRails::ConnectionEvents#webhook_url). It only verifies the delivery, checks the
  # operation and enqueues it (config.enqueue), so it answers well inside the 5 seconds QuBe Sync
  # waits: the job does the rest.
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

    def create
      if request.content_length.to_i > MAX_BODY_BYTES
        QubeRails.logger.warn("QuBe Sync: refused a webhook: its body is over #{MAX_BODY_BYTES} bytes")
        return head(413)
      end

      body = request.raw_post.to_s
      if body.bytesize > MAX_BODY_BYTES
        QubeRails.logger.warn("QuBe Sync: refused a webhook: its body is over #{MAX_BODY_BYTES} bytes")
        return head(413)
      end

      Backend.verify(body, request.headers["X-Qube-Signature"],
                     secrets: QubeRails.config.webhook_secret)
      slug = request.path_parameters[:operation].to_s
      # A URL none of your operations writes: QuBe Sync retries it, and shows it as a failed
      # delivery, which means a wrong webhook_url.
      return head(:not_found) unless QubeRails.config.handler_for(slug)

      # The signature covers the body, not the URL, so the record id is only a pointer: the job
      # checks that the event's reference (a connection event's connection id) is the one saved
      # on that record.
      # The body goes as text, which any queue can carry; the job parses it again.
      QubeRails.config.enqueue.call(
        operation: slug,
        record_id: request.path_parameters[:record_id].to_s,
        body: body.dup.force_encoding(Encoding::UTF_8)
      )
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
  end
end
