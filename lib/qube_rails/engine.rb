# frozen_string_literal: true

require "rails/engine"

module QubeRails
  # Mounted in your config/routes.rb with `mount QubeRails::Engine => "/"`, which adds, relative
  # to where it's mounted:
  #   POST quickbooks/connections                  a connection for the signed-in account
  #   POST quickbooks/connections/:id/onboarding   one of its connections, through setup again
  #   POST webhooks/qube/runs/:id                  a run's webhooks: no sign-in, no CSRF
  #   POST webhooks/qube/connections/:id           a connection's webhooks: no sign-in, no CSRF
  #   POST qube/questions/runs/:id                 an answer, behind your sign-in and CSRF
  #   GET  qube/questions/runs/:id/search          a record field's matches, behind sign-in
  # Your views reach them through the qube_rails route proxy: qube_rails.connections_path,
  # qube_rails.connection_onboarding_path(connection).
  class Engine < ::Rails::Engine
    isolate_namespace QubeRails
  end
end
