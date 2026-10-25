# frozen_string_literal: true

require_relative "lib/qube_rails/version"

Gem::Specification.new do |spec|
  spec.name        = "qube_rails"
  spec.version     = QubeRails::VERSION
  spec.authors     = ["QUBE Team"]
  spec.email       = ["support@qubesync.com"]
  spec.homepage    = "https://github.com/qube-labs/qube_rails"
  spec.summary     = "Rails integration for QuickBooks Desktop via QUBE Sync"
  spec.description = "A Rails gem that provides easy integration with QuickBooks Desktop through the QUBE Sync platform. Includes models, controllers, and utilities for managing QuickBooks data in Rails applications."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/qube-labs/qube_rails"
  spec.metadata["changelog_uri"] = "https://github.com/qube-labs/qube_rails/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{lib}/**/*", "README.md", "LICENSE.txt"]
  end

  # Core dependencies
  spec.add_dependency "rails", ">= 6.1.0"
  spec.add_dependency "qube_sync", path: "../qube_sync_rb"

  # Development dependencies
  spec.add_development_dependency "rspec-rails", "~> 6.0"
  spec.add_development_dependency "factory_bot_rails", "~> 6.2"
  spec.add_development_dependency "faker", "~> 3.0"
  spec.add_development_dependency "sqlite3", "~> 1.4"
  spec.add_development_dependency "pry", "~> 0.14"
  spec.add_development_dependency "rubocop", "~> 1.50"
  spec.add_development_dependency "rubocop-rails", "~> 2.19"

  spec.require_paths = ["lib"]
end
