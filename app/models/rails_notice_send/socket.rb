module RailsNoticeSend::Socket
  
  def send_out
    super
    
    return unless receiver
    receiver.authorized_tokens.each do |authorized_token|
      ActionCable.server.broadcast(
        authorized_token.token,
        id: id,
        body: body,
        count: unread_count,
        link: link,
        showtime: notification_setting.showtime
      )
      self.notification_sendings.find_or_create_by(way: 'websocket', sent_to: authorized_token.token)
    end
  end

end
