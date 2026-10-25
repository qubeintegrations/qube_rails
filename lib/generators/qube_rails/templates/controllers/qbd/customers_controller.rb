module QBD
  class CustomersController < ApplicationController
    before_action :set_connection
    before_action :set_customer, only: [:show, :destroy]

    def index
      @customers = @connection.customers.includes(:qube_connection).order(:name)
    end

    def show
    end

    def destroy
      @customer.destroy!
      redirect_to qbd_customers_path, notice: 'Customer was successfully deleted.'
    end

    private

    def set_connection
      @connection = current_<%= options[:parent_model].underscore %>.qube_connection
      redirect_to root_path, alert: 'No QuickBooks connection found.' unless @connection
    end

    def set_customer
      @customer = @connection.customers.find(params[:id])
    end
  end
end