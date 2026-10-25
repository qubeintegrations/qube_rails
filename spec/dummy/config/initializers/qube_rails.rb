# frozen_string_literal: true

# The dummy app's settings. spec/support/qube_rails.rb sets them again before each example,
# after QubeRails.reset!, so an example can unset one.
QubeRails.configure do |config|
  config.operations = { "create_invoice" => "QuickbooksDesktop::CreateInvoice" }
  config.connection = "QuickbooksDesktop::Connection"
end
