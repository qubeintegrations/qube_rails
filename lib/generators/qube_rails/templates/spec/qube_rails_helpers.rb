require 'rails_helper'

module QubeRailsHelpers
  # Test helper methods for QubeRails testing
  def create_qube_connection(<%= options[:parent_model].underscore %>: nil, attributes: {})
    <%= options[:parent_model].underscore %> ||= create(:<%= options[:parent_model].underscore %>) # Assumes you have a <%= options[:parent_model].underscore %> factory
    
    default_attributes = {
      qb_company_name: 'Test Company',
      qb_company_file: 'TestCompany.qbw',
      webhook_secret: SecureRandom.hex(32),
      is_connected: true,
      last_sync_at: Time.current
    }

    <%= options[:parent_model].underscore %>.create_qube_connection!(default_attributes.merge(attributes))
  end

  def create_qbd_customer(connection: nil, attributes: {})
    connection ||= create_qube_connection
    
    default_attributes = {
      qb_id: SecureRandom.hex(8),
      name: 'Test Customer',
      full_name: 'Test Customer Inc.',
      company_name: 'Test Customer Inc.',
      email: 'test@customer.com',
      phone: '555-0123',
      is_active: true
    }

    connection.customers.create!(default_attributes.merge(attributes))
  end

  def create_qbd_vendor(connection: nil, attributes: {})
    connection ||= create_qube_connection
    
    default_attributes = {
      qb_id: SecureRandom.hex(8),
      name: 'Test Vendor',
      company_name: 'Test Vendor LLC',
      email: 'vendor@test.com',
      phone: '555-0456',
      is_active: true
    }

    connection.vendors.create!(default_attributes.merge(attributes))
  end

  def create_qbd_item(connection: nil, attributes: {})
    connection ||= create_qube_connection
    
    default_attributes = {
      qb_id: SecureRandom.hex(8),
      name: 'Test Item',
      full_name: 'Test Item',
      item_type: 'inventory',
      sales_price: 100.00,
      purchase_cost: 50.00,
      quantity_on_hand: 10,
      is_active: true
    }

    connection.items.create!(default_attributes.merge(attributes))
  end

  def create_qbd_invoice(connection: nil, customer: nil, attributes: {})
    connection ||= create_qube_connection
    customer ||= create_qbd_customer(connection: connection)
    
    default_attributes = {
      qb_id: SecureRandom.hex(8),
      customer: customer,
      txn_date: Date.current,
      ref_number: "INV-#{rand(1000..9999)}",
      subtotal: 100.00,
      sales_tax_total: 8.00,
      applied_amount: 108.00,
      balance_remaining: 0.00
    }

    connection.invoices.create!(default_attributes.merge(attributes))
  end

  def create_qbd_invoice_line_item(invoice: nil, item: nil, attributes: {})
    invoice ||= create_qbd_invoice
    item ||= create_qbd_item(connection: invoice.qube_connection)
    
    default_attributes = {
      item: item,
      description: item.name,
      quantity: 1,
      rate: item.sales_price,
      amount: item.sales_price
    }

    invoice.line_items.create!(default_attributes.merge(attributes))
  end

  def stub_qube_sync_request(method, response = {})
    default_response = { success: true, data: {} }
    allow(QubeRails).to receive(method).and_return(default_response.merge(response))
  end

  def mock_webhook_data(type, data = {})
    base_data = {
      'connection_id' => 1,
      'data' => [data]
    }

    case type
    when :customer
      base_data['data'] = [customer_webhook_data.merge(data)]
    when :vendor
      base_data['data'] = [vendor_webhook_data.merge(data)]
    when :item
      base_data['data'] = [item_webhook_data.merge(data)]
    when :invoice
      base_data['data'] = [invoice_webhook_data.merge(data)]
    end

    base_data
  end

  private

  def customer_webhook_data
    {
      'ListID' => SecureRandom.hex(8),
      'Name' => 'Webhook Customer',
      'FullName' => 'Webhook Customer Inc.',
      'CompanyName' => 'Webhook Customer Inc.',
      'Email' => 'webhook@customer.com',
      'Phone' => '555-0789',
      'IsActive' => true,
      'Balance' => '1250.00',
      'TotalBalance' => '1250.00'
    }
  end

  def vendor_webhook_data
    {
      'ListID' => SecureRandom.hex(8),
      'Name' => 'Webhook Vendor',
      'CompanyName' => 'Webhook Vendor LLC',
      'Email' => 'webhook@vendor.com',
      'Phone' => '555-0321',
      'IsActive' => true,
      'Balance' => '500.00'
    }
  end

  def item_webhook_data
    {
      'ListID' => SecureRandom.hex(8),
      'Name' => 'Webhook Item',
      'FullName' => 'Webhook Item',
      'IsActive' => true,
      'SalesPrice' => '75.00',
      'PurchaseCost' => '40.00',
      'QuantityOnHand' => '25'
    }
  end

  def invoice_webhook_data
    {
      'TxnID' => SecureRandom.hex(8),
      'RefNumber' => "WH-#{rand(1000..9999)}",
      'TxnDate' => Date.current.strftime('%Y-%m-%d'),
      'Subtotal' => '200.00',
      'SalesTaxTotal' => '16.00',
      'TotalAmount' => '216.00',
      'BalanceRemaining' => '0.00'
    }
  end
end

# Include helpers in RSpec
RSpec.configure do |config|
  config.include QubeRailsHelpers, type: :model
  config.include QubeRailsHelpers, type: :controller
  config.include QubeRailsHelpers, type: :request
  config.include QubeRailsHelpers, type: :job
end