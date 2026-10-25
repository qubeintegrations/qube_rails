# frozen_string_literal: true

module QubeRails
  # A setting the app hasn't written yet, raised the first time it's needed.
  class NotConfigured < StandardError; end

  # The only place qube_rails reads your app from: QubeRails.configure in
  # config/initializers/qube_rails.rb (`rails g qube_rails:install` writes one). A setting your
  # app hasn't written raises QubeRails::NotConfigured, naming that file, the first time it's
  # needed, so nothing silently passes; authorize_question, unset, refuses every answer and
  # search instead.
  class Configuration
    FILE = "config/initializers/qube_rails.rb"
    DEFAULT_BASE_URL = "https://qubesync.com"
    # The connection's own events, in webhook URLs: QUBE_WEBHOOK_URL/connection/<account id>.
    # Not an operation: the connection class takes them.
    CONNECTION_SLUG = "connection"

    attr_writer :base_url, :api_key, :webhook_secret, :webhook_url, :queue, :parent_controller

    def initialize
      @operations = nil
      @connection = nil
      @current_account = nil
      @authorize_question = nil
      @enqueue = nil
      @dedupe = nil
      @queue = nil
      @parent_controller = nil
      @api_key = nil
      @base_url = nil
      @webhook_secret = nil
      @webhook_url = nil
    end

    # Each operation by the slug in its webhook URL, as class *names*:
    #   config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
    # Names, not classes, so code reloading in development finds the class again each time. A
    # fixed list, so a class is never looked up from the URL itself: the webhook endpoint answers
    # 404 for any other slug.
    def operations=(map)
      unless map.respond_to?(:each_pair)
        raise ArgumentError, "operations is a Hash of slug => class name, in #{FILE}"
      end

      list = {}
      map.each_pair do |slug, name|
        slug = slug.to_s
        if slug == CONNECTION_SLUG
          raise ArgumentError, "\"connection\" is the connection's own slug, not an operation's: " \
                               "set config.connection in #{FILE} instead"
        end
        list[slug] = name.is_a?(Module) ? name.name : name.to_s
      end
      @operations = list.freeze
    end

    def operations
      @operations || not_configured(:operations, "the operations by slug, as class names")
    end

    # The connection class (a QubeRails::ConnectionEvents), by name:
    #   config.connection = "QuickbooksDesktop::Connection"
    def connection=(name)
      @connection = name.is_a?(Module) ? name.name : name.to_s
    end

    def connection
      @connection || not_configured(:connection, "the connection class's name")
    end

    def connection_class
      constantize(connection)
    end

    # The operation class for a slug, or nil when none of your operations has it (the connection's
    # own slug included).
    def operation_class(slug)
      name = operations[slug.to_s]
      name && constantize(name)
    end

    # The class that takes a webhook to this slug: an operation's, the connection class for
    # "connection", or nil.
    def handler_for(slug)
      return connection_class if slug.to_s == CONNECTION_SLUG

      operation_class(slug)
    end

    # The signed-in customer's account, called with the controller handling the request (so your
    # current_user and other helpers are there):
    #   config.current_account = ->(controller) { controller.current_user.account }
    # Onboarding keeps the connection on it, and its id goes in the connection's webhook URL; nil
    # answers 401.
    def current_account=(callable)
      @current_account = callable!(:current_account, callable)
    end

    def current_account
      @current_account || not_configured(:current_account,
                                         "->(controller) { the signed-in customer's account }")
    end

    # Whether the signed-in user may answer or search the question a run asks about record, with
    # the operation's slug:
    #   config.authorize_question = ->(controller, record, operation) {
    #     record.account_id == controller.current_user.account_id
    #   }
    # Only true allows; anything else is refused and logged. The record's id comes from the URL,
    # so this is all that keeps one customer's users off another's records. Unset, every answer
    # and search is refused, and logged.
    def authorize_question=(callable)
      @authorize_question = callable!(:authorize_question, callable)
    end

    attr_reader :authorize_question

    # Hands a verified delivery, { operation:, record_id:, body: }, to a queue. The default puts
    # it on ActiveJob (QubeRails::WebhookJob, on the queue setting). Your own queue's worker calls
    # QubeRails.run(operation, record_id, body).
    def enqueue=(callable)
      @enqueue = callable!(:enqueue, callable)
    end

    def enqueue
      @enqueue || method(:enqueue_on_active_job)
    end

    # The ActiveJob queue QubeRails::WebhookJob runs on.
    def queue
      @queue || :default
    end

    # seen?(key) and remember(key), for notification delivery ids. The default is Rails.cache, for
    # a day (QubeRails::CacheDedupe): give it a store your workers share (Redis, Solid Cache), so
    # a retry that reaches another worker is still caught.
    def dedupe=(store)
      unless store.respond_to?(:seen?) && store.respond_to?(:remember)
        raise ArgumentError, "dedupe needs seen?(key) and remember(key), in #{FILE}"
      end

      @dedupe = store
    end

    def dedupe
      @dedupe ||= CacheDedupe.new
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
        "connection=#{@connection.inspect} api_key=#{secret_state(@api_key, "QUBE_API_KEY")} " \
        "webhook_secret=#{secret_state(@webhook_secret, "QUBE_WEBHOOK_SECRET")}>"
    end
    alias to_s inspect

    private

    def enqueue_on_active_job(delivery)
      QubeRails::WebhookJob.perform_later(delivery[:operation], delivery[:record_id], delivery[:body])
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
