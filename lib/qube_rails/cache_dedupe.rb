# frozen_string_literal: true

module QubeRails
  # The default dedupe setting: the notification delivery ids already taken, in Rails.cache, for
  # a day. Give it a store your workers share (Redis, Solid Cache): with a per-process store
  # (memory, or the file store on more than one machine) a retry that reaches another worker
  # isn't caught. Rails' test environment's null store remembers nothing.
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
