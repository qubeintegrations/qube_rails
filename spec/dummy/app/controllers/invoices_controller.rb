# frozen_string_literal: true

class InvoicesController < ApplicationController
  def show
    @invoice = current_account.invoices.find(params[:id])
  end
end
