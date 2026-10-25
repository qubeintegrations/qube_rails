class QBDCustomerQueryWebhookJob < ApplicationJob
  queue_as :default

  def perform(webhook_data)
    connection_id = webhook_data['connection_id']
    customer_data = webhook_data['data']

    return unless connection_id && customer_data

    connection = Qube::Connection.find_by(id: connection_id)
    return unless connection

    customer_data.each do |customer_info|
      process_customer(connection, customer_info)
    end
  end

  private

  def process_customer(connection, customer_info)
    qb_id = customer_info['ListID']
    return unless qb_id

    customer = connection.customers.find_or_initialize_by(qb_id: qb_id)
    
    customer.assign_attributes(
      name: customer_info['Name'],
      full_name: customer_info['FullName'],
      company_name: customer_info['CompanyName'],
      first_name: customer_info['FirstName'],
      last_name: customer_info['LastName'],
      email: customer_info['Email'],
      phone: customer_info['Phone'],
      fax: customer_info['Fax'],
      billing_address: format_address(customer_info['BillAddress']),
      shipping_address: format_address(customer_info['ShipAddress']),
      contact: customer_info['Contact'],
      alt_contact: customer_info['AltContact'],
      account_number: customer_info['AccountNumber'],
      credit_limit: customer_info['CreditLimit'],
      preferred_payment_method_ref: customer_info['PreferredPaymentMethodRef'],
      credit_card_info: customer_info['CreditCardInfo'],
      job_status: customer_info['JobStatus'],
      job_start_date: parse_date(customer_info['JobStartDate']),
      job_projected_end_date: parse_date(customer_info['JobProjectedEndDate']),
      job_end_date: parse_date(customer_info['JobEndDate']),
      job_description: customer_info['JobDescription'],
      job_type_ref: customer_info['JobTypeRef'],
      notes: customer_info['Notes'],
      preferred_delivery_method: customer_info['PreferredDeliveryMethod'],
      price_level_ref: customer_info['PriceLevelRef'],
      terms_ref: customer_info['TermsRef'],
      sales_rep_ref: customer_info['SalesRepRef'],
      balance: customer_info['Balance'],
      total_balance: customer_info['TotalBalance'],
      sales_tax_code_ref: customer_info['SalesTaxCodeRef'],
      item_sales_tax_ref: customer_info['ItemSalesTaxRef'],
      sales_tax_country: customer_info['SalesTaxCountry'],
      resale_number: customer_info['ResaleNumber'],
      is_active: customer_info['IsActive'] != false
    )

    if customer.save
      Rails.logger.info "Successfully processed customer: #{customer.name}"
    else
      Rails.logger.error "Failed to save customer #{customer.name}: #{customer.errors.full_messages.join(', ')}"
    end
  end

  def format_address(address_data)
    return nil unless address_data.is_a?(Hash)

    [
      address_data['Addr1'],
      address_data['Addr2'],
      address_data['Addr3'],
      address_data['City'],
      address_data['State'],
      address_data['PostalCode'],
      address_data['Country']
    ].compact.join(', ')
  end

  def parse_date(date_string)
    return nil unless date_string.present?
    Date.parse(date_string) rescue nil
  end
end