# frozen_string_literal: true

require "rails/engine"

module QubeRails
  # Mounted in your config/routes.rb with `mount QubeRails::Engine => "/"`, which adds, relative
  # to where it's mounted:
  #   POST quickbooks/connect                           onboarding, behind your sign-in
  #   POST webhooks/qube/:operation/:record_id          QuBe Sync's webhooks: no sign-in, no CSRF
  #   POST qube/questions/:operation/:record_id         an answer, behind your sign-in and CSRF
  #   GET  qube/questions/:operation/:record_id/search  a record field's matches, behind sign-in
  # Your views reach them through the qube_rails route proxy: qube_rails.connect_path.
  class Engine < ::Rails::Engine
    isolate_namespace QubeRails
  end
end
