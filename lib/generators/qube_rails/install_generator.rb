require 'rails/generators'
require 'rails/generators/active_record'

module QubeRails
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('../templates', __FILE__)
      
      class_option :parent_model, type: :string, default: 'Account', 
                   desc: 'The model that will have QuickBooks connections (e.g., Account, User, Team)'
      class_option :scope, type: :string, default: '', 
                   desc: 'Namespace/scope for controllers (e.g., Admin::)'

      def validate_parent_model
        parent_model = options[:parent_model]
        
        # Check if the model exists in the application
        begin
          parent_model.constantize
        rescue NameError
          say "\n"
          say "Warning: #{parent_model} model not found!", :yellow
          say "Please ensure the #{parent_model} model exists before running the generator."
          say "The generator will attempt to add the QuickBooks connection association automatically."
          say "\n"
        end
      end

      def create_qube_connection_model
        template "models/qube/connection.rb", "app/models/qube/connection.rb"
      end

      def create_qube_request_model  
        template "models/qube/request.rb", "app/models/qube/request.rb"
      end

      def create_qube_base_model
        template "models/qube.rb", "app/models/qube.rb"
      end

      def add_association_to_parent_model
        parent_model = options[:parent_model]
        parent_model_file = "app/models/#{parent_model.underscore}.rb"
        
        unless File.exist?(parent_model_file)
          say "Warning: #{parent_model_file} not found. Please add the association manually:", :yellow
          say "   has_one :qube_connection, class_name: 'Qube::Connection', dependent: :destroy"
          return
        end

        # Check if association already exists
        file_content = File.read(parent_model_file)
        if file_content.match?(/has_one\s+:qube_connection/) || file_content.match?(/has_many\s+:qube_connections/)
          say "QuickBooks connection association already exists in #{parent_model}", :green
          return
        end

        # Try to inject after the class definition line
        if file_content.match?(/^class\s+#{parent_model}\s*</)
          inject_into_class parent_model_file, parent_model do
            "  has_one :qube_connection, class_name: 'Qube::Connection', dependent: :destroy\n"
          end
          say "Added has_one :qube_connection association to #{parent_model}", :green
        else
          say "Could not automatically add association to #{parent_model}. Please add manually:", :yellow
          say "   has_one :qube_connection, class_name: 'Qube::Connection', dependent: :destroy"
        end
      end

      def create_qbd_models
        add_qbd_acronym_inflection
        template "models/qbd.rb", "app/models/qbd.rb"
        template "models/qbd/customer.rb", "app/models/qbd/customer.rb"
      end

      def create_migrations
        migration_template "migrations/create_qube_connections.rb", 
                          "db/migrate/create_qube_connections.rb"
        migration_template "migrations/create_qube_requests.rb", 
                          "db/migrate/create_qube_requests.rb"
        migration_template "migrations/create_qbd_customers.rb", 
                          "db/migrate/create_qbd_customers.rb"
      end

      def create_controllers
        @scope_prefix = options[:scope]
        @connection_parent = "current_#{options[:parent_model].underscore}"
        
        template "controllers/qube_connections_controller.rb", 
                "app/controllers/#{@scope_prefix.underscore}qube_connections_controller.rb"
        template "controllers/qbd/customers_controller.rb", 
                "app/controllers/qbd/customers_controller.rb"
      end

      def create_views
         copy_file "views/shared/_connect_to_qbd.html.erb", 
                "app/views/shared/_connect_to_qbd.html.erb"
      end

      def create_jobs
        template "jobs/qbd_customer_query_webhook_job.rb", 
                "app/jobs/qbd_customer_query_webhook_job.rb"
      end

      def create_rspec_helpers
        return unless File.exist?('spec/rails_helper.rb')
        
        template "spec/qube_rails_helpers.rb", "spec/support/qube_rails_helpers.rb"
        template "spec/factories.rb", "spec/factories/qube_rails.rb"
      end

      def create_routes
        route_content = <<~RUBY
          
          # QUBE Sync Rails routes
          resources :qube_connections, only: [:create, :destroy] do
            collection do
              get :onboarding
              get :callback
            end
          end

          namespace :qbd do
            resources :customers, only: [:index, :show, :destroy]
          end
        RUBY

        route route_content
      end

      def create_initializer
        template "initializers/qube_sync.rb", "config/initializers/qube_sync.rb"
      end

      def create_rspec_helpers_if_needed
        create_rspec_helpers if File.exist?('spec/rails_helper.rb')
      end

      def show_installation_instructions
        say "\n"
        say "QUBE Sync Rails has been installed!", :green
        say "\n"
        say "Next steps:", :yellow
        say "1. Update config/initializers/qube_sync.rb with your API credentials"
        say "2. Restart your Rails server if it's running"
        say "3. Run: rails db:migrate"
        say "4. Add a button in your UI to start the QuickBooks Desktop connection process:"
        say "   <%= render 'shared/connect_to_qbd' %>"

        
        if File.exist?('spec/rails_helper.rb')
          say "5. RSpec helpers and factories have been created in spec/support/ and spec/factories/"
          say "6. Add this line to spec/rails_helper.rb if needed:"
          say "   Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }"
        end
        
        say "\n"
        say "You can now connect to QuickBooks Desktop!", :green
      end

      private

      def add_qbd_acronym_inflection
        inflection_file = "config/initializers/inflections.rb"
        
        # Check if the file exists
        unless File.exist?(inflection_file)
          create_file inflection_file, inflections_template
          return
        end
        
        # Check if QBD acronym is already defined
        file_content = File.read(inflection_file)
        return if file_content.match?(/inflect\.acronym.*:?qbd/i)
        
        # Check if there's an active inflections block
        if file_content.match?(/ActiveSupport::Inflector\.inflections\(:en\)\s+do\s*$/m)
          inject_into_file inflection_file, after: "ActiveSupport::Inflector.inflections(:en) do\n" do
            "  inflect.acronym 'QBD'\n"
          end
        elsif file_content.match?(/ActiveSupport::Inflector\.inflections\s+do\s*$/m)
          inject_into_file inflection_file, after: "ActiveSupport::Inflector.inflections do\n" do
            "  inflect.acronym 'QBD'\n"
          end
        else
          # No active inflections block found, append to the end of the file
          append_to_file inflection_file, "\n#{inflections_template}"
        end
      end

      def inflections_template
        <<~RUBY
          # Be sure to restart your server when you modify this file.

          # Add new inflection rules using the following format. Inflections
          # are locale specific, and you may define rules for as many different
          # locales as you wish. All of these examples are active by default:
          ActiveSupport::Inflector.inflections(:en) do |inflect|
            inflect.acronym 'QBD'
          end
        RUBY
      end

      def next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end
    end
  end
end