# frozen_string_literal: true

module QubeRails
  # A setting the app hasn't written yet, raised the first time it's needed.
  class NotConfigured < StandardError; end

  # The only place qube_rails reads your app from: QubeRails.configure in
  # config/initializers/qube_rails.rb (`rails g qube_rails:install` writes one). A setting your
  # app hasn't written raises QubeRails::NotConfigured, naming that file, the first time it's
  # needed, so nothing silently passes.
  class Configuration
    FILE = "config/initializers/qube_rails.rb"
    DEFAULT_BASE_URL = "https://qubesync.com"

    attr_writer :base_url, :api_key, :webhook_secret, :webhook_url, :queue, :parent_controller

    def initialize
      @operations = nil
      @connection_events = nil
      @current_account = nil
      @authorize_question = nil
      @enqueue = nil
      @dedupe = nil
      @queue = nil
      @job_attempts = nil
      @prune_runs_after = nil
      @parent_controller = nil
      @api_key = nil
      @base_url = nil
      @webhook_secret = nil
      @webhook_url = nil
    end

    # Each operation by its slug (the SLUG a run row keeps, in qube_runs.operation), as class
    # *names*:
    #   config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
    # Names, not classes, so code reloading in development finds the class again each time. A
    # fixed list, so a class is never looked up from anything a request says.
    def operations=(map)
      unless map.respond_to?(:each_pair)
        raise ArgumentError, "operations is a Hash of slug => class name, in #{FILE}"
      end

      list = {}
      map.each_pair do |slug, name|
        list[slug.to_s] = name.is_a?(Module) ? name.name : name.to_s
      end
      @operations = list.freeze
    end

    def operations
      @operations || not_configured(:operations, "the operations by slug, as class names")
    end

    # Your class for a connection's own events (a QubeRails::ConnectionEvents), by name:
    #   config.connection_events = "QuickbooksDesktop::ConnectionEvents"
    def connection_events=(name)
      @connection_events = name.is_a?(Module) ? name.name : name && name.to_s
    end

    def connection_events
      @connection_events || not_configured(:connection_events, "your ConnectionEvents class's name")
    end

    def connection_events_class
      constantize(connection_events)
    end

    # The operation class for a slug, or nil when none of your operations has it.
    def operation_class(slug)
      name = operations[slug.to_s]
      name && constantize(name)
    end

    # The signed-in customer's account, called with the controller handling the request (so your
    # current_user and other helpers are there):
    #   config.current_account = ->(controller) { controller.current_user.account }
    # It owns the connections onboarding makes (QubeRails::Connection#owner), and only its own can
    # be sent back through setup; nil answers 401.
    def current_account=(callable)
      @current_account = callable!(:current_account, callable)
    end

    def current_account
      @current_account || not_configured(:current_account,
                                         "->(controller) { the signed-in customer's account }")
    end

    # Whether the signed-in user may answer or search the question a run asks about record. The
    # run (a QubeRails::Run) carries its operation and its connection, whose owner is the account
    # that connected it. Only true allows; anything else is refused (404, as for a missing run)
    # and logged. The run's id comes from the URL, so this is what keeps one customer's users off
    # another's runs.
    #
    # The default allows the signed-in account (current_account) when it owns the run's
    # connection. Set your own to check more (that the user may see the record), or less (staff
    # who act across accounts):
    #   config.authorize_question = ->(controller, record, run) {
    #     run.connection.owner == controller.current_user.account && controller.current_user.can_edit?(record)
    #   }
    def authorize_question=(callable)
      @authorize_question = callable!(:authorize_question, callable)
    end

    def authorize_question
      @authorize_question || method(:owner_answers)
    end

    # Hands a verified delivery, { kind:, id:, body: } (kind "run" or "connection", id the row's),
    # to a queue. The default puts it on ActiveJob (QubeRails::WebhookJob, on the queue setting).
    # Your own queue's worker calls QubeRails.run(kind, id, body).
    def enqueue=(callable)
      @enqueue = callable!(:enqueue, callable)
    end

    def enqueue
      @enqueue || method(:enqueue_on_active_job)
    end

    # How many times QubeRails::WebhookJob runs a delivery before it gives up (retry_on, with a
    # growing wait), read when the job class loads. Default 10.
    def job_attempts
      @job_attempts || 10
    end

    def job_attempts=(attempts)
      unless attempts.is_a?(Integer) && attempts >= 1
        raise ArgumentError, "job_attempts is a whole number of 1 or more, in #{FILE}"
      end

      @job_attempts = attempts
    end

    # The ActiveJob queue QubeRails::WebhookJob runs on.
    def queue
      @queue || :default
    end

    # How long ended runs are kept before QubeRails::PruneRunsJob deletes them (nil: never).
    attr_reader :prune_runs_after

    def prune_runs_after=(duration)
      unless duration.nil? || (duration.respond_to?(:to_i) && duration.to_i >= 1.day.to_i)
        raise ArgumentError, "prune_runs_after is nil or a duration of a day or more, in #{FILE}"
      end

      @prune_runs_after = duration
    end

    # Where the notification delivery ids each run has taken are kept, so a redelivery runs its
    # handler once. The default is the engine's qube_notifications table
    # (QubeRails::DatabaseDedupe), written in the same transaction as the handler. Another store
    # answers once(run, delivery_id) { } (running the block unless it's taken), or seen?(key) and
    # remember(key), as QubeRails::CacheDedupe (Rails.cache, not transactional) does.
    def dedupe=(store)
      unless dedupe_store?(store)
        raise ArgumentError, "dedupe needs once(run, delivery_id) { }, or seen?(key) and remember(key), in #{FILE}"
      end

      @dedupe = store
    end

    def dedupe
      @dedupe ||= DatabaseDedupe.new
    end

    # The controller onboarding and the question routes inherit, by name, so your sign-in and
    # CSRF protection apply to them.
    def parent_controller
      @parent_controller || "ApplicationController"
    end

    # QUBE_API_KEY, which `qube env --write .env` writes.
    def api_key
      @api_key || env("QUBE_API_KEY") || env_not_set(:api_key, "QUBE_API_KEY")
    end

    # QUBE_URL, or https://qubesync.com.
    def base_url
      @base_url || env("QUBE_URL") || DEFAULT_BASE_URL
    end

    # QUBE_WEBHOOK_SECRET, or a list of secrets while one rotates.
    def webhook_secret
      @webhook_secret || env("QUBE_WEBHOOK_SECRET") ||
        env_not_set(:webhook_secret, "QUBE_WEBHOOK_SECRET")
    end

    # QUBE_WEBHOOK_URL, the base of each run's and each connection's webhook URL: `qube listen
    # --write-env .env` writes it in development, and in production it's your app's
    # /webhooks/qube.
    def webhook_url
      url = @webhook_url || env("QUBE_WEBHOOK_URL") ||
            env_not_set(:webhook_url, "QUBE_WEBHOOK_URL")
      url.to_s.chomp("/")
    end

    # Never the API key or a webhook secret.
    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect} operations=#{@operations.inspect} " \
        "connection_events=#{@connection_events.inspect} api_key=#{secret_state(@api_key, "QUBE_API_KEY")} " \
        "webhook_secret=#{secret_state(@webhook_secret, "QUBE_WEBHOOK_SECRET")}>"
    end
    alias to_s inspect

    private

    # Answers once(run, delivery_id) { }, or seen?(key) and remember(key).
    def dedupe_store?(store)
      store.respond_to?(:once) || (store.respond_to?(:seen?) && store.respond_to?(:remember))
    end

    # The default authorize_question: the signed-in account owns the run's connection. Compared
    # by type and id, as the connection keeps them, so a nil or unsaved account never matches.
    def owner_answers(controller, _record, run)
      account = current_account.call(controller)
      return false if account.nil? || account.id.nil?
      return false if account.respond_to?(:persisted?) && !account.persisted?

      klass = account.class
      type = klass.respond_to?(:base_class) ? klass.base_class.name : klass.name
      connection = run.connection
      type == connection.owner_type && account.id.to_s == connection.owner_id.to_s
    end

    def enqueue_on_active_job(delivery)
      QubeRails::WebhookJob.perform_later(delivery[:kind], delivery[:id], delivery[:body])
    end

    def constantize(name)
      name.to_s.constantize
    end

    def env(name)
      value = ENV[name]
      value unless value.nil? || value.strip.empty?
    end

    def callable!(setting, callable)
      return nil if callable.nil?
      return callable if callable.respond_to?(:call)

      raise ArgumentError, "#{setting} must respond to call, in #{FILE}"
    end

    def secret_state(value, env_name)
      value || env(env_name) ? "[hidden]" : "nil"
    end

    def not_configured(setting, what)
      raise NotConfigured, "QuBe Sync: #{setting} isn't set yet. Set config.#{setting} (#{what}) " \
                           "in QubeRails.configure, in #{FILE}."
    end

    def env_not_set(setting, env_name)
      raise NotConfigured, "QuBe Sync: #{setting} isn't set yet. Set #{env_name} in the " \
                           "environment, or config.#{setting} in QubeRails.configure, in #{FILE}."
    end
  end
end
