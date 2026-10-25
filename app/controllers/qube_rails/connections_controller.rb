# frozen_string_literal: true

module QubeRails
  # Connects a customer's QuickBooks Desktop. QuBe Sync hosts the setup and walks them through
  # the Web Connector, on the computer where QuickBooks is installed, and tells your app how it
  # went by webhook (your connection class, a QubeRails::ConnectionEvents):
  # connection.connected, or connection.setup_cancelled.
  #
  # Behind your sign-in, as your ApplicationController (config.parent_controller) is: create
  # keeps the connection on the signed-in customer's account (config.current_account).
  class ConnectionsController < QubeRails.config.parent_controller.constantize
    # POST /quickbooks/connect, from a "Connect QuickBooks Desktop" button. Best clicked on the
    # computer where QuickBooks is installed. Until connection.connected comes, show the account
    # as waiting for QuickBooks: the setup doesn't come back here.
    def create
      account = QubeRails.config.current_account.call(self)
      unless account
        QubeRails.logger.warn("QuBe Sync: refused a connect: config.current_account found no " \
                              "signed-in account")
        return head(:unauthorized)
      end

      connection = QubeRails.config.connection_class.new(account)
      # Where QuBe Sync says the connection is set up (connection.connected): your connection
      # class, by this account's id.
      webhook_url = connection.webhook_url
      connection_id = connection.saved_connection_id
      if connection_id
        # Connected before: the same connection, its webhook URL brought up to date, with a fresh
        # link.
        QubeRails.client.update_connection(connection_id, webhook_url: webhook_url)
        made = QubeRails.client.regenerate_onboarding(connection_id)
      else
        made = QubeRails.client.create_connection(webhook_url: webhook_url)
        connection.save_connection_id(made["id"])
      end

      # 303, so the browser follows the POST with a GET.
      redirect_to made.dig("links", "onboarding"), allow_other_host: true, status: :see_other
    end
  end
end
