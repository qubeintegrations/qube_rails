# QUBE Sync Rails Configuration
# Feel free to replace ENV with rails credentials or other secure storage methods.

QubeRails.configure do |config|
  # Your QUBE Sync API credentials
  config.api_key = ENV['QUBE_API_KEY']
  
  # Webhook configuration
  config.webhook_secret = ENV['QUBE_WEBHOOK_SECRET']
  
  # API settings
  config.api_base_url = ENV['QUBE_URL'] || 'https://qubesync.com/api/v1'
  config.timeout = 30 # seconds
  
  # Development settings
  config.debug = Rails.env.development?
  config.logger = Rails.logger
  
end