# frozen_string_literal: true

require "rails/generators"

module QubeRails
  module Generators
    # rails g qube_rails:install
    #
    # Writes the app's side of a QuBe Sync integration, for an app that doesn't start from the
    # integration kit: config/initializers/qube_rails.rb (every setting, commented), your class
    # for a connection's events (app/services/quickbooks_desktop/connection_events.rb), the
    # engine's migration (qube_connections, qube_runs, qube_notifications and
    # qube_quickbooks_records, through `qube_rails:install:migrations`), the engine's mount
    # line in config/routes.rb, and qube_rails_assets in your layout. Your own tables need nothing.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb.tt", "config/initializers/qube_rails.rb"
      end

      def create_connection_events
        template "connection_events.rb.tt", "app/services/quickbooks_desktop/connection_events.rb"
      end

      def copy_migrations
        rails_command "qube_rails:install:migrations"
      end

      def mount_engine
        route 'mount QubeRails::Engine => "/"'
      end

      # The question's behaviour script (its search boxes and rows table), in the layout's <head>.
      def include_assets
        layout = "app/views/layouts/application.html.erb"
        path = File.join(destination_root, layout)
        unless File.exist?(path)
          return say_status(:skip, "no #{layout}: add <%= qube_rails_assets %> to your layout's <head>", :yellow)
        end
        return if File.read(path).include?("qube_rails_assets")

        insert_into_file layout, "    <%= qube_rails_assets %>\n", before: "  </head>"
      end
    end
  end
end
