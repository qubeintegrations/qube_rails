class Qube::Connection < ApplicationRecord
  belongs_to :<%= options[:parent_model].underscore %>, class_name: '<%= options[:parent_model] %>'
  has_many :requests, class_name: "Qube::Request", foreign_key: :qube_connection_id, dependent: :destroy

  has_many :customers, class_name: "QBD::Customer", foreign_key: :qube_connection_id, dependent: :destroy
  
  scope :connected, -> { where(is_connected: true) }
  scope :disconnected, -> { where(is_connected: false) }
  scope :recently_synced, -> { where('last_sync_at > ?', 1.hour.ago) }

  def needs_onboarding?
    !is_connected?
  end
  
  def connected?
    is_connected?
  end

  def needs_sync?
    last_sync_at.nil? || last_sync_at < 1.hour.ago
  end

  def sync_overdue?
    last_sync_at.nil? || last_sync_at < 1.day.ago
  end

  def mark_synced!
    update!(last_sync_at: Time.current)
  end

  def disconnect!
    update!(is_connected: false)
  end

  def connect!
    update!(is_connected: true, last_sync_at: Time.current)
  end
end