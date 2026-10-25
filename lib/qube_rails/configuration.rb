module QubeRails
  class Configuration
    attr_accessor :api_key, :webhook_secret, :api_base_url, :timeout, :open_timeout, 
                  :max_retries, :retry_delay, :debug, :logger

    def initialize
      @api_base_url = 'https://qubesync.com/api/v1'
      # @timeout = 30
      # @open_timeout = 10
      # @max_retries = 3
      # @retry_delay = 1
      # @debug = false
      # @logger = defined?(Rails) ? Rails.logger : Logger.new(STDOUT)
    end

    def configure_qube_sync!
      QubeSync.configure do |config|
        config.api_key = api_key if api_key
        config.webhook_secret = webhook_secret if webhook_secret
        config.base_url = api_base_url if api_base_url
        # config.timeout = timeout if timeout
        # config.open_timeout = open_timeout if open_timeout
        # config.max_retries = max_retries if max_retries
        # config.retry_delay = retry_delay if retry_delay
        # config.debug = debug if debug
        # config.logger = logger if logger
      end
    end
  end
end