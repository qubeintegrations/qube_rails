class <%= @scope_prefix %>QubeConnectionsController < ApplicationController
  def create
    # Check if connection already exists
    if <%= @connection_parent %>.qube_connection.present?
      redirect_to <%= @connection_parent %>.qube_connection.onboarding_url || root_path, 
                  alert: "QuickBooks connection already exists."
      return
    end

    response = QubeSync.create_connection(redirect_url: callback_qube_connections_url)
    <%= @connection_parent %>.create_qube_connection!(
      qube_id: response["id"], 
      onboarding_url: response.dig("links", "onboarding"),
      is_connected: false
    )

    redirect_to connection.onboarding_url, allow_other_host: true, status: :see_other
  end

  def destroy
    return redirect_to root_path, alert: "No connection found." unless connection

    if QubeRails.delete_connection(connection.qube_id)
      connection.destroy
      redirect_to after_qbd_disconnect_path(<%= @connection_parent %>), notice: "Successfully disconnected from QuickBooks Desktop!"
    else
      redirect_to :back, alert: "Failed to disconnect from QuickBooks Desktop. Please try again."
    end
  end

  def onboarding
    return redirect_to root_path, alert: "No connection found." unless connection

    redirect_to QubeRails.regenerate_onboarding_url(connection.qube_id), allow_other_host: true
  end

  def callback
    return redirect_to root_path, alert: "No connection found." unless connection

    case params[:state]
    when "connected"
      connection.connect!
      
      redirect_to after_qbd_connected_path(<%= @connection_parent %>), notice: "Successfully connected to QuickBooks Desktop!"
    
    when "cancelled"
      QubeRails.delete_connection(connection.qube_id) 
      connection.destroy

      redirect_to after_qbd_setup_cancelled_path(<%= @connection_parent %>), notice: "QuickBooks connection setup was cancelled."
    
    when "expired"
      redirect_to QubeRails.regenerate_onboarding_url(params[:connection_id]), allow_other_host: true
    end
  end

  private

  def connection
    @connection ||= <%= @connection_parent %>.qube_connection
  end

  def after_qbd_setup_path(<%= options[:parent_model].underscore %>)
    root_path
  end

  alias after_qbd_connected_path after_qbd_setup_path
  alias after_qbd_disconnect_path after_qbd_setup_path
  alias after_qbd_setup_cancelled_path after_qbd_setup_path
  alias after_qbd_expired_path after_qbd_setup_path
end