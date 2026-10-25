# frozen_string_literal: true

module QubeRails
  # A dedupe setting for an app that would rather not use the engine's table
  # (QubeRails::DatabaseDedupe, the default): the notification delivery ids already taken, in
  # Rails.cache, for a day. It needs a store your workers share (Redis, Solid Cache): with a
  # per-process store (memory, or the file store on more than one machine) a retry that reaches
  # another worker isn't caught, and the null store remembers nothing. It isn't transactional:
  # the id is remembered after the handler commits, so a crash between the two runs the handler
  # again on the redelivery.
  #   config.dedupe = QubeRails::CacheDedupe.new(Rails.cache, expires_in: 1.day)
  class CacheDedupe
    DAY = 24 * 60 * 60

    def initialize(cache = nil, expires_in: DAY)
      @cache = cache
      @expires_in = expires_in
    end

    def seen?(key)
      cache.exist?(key)
    end

    def remember(key)
      cache.write(key, true, expires_in: @expires_in)
    end

    private

    def cache
      @cache || Rails.cache
    end
  end
end
