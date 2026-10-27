# frozen_string_literal: true

require "securerandom"

module QubeRails
  # One v2 operation your app queues itself, with no workflow, and what it does with that
  # request's webhooks. Subclass it once per request, list it in config.operations by its SLUG,
  # and see the README's "Plain requests".
  #
  #   class FindCustomer < QubeRails::Request
  #     OPERATION = "customer.query"
  #     SLUG = "find_customer"
  #
  #     def params
  #       { full_name: record.name }
  #     end
  #
  #     def answered(event) ... end
  #   end
  #
  #   row = QuickbooksDesktop::FindCustomer.queue(customer, connection)
  class Request
    # The QubeRails::QueuedRequest for record on connection. While the last one hasn't ended it's
    # returned (reused?), sent again first if QuBe Sync never confirmed it.
    def self.queue(record, connection)
      unless made_by_qube_sync?(connection)
        raise NotConnected, "QuBe Sync: #{name}.queue needs a connection QuBe Sync has made (one with a " \
                            "qube_id): the customer finishes onboarding first"
      end

      row, params_error = claim(record, connection)
      raise params_error if params_error
      return retry_queue(row) if row.reused?

      send_queue(row)
    end

    # Sends a queue that got no answer again, with the same params and Idempotency-Key.
    def self.retry_queue(row)
      return row if row.qube_id
      unless row.state == "queued"
        raise ArgumentError, "QuBe Sync: request #{row.id} is #{row.state}: only a queue that got no answer is sent again"
      end

      send_queue(row)
    end

    # Under the connection row's lock, so a double click finds the same row.
    def self.claim(record, connection)
      connection.with_lock do
        going = QubeRails::QueuedRequest.where(connection: connection).latest_for(record, self::SLUG)
        next [going.tap { |row| row.reused = true }, nil] if going && !going.ended?

        new_row(record, connection)
      end
    end
    private_class_method :claim

    def self.new_row(record, connection)
      row = QubeRails::QueuedRequest.new(
        connection: connection, operation: self::SLUG, record: record,
        reference: "#{self::SLUG}-#{record.id}-#{SecureRandom.uuid}", state: "queued"
      )
      begin
        # As JSON reads it back, so a resend sends exactly what the first did.
        row.params = JSONCoder.load(JSONCoder.dump(new(record, row).params))
      rescue StandardError, NotImplementedError => e
        row.state = "failed"
        row.ended_at = Time.now
        row.save!
        return [row, e]
      end
      row.save!
      [row, nil]
    end
    private_class_method :new_row

    def self.send_queue(row)
      answer =
        begin
          QubeRails.client.queue(self::OPERATION, row.connection.qube_id, row.params || {},
                                 webhook_url: row.webhook_url, idempotency_key: row.reference)
        rescue Backend::APIError => e
          mark_failed(row) if refused?(e)
          raise
        end
      record_queue(row, answer.is_a?(Hash) ? answer : {})
      row
    end
    private_class_method :send_queue

    # A 4xx but 409 (the key in use by a call still in flight): nothing was queued.
    def self.refused?(error)
      error.status.between?(400, 499) && error.status != 409
    end
    private_class_method :refused?

    def self.mark_failed(row)
      now = Time.now
      row.update_columns(state: "failed", ended_at: now, updated_at: now)
    end
    private_class_method :mark_failed

    def self.record_queue(row, answer)
      row.with_lock do
        row.qube_id ||= answer["id"]
        row.save!
      end
    end
    private_class_method :record_queue

    def self.made_by_qube_sync?(connection)
      connection.is_a?(QubeRails::Connection) && !connection.qube_id.to_s.empty?
    end
    private_class_method :made_by_qube_sync?

    # Write it to load the record your own way; left out, the row's record_type finds it.
    def self.find_record(id)
      raise NotImplementedError, "#{name}.find_record(#{id.inspect}) isn't written"
    end

    def self.record_for(row)
      if method(:find_record).owner == QubeRails::Request.singleton_class
        row.record
      else
        find_record(row.record_id)
      end
    end

    attr_reader :record, :queued_request

    def initialize(record, queued_request)
      @record = record
      @queued_request = queued_request
    end

    def connection
      queued_request.connection
    end

    # The operation's params, from the record.
    def params
      raise NotImplementedError, "#{self.class.name}#params isn't written yet"
    end

    # One response_received page: event.response_json["data"], event.page.
    def answered(event)
      log_event(event)
    end

    # Every page 1..N answered. Called once.
    def done; end

    # error or discarded: event.error["user_message"] is safe to show.
    def failed(event)
      log_event(event)
    end

    # QuBe Sync keeps trying: show event.error["user_message"], never resend.
    def retrying(event)
      log_event(event)
    end

    # QuickBooks may have applied it. A query can be queued again; check a write first.
    def timed_out(event)
      failed(event)
    end

    # One webhook, from the job, under the row's lock. Deliveries come at least once, in any order.
    def handle(event)
      changed = false
      queued_request.with_lock { changed = apply(event) }
      QubeRails.broadcast_refresh(record) if changed
    end

    private

    FINAL_STATES = %w[error timed_out discarded].freeze
    private_constant :FINAL_STATES

    def apply(event)
      row = queued_request
      unless this_request?(event)
        QubeRails.logger.warn("QuBe Sync: #{self.class.name} request #{row.id} skipped #{event.type} " \
                              "#{event["id"].inspect}: not this request")
        return false
      end
      return false unless take_once(event)

      row.qube_id ||= event.id
      case event.state
      when "response_received" then page_answered(event)
      when "retryable" then retryable(event)
      when *FINAL_STATES then final(event)
      else
        QubeRails.logger.warn("QuBe Sync: #{self.class.name} request #{row.id}: unknown state #{event.state.inspect}")
      end
      row.save!
      true
    end

    # Request events carry no connection id: the id is checked once the row has one.
    def this_request?(event)
      return false unless event.type == "request"

      qube_id = queued_request.qube_id
      qube_id.nil? || event.id == qube_id
    end

    # Records the delivery in this transaction: false for one taken already.
    def take_once(event)
      deliveries = QubeRails::RequestDelivery.where(request_id: queued_request.id)
      key = event.dedupe_key.to_s
      return false if deliveries.where(dedupe_key: key).exists?

      QubeRails::RequestDelivery.transaction(requires_new: true) do
        deliveries.create!(dedupe_key: key, page: page_of(event), state: event.state.to_s)
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def page_answered(event)
      row = queued_request
      row.last_page = page_of(event) if %w[done not_applicable].include?(event.iteration_state)
      row.state = "response_received" unless row.ended?
      answered(event)

      pages = answered_pages
      row.pages_answered = pages.size
      return if row.ended? || row.last_page.nil?
      return unless pages.count { |page| page.between?(1, row.last_page) } == row.last_page

      row.ended_at = Time.now
      done
    end

    def retryable(event)
      row = queued_request
      if page_settled?(event)
        QubeRails.logger.info("QuBe Sync: #{self.class.name} request #{row.id} page #{page_of(event)}: " \
                              "skipped a retryable that came after its answer")
        return
      end
      unless row.ended?
        row.state = "retryable"
        row.error = event.error
      end
      retrying(event)
    end

    def final(event)
      row = queued_request
      unless row.ended?
        row.state = event.state
        row.error = event.error
        row.ended_at = Time.now
      end
      event.state == "timed_out" ? timed_out(event) : failed(event)
    end

    def answered_pages
      QubeRails::RequestDelivery.where(request_id: queued_request.id, state: "response_received")
                                .distinct.pluck(:page).compact
    end

    def page_settled?(event)
      QubeRails::RequestDelivery.where(request_id: queued_request.id, page: page_of(event))
                                .where.not(state: "retryable").exists?
    end

    # An answer that wasn't paged is page 1.
    def page_of(event)
      event.page.is_a?(Integer) ? event.page : 1
    end

    def log_event(event)
      code = event.error.is_a?(Hash) ? " #{event.error["error_code"] || event.error["error_type"]}" : ""
      line = "QuBe Sync: #{self.class.name} #{record.id} (request #{queued_request.id}): " \
             "#{event.state} page #{page_of(event)}#{code}"
      if event.state == "response_received"
        QubeRails.logger.info(line)
      else
        QubeRails.logger.warn(line)
      end
    end
  end
end
