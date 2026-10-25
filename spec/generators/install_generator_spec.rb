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

  let(:commands) { [] }

  # rails_command is stubbed on the instance: it would boot an app in the temporary directory.
  def generate
    $stdout = StringIO.new
    generator = described_class.new([], {}, destination_root: @root)
    ran = commands
    allow(generator).to receive(:rails_command) { |command| ran << command }
    generator.invoke_all
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
    %w[operations connection_events current_account authorize_question enqueue queue job_attempts dedupe
       parent_controller api_key base_url webhook_secret webhook_url].each do |setting|
      expect(initializer).to include("config.#{setting}")
    end
    expect(initializer).to include('config.connection_events = "QuickbooksDesktop::ConnectionEvents"',
                                   "# config.authorize_question = ->(controller, record, run)")
    expect(compiles(initializer)).to be(true)
  end

  it "writes the app's ConnectionEvents class with the four handlers" do
    generate

    source = read("app/services/quickbooks_desktop/connection_events.rb")
    expect(source).to include("class ConnectionEvents < QubeRails::ConnectionEvents")
    %w[connected setup_cancelled stalled resumed].each do |handler|
      expect(source).to include("def #{handler}(event)\n      log_event(event)")
    end
    expect(compiles(source)).to be(true)
  end

  it "copies the engine's migrations and mounts the engine" do
    generate

    expect(commands).to eq(["qube_rails:install:migrations"])
    expect(read("config/routes.rb")).to include('mount QubeRails::Engine => "/"')
    expect(Dir[File.join(@root, "db/migrate/*")]).to be_empty # nothing on the app's own tables
  end

  it "has the engine's install:migrations task to run" do
    Rails.application.load_tasks
    expect(Rake::Task.task_defined?("qube_rails:install:migrations")).to be(true)
  end
end
