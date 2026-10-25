# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true if config.respond_to?(:cache_classes=)
  config.action_controller.allow_forgery_protection = false
  config.action_dispatch.show_exceptions = Rails.gem_version >= Gem::Version.new("7.1") ? :none : false
  config.active_support.deprecation = :stderr
end
