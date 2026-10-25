class QBD::Customer < ApplicationRecord
  belongs_to :qube_connection, class_name: "Qube::Connection"

  validates :list_id, presence: true, uniqueness: { scope: :qube_connection_id }
  validates :name, presence: true

  scope :active, -> { where(is_active: true) }

end