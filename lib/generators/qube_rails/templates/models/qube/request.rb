class Qube::Request < ApplicationRecord
  belongs_to :qube_connection, class_name: "Qube::Connection"

  validates :qube_id, presence: true, uniqueness: true
  validates :state, presence: true

  scope :pending, -> { where(state: 'pending') }
  scope :completed, -> { where(state: 'completed') }
  scope :failed, -> { where(state: 'failed') }

  def pending?
    state == 'pending'
  end

  def completed?
    state == 'completed'
  end

  def failed?
    state == 'failed'
  end
end