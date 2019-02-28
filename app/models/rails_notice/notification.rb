class Notification < ApplicationRecord
  include RailsNoticeGetui

  serialize :cc_emails, Array
  attribute :code, :string, default: 'default'
  belongs_to :receiver, polymorphic: true
  belongs_to :sender, polymorphic: true, optional: true
  belongs_to :notifiable, polymorphic: true, optional: true
  belongs_to :linked, polymorphic: true, optional: true
  has_one :notification_setting, ->(o) { where(receiver_type: o.receiver_type) }, primary_key: :receiver_id, foreign_key: :receiver_id

  default_scope -> { order(id: :desc) }
  scope :unread, -> { where(read_at: nil) }
  scope :have_read, -> { where.not(read_at: nil) }

  after_create_commit :process_job, :update_unread_count

  def process_job
    make_as_unread
    if sending_at
      NotificationJob.set(wait_until: sending_at).perform_later id
    else
      NotificationJob.perform_later(self.id)
    end
  end

  def send_out
    send_to_socket
  end

  def send_email
    return unless email_enable?

    if notify_setting[:mailer_class]
      notify_method = notify_setting[:mailer_method] || 'notify'
      if sending_at
        notify_setting[:mailer_class].public_send(notify_method, self.notifiable_id).deliver_later(wait_until: sending_at)
      else
        notify_setting[:mailer_class].public_send(notify_method, self.notifiable_id).deliver_later
      end
    else
      if sending_at
        RailsNoticeMailer.notify(self.id).deliver_later(wait_until: sending_at)
      else
        RailsNoticeMailer.notify(self.id).deliver_later
      end
    end
  end

  def send_to_socket
    return unless self.receiver
    ActionCable.server.broadcast(
      "#{self.receiver_type}:#{self.receiver_id}",
      id: id,
      body: body,
      count: unread_count,
      link: link,
      showtime: notification_setting&.showtime
    )
    self.update sent_at: Time.now
  end

  def email_enable?
    if receiver.notification_setting&.accept_email
      return true
    end

    if receiver.notification_setting&.accept_email.is_a?(FalseClass)
      return false
    end

    RailsNotice.config.default_send_email
  end

  def notifiable_detail
    r = self.notifiable.as_json(**notify_setting.slice(:only, :except, :include, :methods))
    Hash(r).with_indifferent_access
  end

  def linked_detail
    r = self.linked.as_json(**linked_setting.slice(:only, :except, :include, :methods))
    Hash(r).with_indifferent_access
  end

  def linked_setting
    nt = linked_type&.constantize
    if nt.respond_to?(:notifies)
      r = nt.notifies
      Hash(r[self.code])
    else
      {}
    end
  end

  def notifiable_attributes
    if verbose
      r = notifiable_detail
      r.transform_values! do |i|
        next i unless i.acts_like?(:time)
        if self.receiver.respond_to?(:timezone)
          time_zone = self.receiver.timezone
        else
          time_zone = Time.zone.name
        end
        i.in_time_zone(time_zone).strftime '%Y-%m-%d %H:%M:%S'
      end
      r
    else
      {}.with_indifferent_access
    end
  end

  def notify_setting
    nt = notifiable_type.constantize
    if nt.respond_to?(:notifies)
      r = nt.notifies
      Hash(r[self.code])
    else
      {}
    end
  end

  def tr_key(column)
    "#{self.class.i18n_scope}.notify.#{notifiable.class.base_class.model_name.i18n_key}.#{self.code}.#{column}"
  end

  def tr_value(column)
    keys = I18nHelper.interpolate_key(I18n.t(tr_key(column)))
    notifiable_detail.slice *keys
  end

  def code
    super ? super.to_sym : :default
  end

  def title
    return super if super.present?

    if I18n.exists? tr_key(:title)
      tr_values = tr_value(:title)
      tr_values.merge! notify_setting.fetch(:tr_values, {})
      return I18n.t tr_key(:title), tr_values
    end

    if notifiable.respond_to?(:title)
      notifiable.title
    end
  end

  def body
    return super if super.present?

    if I18n.exists? tr_key(:body)
      tr_values = tr_value(:body)
      tr_values.merge! notify_setting.fetch(:tr_values, {})
      return I18n.t tr_key(:body), tr_values
    end

    if notifiable.respond_to?(:body)
      notifiable.body
    end
  end

  def cc_emails
    r = notify_setting.fetch(:cc_emails, []).map do |i|
      next i unless i.respond_to?(:call)
      i.call(notifiable)
    end
    r.flatten.concat super
  end

  def unread_count
    Rails.cache.read("#{self.receiver_type}_#{self.receiver_id}_unread") || 0
  end

  def make_as_unread
    if read_at.present?
      self.update(read_at: nil)
      Rails.cache.increment "#{self.receiver_type}_#{self.receiver_id}_unread"
      Rails.cache.increment "#{self.receiver_type}_#{self.receiver_id}_#{self.notifiable_type}_unread"
      Rails.cache.increment "#{self.receiver_type}_#{self.receiver_id}_official_unread" if self.official
    end
  end

  def make_as_read
    if read_at.blank?
      update(read_at: Time.now)
      Rails.cache.decrement "#{self.receiver_type}_#{self.receiver_id}_unread"
      Rails.cache.decrement "#{self.receiver_type}_#{self.receiver_id}_#{self.notifiable_type}_unread"
      Rails.cache.decrement "#{self.receiver_type}_#{self.receiver_id}_official_unread" if self.official
    end
  end

  def update_unread_count
    no = Notification.where(receiver_id: self.receiver_id, receiver_type: self.receiver_type, read_at: nil)

    Rails.cache.write "#{self.receiver_type}_#{self.receiver_id}_unread", no.count, raw: true
    Rails.cache.write "#{self.receiver_type}_#{self.receiver_id}_#{self.notifiable_type}_unread", no.where(notifiable_type: self.notifiable_type).count, raw: true
    Rails.cache.write "#{self.receiver_type}_#{self.receiver_id}_official_unread", no.where(official: true).count, raw: true
  end

  def link
    if super.present?
      super
    elsif linked_type && linked_id
      url = URI(RailsNotice.config.link_host)
      url.path = "/#{linked_type.underscore}/#{linked_id}"
      url.to_s
    else
      url = URI(RailsNotice.config.link_host)
      url.path = "/#{self.class.name.underscore}/#{self.id}"
      url.to_s
    end
  end

  def self.unread_count_details(receiver)
    r = RailsNotice.notifiable_types.map do |nt|
      { "#{nt}": Rails.cache.read("#{receiver.class.name}_#{receiver.id}_#{nt}_unread").to_i }
    end
    r << { official: Rails.cache.read("#{receiver.class.name}_#{receiver.id}_official_unread").to_i }
    r.to_combined_hash
  end

  def self.update_unread_count(receiver)
    no = Notification.where(receiver_id: receiver.id, receiver_type: receiver.class.name, read_at: nil)
    if Rails.cache.write "#{receiver.class.name}_#{receiver.id}_unread", no.count, raw: true
      Rails.cache.read "#{receiver.class.name}_#{receiver.id}_unread"
    end

    RailsNotice.notifiable_types.map do |nt|
      Rails.cache.write "#{receiver.class.name}_#{receiver.id}_#{nt}_unread", no.where(notifiable_type: nt).count, raw: true
    end

    Rails.cache.write "#{receiver.class.name}_#{receiver.id}_official_unread", no.where(official: true).count, raw: true
  end

end
