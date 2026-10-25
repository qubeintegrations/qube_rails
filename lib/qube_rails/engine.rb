require 'rails/engine'

module QubeRails
  class Engine < Rails::Engine
    isolate_namespace QubeRails

    config.generators do |g|
      g.test_framework :rspec, fixture: false
      g.assets false
      g.helper false
    end

    initializer "qube_rails.configure" do
      QubeRails.config.configure_qube_sync! if QubeRails.config.api_key
    end

    initializer "qube_rails.load_models" do
      Dir[File.join(__dir__, "../app/models/**/*.rb")].each { |file| require file }
    end
  end
end