require 'qube_sync'
require 'qube_rails/version'
require 'qube_rails/configuration'
require 'qube_rails/engine' if defined?(Rails)

module QubeRails
  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  def self.config
    self.configuration ||= Configuration.new
  end

  # Delegate common methods to QubeSync for convenience
  def self.method_missing(method_name, *args, &block)
    if QubeSync.respond_to?(method_name)
      QubeSync.send(method_name, *args, &block)
    else
      super
    end
  end

  def self.respond_to_missing?(method_name, include_private = false)
    QubeSync.respond_to?(method_name) || super
  end
end

# Alias for backwards compatibility
QubeSyncRails = QubeRails unless defined?(QubeSyncRails)