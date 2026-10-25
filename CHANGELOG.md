# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2024-01-21

### Added
- Initial release of QubeSyncRails gem
- Rails engine with complete QuickBooks Desktop integration
- Models for QuickBooks entities (Customer, Vendor, Item, Invoice)
- ActiveRecord associations and validations
- Rails controllers with CRUD operations
- Background job templates for webhook processing
- Rails generator for easy installation
- RSpec testing helpers and factories
- Comprehensive configuration system
- Database migrations for all QuickBooks entities
- Connection management with webhook callbacks
- Data import/export functionality

### Features
- **Models**: Qube::Connection, Qube::Request, QBD::Customer, QBD::Vendor, QBD::Item, QBD::Invoice, QBD::InvoiceLineItem
- **Controllers**: Complete CRUD operations for all QuickBooks entities
- **Jobs**: Webhook processing for real-time data synchronization  
- **Generator**: `rails generate qube_rails:install` for automated setup
- **Testing**: RSpec helpers and FactoryBot factories
- **Configuration**: Environment-based API key and webhook management