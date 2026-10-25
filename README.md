# QUBE Rails Integration

[![Gem Version](https://badge.fury.io/rb/qube_rails.svg)](https://badge.fury.io/rb/qube_rails)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Rails gem that provides seamless integration with QUBE Sync for QuickBooks Desktop connectivity, data synchronization, and invoice management.

## Features

- 🔗 **Easy QuickBooks Desktop Integration** - Connect your Rails app to QuickBooks Desktop through QUBE Sync
- 📊 **Data Synchronization** - Import customers, vendors, and items from QuickBooks Desktop
- 🧾 **Invoice Management** - Create and send invoices to QuickBooks Desktop
- 🎣 **Webhook Handling** - Built-in webhook processing for real-time updates
- 🎨 **UI Components** - Pre-built views and controllers for seamless user experience
- ⚡ **Rails Generators** - Automatic setup with Rails generators

## Requirements

- Ruby >= 2.7.0
- Rails >= 6.0
- QuickBooks Desktop (for end users)
- QUBE Sync account and API credentials

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'qube_rails'
```

And then execute:

```bash
$ bundle install
```

## Quick Start

### 1. Generate Base Components

Generate the core models and controllers:

```bash
rails generate qube_rails:install
```

**For custom parent models (User, Team, etc.):**
```bash
rails generate qube_rails:install --parent_model=User
```

This creates:
- `Qube::Connection` model for managing QuickBooks connections
- `Qube::Request` model for tracking API requests
- `QubeConnectionsController` for connection management
- Database migrations
- Routes configuration

**Important:** Ensure your parent model (Account, User, Team, etc.) exists before running the generator. The generator will create a foreign key to your specified model.

### 2. Add Association to Parent Model

Add the QuickBooks connection association to your parent model:

```ruby
# app/models/account.rb (or User, Team, etc.)
class Account < ApplicationRecord
  has_one :qube_connection, class_name: 'Qube::Connection', dependent: :destroy
end
```

### 3. Configuration

Create an initializer to configure your QUBE Sync credentials:

```ruby
# config/initializers/qube_sync.rb
QubeSyncRails.configure do |config|
  config.api_key = ENV['QUBE_API_KEY']
  config.webhook_secret = ENV['QUBE_WEBHOOK_SECRET']
  config.base_url = 'https://api.qubesync.com' # Optional, defaults to production
end
```

### 4. Add Routes

Add the QuickBooks connection routes to your application:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  resources :qube_connections, only: [:create, :destroy] do
    get :callback, on: :collection
    get :onboarding, on: :member
  end

  namespace :qbd do
    resources :customers
    resources :vendors  
    resources :items
    resources :invoices do
      member do
        patch :send_to_quickbooks
      end
    end
    
    post "/imports" => "imports#create"
    post "/imports/customers/webhook" => "imports#customers_webhook"
    post "/imports/vendors/webhook" => "imports#vendors_webhook"
    post "/imports/items/webhook" => "imports#items_webhook"
    post "/invoices/webhook" => "imports#invoice_add_webhook"
  end
end
```

### 4. Setup Account Association

Add the QuickBooks connection association to your user/account model:

```ruby
class Account < ApplicationRecord
  has_one :qube_connection, class_name: "Qube::Connection", dependent: :destroy
  
  def quickbooks_connected?
    qube_connection&.connected?
  end
end
```

## Usage

### Connecting to QuickBooks Desktop

#### In Your Controller
```ruby
class DashboardController < ApplicationController
  def show
    @connection = current_account.qube_connection
  end
end
```

#### In Your View
```erb
<% if @connection %>
  <% if @connection.pending? %>
    <p>Connection is pending. Please complete the setup.</p>
    <%= button_to "Complete Setup", onboarding_qube_connection_path(@connection), 
          method: :get, class: "btn btn-primary" %>
  <% else %>
    <p>Connected to QuickBooks Desktop</p>
    <%= button_to "Disconnect", qube_connection_path(@connection), 
          method: :delete, class: "btn btn-danger",
          data: { confirm: "Are you sure?" } %>
  <% end %>
<% else %>
  <%= button_to "Connect to QuickBooks Desktop", qube_connections_path, 
        class: "btn btn-success" %>
<% end %>
```

### Data Import and Synchronization

#### Import Data from QuickBooks
```ruby
# In your controller
def start_imports
  connection = current_account.qube_connection
  
  # Start customer import
  response = QubeSync.customer_query(connection.qube_id, 
    iterate: true, 
    webhook_url: qbd_import_customers_webhook_url
  )
  connection.requests.create!(response.slice("state", "request_types")
    .merge("qube_id" => response["id"]))
  
  # Start vendor import  
  response = QubeSync.vendor_query(connection.qube_id,
    iterate: true,
    webhook_url: qbd_import_vendors_webhook_url
  )
  connection.requests.create!(response.slice("state", "request_types")
    .merge("qube_id" => response["id"]))
    
  # Start item import
  response = QubeSync.item_query(connection.qube_id,
    iterate: true, 
    webhook_url: qbd_import_items_webhook_url
  )
  connection.requests.create!(response.slice("state", "request_types")
    .merge("qube_id" => response["id"]))
    
  redirect_to dashboard_path, notice: "Import started!"
end
```

#### Access Imported Data
```ruby
connection = current_account.qube_connection

# Get customers
customers = connection.customers.where(is_active: true)

# Get vendors  
vendors = connection.vendors.where(is_active: true)

# Get items
items = connection.items.where(is_active: true)
```

### Invoice Management

#### Create New Invoice
```ruby
# In your controller
def new
  @invoice = @connection.invoices.build
  @invoice.invoice_line_items.build
  @customers = @connection.customers.where(is_active: true)
  @items = @connection.items.where(is_active: true)
end

def create
  @invoice = @connection.invoices.build(invoice_params)
  @invoice.customer = @connection.customers.find(params[:qbd_invoice][:customer_id])

  if @invoice.save
    redirect_to qbd_invoice_path(@invoice), notice: 'Invoice created successfully.'
  else
    render :new, status: :unprocessable_entity
  end
end
```

#### Send Invoice to QuickBooks
```ruby
def send_to_quickbooks
  if @invoice.draft?
    invoice_data = @invoice.to_quickbooks_format
    
    begin
      response = QubeSync.invoice_add(@connection.qube_id, invoice_data, 
        webhook_url: qbd_invoice_add_webhook_url)
      
      @connection.requests.create!(
        qube_id: response["id"],
        state: response["state"],
        request_types: response["request_types"] || ["invoice_add"],
        request_json: { invoice_id: @invoice.id, invoice_data: invoice_data }
      )
      
      @invoice.update(status: 'sent')
      redirect_to qbd_invoice_path(@invoice), 
        notice: 'Invoice is being sent to QuickBooks.'
    rescue => e
      redirect_to qbd_invoice_path(@invoice), 
        alert: 'Failed to send invoice to QuickBooks.'
    end
  end
end
```

### Webhook Handling

The gem provides built-in webhook handlers for processing QuickBooks responses:

```ruby
class QBD::ImportsController < ApplicationController
  skip_before_action :verify_authenticity_token, 
    only: [:customers_webhook, :vendors_webhook, :items_webhook, :invoice_add_webhook]

  def customers_webhook
    body = request.body.read
    signature = request.headers["X-Qube-Signature"]
    data = QubeSync.verify_and_build_webhook!(body, signature)
    
    QBDCustomerQueryWebhookJob.perform_later(data)
    head :ok
  end
  
  # Similar methods for vendors_webhook, items_webhook, invoice_add_webhook
end
```

### Background Jobs

Create background jobs to process webhook responses:

```ruby
class QBDCustomerQueryWebhookJob < ApplicationJob
  queue_as :default

  def perform(data)
    request_record = Qube::Request.find_by(qube_id: data.fetch("id"))
    return unless request_record

    request_record.update(
      state: data.fetch("state"),
      response_json: data.fetch("response_json")
    )

    case data["error"]
    when nil
      process_customers(request_record, data)
    else
      handle_error(request_record, data["error"])
    end
  end

  private

  def process_customers(request_record, data)
    response_json = data.fetch("response_json")
    connection = request_record.qube_connection
    
    response_json.each do |response|
      customers_data = response.dig("QBXMLMsgsRs", "CustomerQueryRs", "CustomerRet")
      next unless customers_data
      
      Array.wrap(customers_data).each do |customer_data|
        # Process and save customer data
        connection.customers.find_or_create_by(list_id: customer_data["ListID"]) do |customer|
          customer.name = customer_data["Name"]
          customer.email = customer_data["Email"]
          # ... other fields
        end
      end
    end
  end
end
```

## Models

### Qube::Connection

Represents a connection between your application and a QuickBooks Desktop file.

```ruby
connection = Qube::Connection.find(1)
connection.pending?     # => true/false
connection.active?      # => true/false  
connection.customers    # => Associated customers
connection.vendors      # => Associated vendors
connection.items        # => Associated items
connection.invoices     # => Associated invoices
```

### QBD::Customer

Represents a customer imported from QuickBooks Desktop.

```ruby
customer = QBD::Customer.find(1)
customer.name           # => "ACME Corp"
customer.email          # => "billing@acme.com" 
customer.is_active      # => true
customer.bill_address   # => Associated billing address
```

### QBD::Invoice

Represents an invoice that can be sent to QuickBooks Desktop.

```ruby
invoice = QBD::Invoice.find(1)
invoice.customer        # => Associated customer
invoice.invoice_line_items # => Associated line items
invoice.draft?          # => true/false
invoice.sent?           # => true/false
invoice.to_quickbooks_format # => Hash formatted for QB
```

## Configuration Options

```ruby
QubeSyncRails.configure do |config|
  # Required: Your QUBE Sync API credentials
  config.api_key = ENV['QUBE_API_KEY']
  config.webhook_secret = ENV['QUBE_WEBHOOK_SECRET']
  
  # Optional: API base URL (defaults to production)
  config.base_url = 'https://api.qubesync.com'
  
  # Optional: Timeout settings
  config.timeout = 30
  config.open_timeout = 10
  
  # Optional: Retry settings
  config.max_retries = 3
  config.retry_delay = 1
end
```

## Error Handling

The gem provides comprehensive error handling:

```ruby
begin
  QubeSync.customer_query(connection_id)
rescue QubeSync::AuthenticationError => e
  # Handle authentication errors
rescue QubeSync::ConnectionError => e  
  # Handle connection errors
rescue QubeSync::APIError => e
  # Handle general API errors
end
```

## Testing

### RSpec Support

The gem includes RSpec helpers for testing:

```ruby
# spec/rails_helper.rb
require 'qube_rails/rspec'

RSpec.configure do |config|
  config.include QubeRails::TestHelpers
end

# In your tests
RSpec.describe "QuickBooks Integration" do
  it "creates a connection" do
    stub_qube_sync_create_connection
    
    post qube_connections_path
    expect(response).to redirect_to(/qubesync\.com/)
  end
end
```

### Test Factories

```ruby
# spec/factories/qube_connections.rb
FactoryBot.define do
  factory :qube_connection, class: 'Qube::Connection' do
    qube_id { SecureRandom.uuid }
    state { 'pending' }
    onboarding_url { 'https://app.qubesync.com/onboard/123' }
    association :account
  end
end
```

## Security Considerations

- Always validate webhook signatures using the provided webhook secret
- Use environment variables for sensitive configuration
- Implement proper authorization checks in your controllers
- Consider rate limiting for webhook endpoints

## Troubleshooting

### Common Issues

**Connection fails to establish:**
- Verify your API credentials
- Check that QuickBooks Desktop is running
- Ensure the Web Connector is properly configured

**Webhooks not being received:**
- Verify webhook URLs are publicly accessible
- Check webhook signature validation
- Ensure proper CSRF exemption for webhook endpoints

**Data sync issues:**
- Check the Qube::Request records for error details
- Verify QuickBooks company file permissions
- Review background job logs

### Debug Mode

Enable debug logging:

```ruby
QubeSyncRails.configure do |config|
  config.debug = true
  config.logger = Rails.logger
end
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Changelog

### v0.1.0
- Initial release
- Basic QuickBooks Desktop connectivity
- Customer, vendor, and item synchronization
- Invoice creation and sending
- Webhook handling
- Rails generators

## License

This gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Support

For support and questions:

- 📧 Email: support@qubesync.com
- 🌐 Website: https://qubesync.com
- 📚 Documentation: https://docs.qubesync.com

## Related Projects

- [qube_sync](https://github.com/qubesync/qube_sync) - The core Ruby SDK for QUBE Sync
- [qube_web_connector](https://github.com/qubesync/qube_web_connector) - QuickBooks Web Connector for QUBE Sync