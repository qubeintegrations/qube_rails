# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module QubeRails
  module Generators
    # rails g qube_rails:install [table]
    #
    # Writes the app's side of a QuBe Sync integration, for an app that doesn't start from the
    # integration kit: config/initializers/qube_rails.rb (every setting, commented), the
    # connection class (app/services/quickbooks_desktop/connection.rb), a migration adding
    # qube_connection_id and qube_connection_revision to table (accounts unless named), and the
    # engine's mount line in config/routes.rb.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :table, type: :string, default: "accounts",
                       desc: "The table of the accounts that keep a connection"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/qube_rails.rb"
      end

      def create_connection_class
        template "connection.rb.tt", "app/services/quickbooks_desktop/connection.rb"
      end

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/add_qube_connection_to_#{table_name}.rb"
      end

      def mount_engine
        route 'mount QubeRails::Engine => "/"'
      end

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      private

      def table_name
        table.to_s.underscore.tr("/", "_").pluralize
      end

      def model_name
        table_name.classify
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
