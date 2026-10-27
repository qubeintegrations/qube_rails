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
  #   POST qube/runs/:id/retry_start               an unconfirmed start sent again, likewise
  #   GET  qube/storyboard(/:screen)               every screen with sample data (config.storyboard)
  # Your views reach them through the qube_rails route proxy: qube_rails.connections_path,
  # qube_rails.connection_onboarding_path(connection).
  class Engine < ::Rails::Engine
    isolate_namespace QubeRails

    # qube_rails_assets and qube_classes, in every view of the app.
    initializer "qube_rails.view_helpers" do
      ActiveSupport.on_load(:action_view) { include QubeRails::ViewHelpers }
    end

    # Sprockets serves only what's listed; Propshaft serves every asset path and has no list.
    initializer "qube_rails.assets" do |app|
      assets = app.config.respond_to?(:assets) ? app.config.assets : nil
      precompile = assets && assets.precompile
      precompile.concat(%w[qube_rails/question.js qube_rails.css]) if precompile.is_a?(Array)
    end
  end
end
