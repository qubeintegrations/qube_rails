# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "generators/qube_rails/install_generator"

RSpec.describe QubeRails::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def generate(*args)
    capture = StringIO.new
    $stdout = capture
    described_class.start(args, destination_root: @root)
  ensure
    $stdout = STDOUT
  end

  def read(path)
    File.read(File.join(@root, path))
  end

  def compiles(source)
    RubyVM::InstructionSequence.compile(source)
    true
  end

  it "writes the initializer with every setting, commented" do
    generate

    initializer = read("config/initializers/qube_rails.rb")
    %w[operations connection current_account authorize_question enqueue queue dedupe parent_controller
       api_key base_url webhook_secret webhook_url].each do |setting|
      expect(initializer).to include("config.#{setting}")
    end
    expect(initializer).to include('config.connection = "QuickbooksDesktop::Connection"')
    expect(initializer).to include("# config.authorize_question")
    expect(compiles(initializer)).to be(true)
  end

  it "writes the connection class with find_record and the four handlers" do
    generate

    connection = read("app/services/quickbooks_desktop/connection.rb")
    expect(connection).to include("class Connection < QubeRails::ConnectionEvents", "Account.find(id)")
    %w[connected setup_cancelled stalled resumed].each do |handler|
      expect(connection).to include("def #{handler}(event)\n      log_event(event)")
    end
    expect(compiles(connection)).to be(true)
  end

  it "writes the migration for accounts by default, and mounts the engine" do
    generate

    migration = Dir[File.join(@root, "db/migrate/*_add_qube_connection_to_accounts.rb")].first
    expect(migration).not_to be_nil
    source = File.read(migration)
    expect(source).to include("class AddQubeConnectionToAccounts < ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]")
    expect(source).to include("add_column :accounts, :qube_connection_id, :string",
                              "add_column :accounts, :qube_connection_revision, :integer")
    expect(compiles(source)).to be(true)
    expect(read("config/routes.rb")).to include('mount QubeRails::Engine => "/"')
  end

  it "takes the table as an argument" do
    generate("organizations")

    expect(Dir[File.join(@root, "db/migrate/*_add_qube_connection_to_organizations.rb")]).not_to be_empty
    expect(read("app/services/quickbooks_desktop/connection.rb")).to include("Organization.find(id)")
    expect(read("config/initializers/qube_rails.rb")).to include("record.organization_id")
  end

  it "writes a migration that runs" do
    generate("widgets")
    ActiveRecord::Base.connection.create_table(:widgets, force: true)
    load Dir[File.join(@root, "db/migrate/*_add_qube_connection_to_widgets.rb")].first
    AddQubeConnectionToWidgets.new.migrate(:up)

    columns = ActiveRecord::Base.connection.columns(:widgets).map { |c| [c.name, c.type] }
    expect(columns).to include(["qube_connection_id", :string], ["qube_connection_revision", :integer])
  ensure
    ActiveRecord::Base.connection.drop_table(:widgets, if_exists: true)
  end
end
