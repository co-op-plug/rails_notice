module RailsNotice::NotificationSending
  extend ActiveSupport::Concern
  included do
    attribute :way, :string
    attribute :sent_to, :string
    attribute :sent_at, :datetime, default: -> { Time.now }
    attribute :sent_result, :string
    
    belongs_to :notification
    
    enum way: {
      email: 'email',
      websocket: 'websocket'
    }
  end
  
end
