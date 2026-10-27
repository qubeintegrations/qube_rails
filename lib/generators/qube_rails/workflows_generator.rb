# frozen_string_literal: true

require "rails/generators"

module QubeRails
  module Generators
    # rails g qube_rails:workflows [--drafts] [--check]
    #
    # Writes your app's typed workflow starts: app/qube/qube_workflows.rb (QubeWorkflows, a
    # module per workflow with a start method per branch of its input, autoloaded from app/qube)
    # and sig/qube_workflows.rbs, from the workflow input types QuBe Sync serves for your app's
    # API key (config.api_key). Each start uses QubeRails.client. Check both files in, and run it
    # again when a workflow is published.
    #
    # --drafts types each workflow's draft where it has one. --check writes nothing, and exits 1
    # when the file is out of date (or QuBe Sync refuses the key), for CI; when QuBe Sync can't be
    # reached it warns and passes.
    class WorkflowsGenerator < Rails::Generators::Base
      RUBY = "app/qube/qube_workflows.rb"
      SIG = "sig/qube_workflows.rbs"
      COMMAND = "bin/rails g qube_rails:workflows"
      CLIENT = "::QubeRails.client"

      class_option :drafts, type: :boolean, default: false,
                            desc: "Type each workflow's draft where it has one"
      class_option :check, type: :boolean, default: false,
                           desc: "Write nothing; exit 1 when #{RUBY} is out of date"

      def write_or_check
        options[:check] ? check : write
      end

      private

      def write
        document = Backend.workflow_types(QubeRails.client, include_drafts: options[:drafts])
        files = Backend.render_workflow_types(document, source: source, drafts: options[:drafts], command: COMMAND,
                                                        client_expression: CLIENT)
        warn_each(files.warnings)
        create_file RUBY, files.ruby, force: true
        create_file SIG, files.rbs, force: true
      rescue Backend::APIError => e
        fail_with(e.message)
      rescue *Backend::NETWORK_ERRORS, SystemCallError => e
        fail_with("couldn't reach QuBe Sync (#{e.class}: #{e.message}); nothing was written")
      end

      def check
        path = File.join(destination_root, RUBY)
        fail_with("#{RUBY} isn't there: run `#{COMMAND}` to write it") unless File.exist?(path)

        result = Backend.check_workflow_types(File.read(path), client: QubeRails.client, source: source, path: RUBY,
                                                               command: COMMAND, client_expression: CLIENT)
        warn_each(result.warnings)
        case result.status
        when :current then say_status :current, result.message, :green
        when :unreachable then say_status :warning, result.message, :yellow
        else fail_with(result.message)
        end
      end

      def source
        "#{QubeRails.config.base_url.to_s.sub(%r{/+\z}, '')}/api/v2/workflows/types"
      end

      def warn_each(warnings)
        warnings.each { |warning| say_status :warning, warning, :yellow }
      end

      # A failing check stops the command with status 1, so CI fails.
      def fail_with(message)
        say_status :error, message, :red
        exit 1
      end
    end
  end
end
