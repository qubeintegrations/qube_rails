# frozen_string_literal: true

# A stand-in for an app's sign-in: the X-Account header names the signed-in account.
class ApplicationController < ActionController::Base
  before_action :require_sign_in

  def current_account
    @current_account ||= Account.find_by(id: request.headers["X-Account"])
  end

  private

  def require_sign_in
    head :unauthorized unless current_account
  end
end
