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
    # name. Best clicked on the computer where QuickBooks is installed. It sends the account's
    # newest connection that has never connected (pending, or its setup cancelled) back through
    # setup, so clicking Connect again doesn't pile up connections; it makes a new one when the
    # account has none, or with new=1 (a "Connect another company file" button). A new row is
    # written first, so the connection's webhook URL names it; if QuBe Sync doesn't answer, the
    # row is left without a qube_id and the next click picks it up. Until connection.connected
    # comes, show it as waiting for QuickBooks: the setup doesn't come back here.
    #
    # With simulated=1, outside production, it connects a simulated QuickBooks company file
    # instead, for testing with no Windows computer: a new row whose QuBe Sync connection is
    # connected as it's made, so connection.connected comes at once, and back to the page the
    # button was on rather than to setup.
    def create
      account = signed_in_account
      return head(:unauthorized) unless account
      return connect_simulated(account) if simulated_requested?

      connection = QubeRails::Connection.owned_by(account).never_connected.first unless params[:new].to_s == "1"
      return send_to_setup(connection) if connection

      send_to_setup(QubeRails::Connection.create!(owner: account, name: connection_name, status: "pending"),
                    fresh: true)
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

    RUNS_GOING = "It has a run or request that hasn't ended: wait for it, or answer its question, first."
    NO_ANSWER = "QuBe Sync didn't answer: try disconnecting again in a minute."

    # DELETE /quickbooks/connections/:id: disconnects one of the signed-in account's
    # connections. QuBe Sync deletes its connection (the Web Connector stops syncing that
    # company file), then the row goes, with its runs and its QuickBooks links. Refused while a
    # run hasn't ended. Another account's connection answers 404.
    def destroy
      account = signed_in_account
      return head(:unauthorized) unless account

      connection = QubeRails::Connection.owned_by(account).find_by(id: params[:id])
      return head(:not_found) unless connection
      return back_with_error(RUNS_GOING) if work_going?(connection)

      delete_on_qube(connection)
      connection.disconnect!
      redirect_back fallback_location: "/", status: :see_other
    rescue *QubeRails::Backend::NETWORK_ERRORS
      back_with_error(NO_ANSWER)
    end

    private

    def work_going?(connection)
      connection.runs.where.not(state: QubeRails::Run::ENDED_STATES).exists? ||
        connection.queued_requests.where(ended_at: nil).exists?
    end

    # Already gone there (404) is gone.
    def delete_on_qube(connection)
      return if connection.qube_id.to_s.empty?

      QubeRails.client.delete_connection(connection.qube_id)
    rescue QubeRails::Backend::APIError => e
      raise unless e.status == 404
    end

    # The engine's partials show the message once.
    def back_with_error(message)
      flash[:qube_rails_error] = message
      redirect_back fallback_location: "/", status: :see_other
    end

    def signed_in_account
      account = QubeRails.config.current_account.call(self)
      unless account
        QubeRails.logger.warn("QuBe Sync: refused a connect: config.current_account found no signed-in account")
      end
      account
    end

    def simulated_requested?
      params[:simulated].to_s == "1"
    end

    # Never in production: a customer's user can't make a connection to a fake company file.
    def connect_simulated(account)
      return head(:not_found) if Rails.env.production?

      connection = QubeRails::Connection.create!(owner: account, name: connection_name, status: "pending")
      made = QubeRails.client.create_connection(webhook_url: connection.webhook_url, name: connection.name,
                                                type: "simulated")
      connection.update!(qube_id: made["id"])
      redirect_back fallback_location: "/", status: :see_other
    end

    def connection_name
      name = params[:name].to_s.strip
      name.empty? ? nil : name[0, 255]
    end

    # fresh: a row this request wrote, which no earlier create can have been made for.
    def send_to_setup(connection, fresh: false)
      # An earlier create that landed before its id was saved: that connection, not a second one.
      connection.adopt_qube_connection if !fresh && connection.qube_id.to_s.empty?
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
