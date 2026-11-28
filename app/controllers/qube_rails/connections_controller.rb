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
    # type is "realtime" or "standard" (default config.connection_type); any other answers 422.
    # Only a never-connected connection of that type is sent back through setup; one no event has
    # typed yet is asked about first (a pre-0.2.1 row the migration labelled realtime).
    #
    # With simulated=1, outside production, it connects a simulated QuickBooks company file
    # instead, for testing with no Windows computer: a new row whose QuBe Sync connection is
    # connected as it's made, so connection.connected comes at once, and back to the page the
    # button was on rather than to setup.
    def create
      account = signed_in_account
      return head(:unauthorized) unless account
      return connect_simulated(account) if simulated_requested?

      type = requested_type
      return head(:unprocessable_entity) unless type

      unless params[:new].to_s == "1"
        connection = QubeRails::Connection.owned_by(account).never_connected.find_by(connection_type: type) ||
                     untyped_never_connected(account, type)
      end
      return send_to_setup(connection) if connection

      send_to_setup(QubeRails::Connection.create!(owner: account, name: connection_name, status: "pending",
                                                  connection_type: type), fresh: true)
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

    # POST /quickbooks/connections/:id/company_file: sends the customer to switch one of the
    # signed-in account's connections to another company file (its links.company_file, renewed
    # as onboarding's is). QuBe Sync then sends connection.company_file_changed. A simulated
    # connection, or one QuBe Sync never answered, answers 404, as another account's does.
    def company_file
      account = signed_in_account
      return head(:unauthorized) unless account

      connection = QubeRails::Connection.owned_by(account).find_by(id: params[:id])
      return head(:not_found) if connection.nil? || connection.qube_id.to_s.empty? || connection.simulated?

      send_to_setup(connection, link: "company_file")
    end

    # POST /quickbooks/connections/:id/links/:link_id/confirm and /reject, from the review_links
    # partial: one of the signed-in account's connections' links under review is the same record
    # (Connection#confirm_link) or not (#reject_link), then back to the page. One settled already (a
    # second click) goes back as it is. Another account's connection, or a link not on it, is 404.
    def confirm_link
      settle_link(:confirm_link)
    end

    def reject_link
      settle_link(:reject_link)
    end

    # What the page says when it can't, as I18n keys under qube_rails (config/locales/en.yml).
    RUNS_GOING = :"errors.still_syncing"
    NO_ANSWER = :"errors.disconnect_unreachable"

    # DELETE /quickbooks/connections/:id: disconnects one of the signed-in account's
    # connections. QuBe Sync deletes its connection (the Web Connector stops syncing that
    # company file), then the row goes, with its runs and its QuickBooks links. Refused while a
    # run or request hasn't ended (the engine's link checks aside). Another account's connection answers 404.
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

    # The engine's own link checks don't count: they go with the connection.
    def work_going?(connection)
      prefix = "#{QubeRails::QueuedRequest.sanitize_sql_like(QubeRails::LinkCheck::SLUG_PREFIX)}%"
      not_checks = QubeRails::QueuedRequest.arel_table[:operation].does_not_match(prefix, "\\", true)
      connection.runs.where.not(state: QubeRails::Run::ENDED_STATES + %w[realtime_required]).exists? ||
        connection.queued_requests.where(ended_at: nil).where(not_checks).exists?
    end

    def settle_link(how)
      account = signed_in_account
      return head(:unauthorized) unless account

      connection = QubeRails::Connection.owned_by(account).find_by(id: params[:id])
      link = connection&.quickbooks_records&.find_by(id: params[:link_id])
      return head(:not_found) unless link

      begin
        connection.public_send(how, link) if link.under_review?
      rescue ArgumentError # settled meanwhile (a second click, another tab)
        nil
      end
      QubeRails.broadcast_refresh(link.record) if link.record
      redirect_back fallback_location: "/", status: :see_other
    end

    # Already gone there (404) is gone.
    def delete_on_qube(connection)
      return if connection.qube_id.to_s.empty?

      QubeRails.client.delete_connection(connection.qube_id)
    rescue QubeRails::Backend::APIError => e
      raise unless e.status == 404
    end

    # The engine's partials show the message once.
    def back_with_error(key)
      flash[:qube_rails_error] = QubeRails.t(key)
      redirect_back fallback_location: "/", status: :see_other
    end

    def signed_in_account
      account = QubeRails.config.current_account.call(self)
      unless account
        QubeRails.logger.warn("QuBe Sync: refused a connect: config.current_account found no signed-in account")
      end
      account
    end

    # The type param, else config.connection_type; nil for anything but realtime or standard.
    def requested_type
      type = params[:type].to_s
      return QubeRails.config.connection_type if type.empty?

      %w[realtime standard].include?(type) ? type : nil
    end

    def simulated_requested?
      params[:simulated].to_s == "1"
    end

    # Never in production: a customer's user can't make a connection to a fake company file.
    def connect_simulated(account)
      return head(:not_found) if Rails.env.production?

      connection = QubeRails::Connection.create!(owner: account, name: connection_name, status: "pending",
                                                 connection_type: "simulated")
      made = QubeRails.client.create_connection(webhook_url: connection.webhook_url, name: connection.name,
                                                type: "simulated")
      connection.update!(qube_id: made["id"])
      redirect_back fallback_location: "/", status: :see_other
    end

    # How many never-connected rows of another type Connect asks QuBe Sync about.
    UNTYPED_LOOKUPS = 3

    # A never-connected row no event has typed (revision nil) whose type QuBe Sync says is type:
    # a row from before 0.2.1, which the migration labelled realtime. Each lookup is short (the
    # quick client), the first that gets no answer ends them, and one checked isn't asked again.
    def untyped_never_connected(account, type)
      rows = QubeRails::Connection.owned_by(account).never_connected.where(revision: nil)
                                  .where.not(connection_type: [type, "simulated"]).where.not(qube_id: nil)
      rows.limit(UNTYPED_LOOKUPS).each do |row|
        return row if row.refresh_type!(client: QubeRails.quick_client, remember: true) == type
      rescue QubeRails::Backend::APIError, *QubeRails::Backend::NETWORK_ERRORS => e
        QubeRails.logger.warn("QuBe Sync: couldn't read connection #{row.id}'s type (#{e.class}); not reusing it")
        return nil if !e.is_a?(QubeRails::Backend::APIError) # no more waiting on QuBe Sync for this click
      end
      nil
    end

    def connection_name
      name = params[:name].to_s.strip
      name.empty? ? nil : name[0, 255]
    end

    # fresh: a row this request wrote, which no earlier create can have been made for. link: the
    # connection's link to send them to, else its onboarding (a page QuBe Sync has no link for).
    def send_to_setup(connection, fresh: false, link: "onboarding")
      # An earlier create that landed before its id was saved: that connection, not a second one.
      connection.adopt_qube_connection if !fresh && connection.qube_id.to_s.empty?
      if connection.qube_id
        QubeRails.client.update_connection(connection.qube_id, webhook_url: connection.webhook_url)
        made = QubeRails.client.regenerate_onboarding(connection.qube_id)
      else
        made = QubeRails.client.create_connection(webhook_url: connection.webhook_url, name: connection.name,
                                                  type: connection.connection_type)
        connection.update!(qube_id: made["id"])
      end

      # 303, so the browser follows the POST with a GET.
      target = made.dig("links", link) || made.dig("links", "onboarding")
      redirect_to target, allow_other_host: true, status: :see_other
    end
  end
end
