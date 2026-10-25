# frozen_string_literal: true

module QubeRails
  # Connects a customer's QuickBooks Desktop. QuBe Sync hosts the setup and walks them through
  # the Web Connector, on the computer where QuickBooks is installed, and tells the connection
  # how it went by webhook (QubeRails::ConnectionEvents, then your config.connection_events
  # class): connection.connected, or connection.setup_cancelled.
  #
  # An account can have any number of connections (a company file each), so each is its own row
  # (QubeRails::Connection), owned by the signed-in account (config.current_account). Behind
  # your sign-in, as your ApplicationController (config.parent_controller) is.
  class ConnectionsController < QubeRails.config.parent_controller.constantize
    # POST /quickbooks/connections, from a "Connect QuickBooks Desktop" button, with an optional
    # name. Best clicked on the computer where QuickBooks is installed. The row is written first,
    # so the connection's webhook URL names it; if QuBe Sync doesn't answer, the row is left
    # without a qube_id and its onboarding route tries again. Until connection.connected comes,
    # show it as waiting for QuickBooks: the setup doesn't come back here.
    def create
      account = signed_in_account
      return head(:unauthorized) unless account

      connection = QubeRails::Connection.create!(owner: account, name: connection_name, status: "pending")
      send_to_setup(connection)
    end

    # POST /quickbooks/connections/:id/onboarding: sends one of the signed-in account's
    # connections back through setup (a new company file, a Web Connector set up again), with its
    # webhook URL brought up to date. Another account's connection answers 404.
    def onboarding
      account = signed_in_account
      return head(:unauthorized) unless account

      connection = QubeRails::Connection.owned_by(account).find_by(id: params[:id])
      return head(:not_found) unless connection

      send_to_setup(connection)
    end

    private

    def signed_in_account
      account = QubeRails.config.current_account.call(self)
      unless account
        QubeRails.logger.warn("QuBe Sync: refused a connect: config.current_account found no signed-in account")
      end
      account
    end

    def connection_name
      name = params[:name].to_s.strip
      name.empty? ? nil : name[0, 255]
    end

    def send_to_setup(connection)
      if connection.qube_id
        QubeRails.client.update_connection(connection.qube_id, webhook_url: connection.webhook_url)
        made = QubeRails.client.regenerate_onboarding(connection.qube_id)
      else
        made = QubeRails.client.create_connection(webhook_url: connection.webhook_url, name: connection.name)
        connection.update!(qube_id: made["id"])
      end

      # 303, so the browser follows the POST with a GET.
      redirect_to made.dig("links", "onboarding"), allow_other_host: true, status: :see_other
    end
  end
end
