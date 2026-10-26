# frozen_string_literal: true

require_relative "lib/qube_rails/version"

Gem::Specification.new do |spec|
  spec.name = "qube_rails"
  spec.version = QubeRails::VERSION
  spec.authors = ["Garrett Lancaster"]
  spec.email = ["support@qubesync.com"]
  spec.homepage = "https://qubesync.com"
  spec.summary = "QuBe Sync's Rails engine: the webhook endpoint, onboarding and question routes " \
                 "for QuickBooks Desktop"
  spec.description = "The code every Rails app's QuBe Sync integration shares: the webhook endpoint " \
                     "and its job, onboarding, the question routes and partial, and the Operation " \
                     "and ConnectionEvents bases. Your app keeps its own operations, its connection " \
                     "class and one initializer."
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://docs.qubesync.com"
  spec.metadata["source_code_uri"] = "https://github.com/qubeintegrations/qube_rails"
  spec.metadata["changelog_uri"] = "https://github.com/qubeintegrations/qube_rails/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].reject do |f|
      File.directory?(f) || File.basename(f) == ".DS_Store"
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "qube_sync", ">= 0.4.0"
  spec.add_dependency "railties", ">= 7.0"
  # QubeRails::WebhookJob, the default enqueue, is an ActiveJob job.
  spec.add_dependency "activejob", ">= 7.0"
end
