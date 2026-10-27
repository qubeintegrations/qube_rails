# frozen_string_literal: true

Rails.application.routes.draw do
  mount QubeRails::Engine => "/"

  get "invoices/:id", to: "invoices#show", as: :invoice
  get "account", to: "accounts#show"
end
