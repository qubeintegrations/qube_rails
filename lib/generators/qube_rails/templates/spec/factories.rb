# FactoryBot factories for QubeRails models
FactoryBot.define do
  factory :qube_connection, class: 'Qube::Connection' do
    # Association to parent model - uncomment and adjust based on your parent model
    # <%= options[:parent_model].underscore %> { create(:<%= options[:parent_model].underscore %>) }
    
    qb_company_name { "#{Faker::Company.name} LLC" }
    qb_company_file { "#{qb_company_name.parameterize}.qbw" }
    webhook_secret { SecureRandom.hex(32) }
    is_connected { true }
    last_sync_at { 1.hour.ago }

    trait :disconnected do
      is_connected { false }
      last_sync_at { nil }
    end

    trait :recently_synced do
      last_sync_at { 5.minutes.ago }
    end

    trait :stale_sync do
      last_sync_at { 2.days.ago }
    end
  end

  factory :qube_request, class: 'Qube::Request' do
    association :qube_connection, factory: :qube_connection
    
    request_type { %w[customer_query vendor_query item_query invoice_query].sample }
    status { 'pending' }
    
    trait :completed do
      status { 'completed' }
      response_data { { 'success' => true, 'count' => rand(10..100) } }
    end

    trait :failed do
      status { 'failed' }
      error_message { 'Connection timeout' }
    end

    trait :customer_query do
      request_type { 'customer_query' }
    end

    trait :vendor_query do
      request_type { 'vendor_query' }
    end

    trait :item_query do
      request_type { 'item_query' }
    end

    trait :invoice_query do
      request_type { 'invoice_query' }
    end
  end

  factory :qbd_customer, class: 'QBD::Customer' do
    association :qube_connection, factory: :qube_connection
    
    qb_id { SecureRandom.hex(8) }
    name { Faker::Company.name }
    full_name { name }
    company_name { name }
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    email { Faker::Internet.email }
    phone { Faker::PhoneNumber.phone_number }
    billing_address { "#{Faker::Address.street_address}, #{Faker::Address.city}, #{Faker::Address.state_abbr} #{Faker::Address.zip_code}" }
    is_active { true }
    balance { Faker::Number.decimal(l_digits: 3, r_digits: 2) }
    total_balance { balance }

    trait :inactive do
      is_active { false }
    end

    trait :with_job do
      job_status { 'awarded' }
      job_start_date { 1.month.from_now }
      job_projected_end_date { 3.months.from_now }
      job_description { Faker::Lorem.sentence }
    end

    trait :with_high_balance do
      balance { Faker::Number.between(from: 10000, to: 50000) }
      total_balance { balance }
    end
  end

  factory :qbd_vendor, class: 'QBD::Vendor' do
    association :qube_connection, factory: :qube_connection
    
    qb_id { SecureRandom.hex(8) }
    name { Faker::Company.name }
    company_name { name }
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    email { Faker::Internet.email }
    phone { Faker::PhoneNumber.phone_number }
    billing_address { "#{Faker::Address.street_address}, #{Faker::Address.city}, #{Faker::Address.state_abbr} #{Faker::Address.zip_code}" }
    is_active { true }
    balance { Faker::Number.decimal(l_digits: 3, r_digits: 2) }

    trait :inactive do
      is_active { false }
    end

    trait :with_high_balance do
      balance { Faker::Number.between(from: 5000, to: 25000) }
    end
  end

  factory :qbd_item, class: 'QBD::Item' do
    association :qube_connection, factory: :qube_connection
    
    qb_id { SecureRandom.hex(8) }
    name { Faker::Commerce.product_name }
    full_name { name }
    is_active { true }
    item_type { %w[inventory service non_inventory].sample }
    sales_price { Faker::Number.decimal(l_digits: 2, r_digits: 2) }
    purchase_cost { sales_price * 0.6 } # 40% markup
    sales_description { Faker::Lorem.sentence }
    purchase_description { sales_description }

    trait :inventory do
      item_type { 'inventory' }
      quantity_on_hand { Faker::Number.between(from: 0, to: 100) }
      average_cost { purchase_cost }
      reorder_point { 10 }
    end

    trait :service do
      item_type { 'service' }
      quantity_on_hand { nil }
      average_cost { nil }
    end

    trait :non_inventory do
      item_type { 'non_inventory' }
      quantity_on_hand { nil }
      average_cost { nil }
    end

    trait :out_of_stock do
      quantity_on_hand { 0 }
    end

    trait :low_stock do
      quantity_on_hand { 5 }
      reorder_point { 10 }
    end
  end

  factory :qbd_invoice, class: 'QBD::Invoice' do
    association :qube_connection, factory: :qube_connection
    association :customer, factory: :qbd_customer
    
    qb_id { SecureRandom.hex(8) }
    txn_date { Faker::Date.between(from: 30.days.ago, to: Date.current) }
    ref_number { "INV-#{Faker::Number.number(digits: 6)}" }
    billing_address { customer.billing_address }
    subtotal { Faker::Number.decimal(l_digits: 3, r_digits: 2) }
    sales_tax_percentage { 8.25 }
    sales_tax_total { subtotal * (sales_tax_percentage / 100) }
    applied_amount { subtotal + sales_tax_total }
    balance_remaining { 0.00 }

    trait :pending do
      is_pending { true }
    end

    trait :with_balance do
      balance_remaining { applied_amount }
    end

    trait :overdue do
      due_date { 30.days.ago }
      balance_remaining { applied_amount }
    end

    trait :with_line_items do
      after(:create) do |invoice|
        create_list(:qbd_invoice_line_item, 3, invoice: invoice)
        invoice.update!(subtotal: invoice.line_items.sum(:amount))
      end
    end
  end

  factory :qbd_invoice_line_item, class: 'QBD::InvoiceLineItem' do
    association :invoice, factory: :qbd_invoice
    association :item, factory: :qbd_item
    
    description { item.name }
    quantity { Faker::Number.between(from: 1, to: 10) }
    unit_of_measure { 'Each' }
    rate { item.sales_price }
    amount { quantity * rate }

    trait :service_item do
      association :item, factory: [:qbd_item, :service]
      quantity { 1 }
    end

    trait :high_quantity do
      quantity { Faker::Number.between(from: 50, to: 100) }
      amount { quantity * rate }
    end
  end
end