# frozen_string_literal: true

require 'customerio'

class User < ActiveRecord::Base
  include LoggingHelper

  has_secure_password
  attr_accessor :friend_count, :is_new

  attr_accessible :first_name, :last_name, :email, :password, :password_confirmation, :dob, :gender, :ban_reason, :hidden_reason, :location_attributes, :estimated_dob, :admin, :is_email_verified, :provider_id, :provider, :phone, :refresh_token, :phone_verified, :reset_password_token, :personality_type

  #validation
  email_reg_ex = /\A[\w+\-.]+@[a-z\d.]+\.[a-z]+\z/i

  validates :first_name, :length => { :maximum => 50 }

  validates :last_name, :length => { :maximum => 50 }
  validates :email, :allow_blank =>  true,
                    :format => { :with => email_reg_ex},
                    :uniqueness => { :case_sensitive => false}

  validates :password, :presence => true,
                       :confirmation => true,
                       :length => { :within => 6..40 },
                       unless: Proc.new { |c| c.id.present? and !c.password.present? }

  validates :gender, :presence => false, inclusion: { in: [GENDER_MALE, GENDER_FEMALE, UNKNOWN],
                                                     message: "%{value} is not a valid gender" }
  validate :ban_if_below_minimum_age, on: :update

  before_save :encrypt_password, :set_last_name #, :load_image_url #note this may not be effective if the provider is not created yet
  before_create :set_new_flag, :create_settings
  after_create :create_user_job_lock!, :track_create_event, :create_virtual_currency_account!, :ban_if_below_minimum_age
  after_destroy :track_destroy_event
  after_save :track_user, :update_device, :update_posts
  before_update :set_password_for_facebook_users
  # relationships
  has_many :relationships, :dependent => :destroy

  # TODO: need to be completely reimplemented, breaking Rails Admin
  has_many :user_relationships, -> { where(target_type: RELATIONSHIP_TYPE_USER) }, foreign_key: 'user_id', class_name: 'Relationship'
  has_many :reverse_relationships, -> { where(target_type: RELATIONSHIP_TYPE_USER) }, foreign_key: 'target_id', class_name: 'Relationship'
  has_many :viewed_pages, :dependent => :delete_all, class_name: 'PageView'

  has_many :friends, -> {where(status: 'accepted')}, foreign_key: 'user_id', class_name: 'Friendship'
  has_many :pending_friend_requests, -> {where(status: 'pending')}, foreign_key: 'friend_id', class_name: 'Friendship'
  has_many :friend_requests, class_name: 'Friendship', foreign_key: 'friend_id', dependent: :destroy
  has_many :friendships, class_name: 'Friendship', foreign_key: 'user_id', dependent: :destroy

  has_many :followers, -> { joins(:relationships).where(relationships: { active: true }) }, through: :reverse_relationships, source: :follower
  has_many :page_views, -> { where(page_type: RELATIONSHIP_TYPE_USER) }, dependent: :delete_all, foreign_key: 'page_id', class_name: 'PageView'

  has_one :user_settings, class_name: 'UserSetting'
  has_one :user_job_lock
  has_one :device, class_name: 'Device'

  has_one :unbanded_user

  has_many :tokens, dependent: :destroy
  has_many :external_auth_providers, dependent: :destroy
  has_many :push_devices, class_name: 'APN::Device', dependent: :destroy
  has_many :notifications, class_name: 'APN::Notification', through: :push_devices, dependent: :destroy
  has_many :purchase_receipts, -> { order(expires_date: :desc) }
  has_many :all_user_photos, class_name: 'UserPhoto', foreign_key: :user_id, dependent: :destroy
  has_many :user_photos, -> { where(deleted: false).where(needs_moderation: false).or(where(deleted: false).where(needs_moderation: true).where(moderated: true))}, class_name: 'UserPhoto', foreign_key: :user_id
  has_one :primary_photo, -> { where(deleted: false).where(needs_moderation: false).or(where(deleted: false).where(needs_moderation: true).where(moderated: true)).order(order_index: :asc) }, class_name: 'UserPhoto', foreign_key: :user_id
  has_one :my_primary_photo, -> { where(deleted: false).order(order_index: :asc) }, class_name: 'UserPhoto', foreign_key: :user_id
  has_many :purchased_virtual_products, class_name: 'VirtualProductTransaction'
  has_many :received_virtual_products, class_name: 'VirtualProductTransaction', foreign_key: :recipient_user_id

  has_many :posts, dependent: :destroy
  has_many :post_skips, dependent: :destroy
  has_many :ratings, dependent: :delete_all
  has_many :rated_posts, -> { where('ratings.value != 0') }, through: :ratings, source: :rated_posts
  has_many :liked_posts, -> { where('ratings.value > 0') }, through: :ratings, source: :rated_posts

  has_many :sent_user_blocks, class_name: 'UserBlock', dependent: :destroy
  has_many :received_user_blocks, class_name: 'UserBlock', foreign_key: 'blocked_user_id', dependent: :destroy
  has_many :blocked_users, through: :sent_user_blocks, class_name: 'User', source: 'blocked_user'
  has_many :blocking_users, through: :received_user_blocks, class_name: 'User', source: 'user'

  has_many :sent_messages, class_name: 'UserMessage', dependent: :destroy
  has_many :received_messages, class_name: 'UserMessage', foreign_key: 'recipient_user_id', dependent: :destroy
  has_many :unread_messages, -> { where(read_by_recipient: false) }, class_name: 'UserMessage', foreign_key: 'recipient_user_id'

  has_many :initiated_conversations, class_name: 'Conversation', foreign_key: 'initiating_user_id', dependent: :destroy
  has_many :targeted_conversations, class_name: 'Conversation', foreign_key: "target_user_id", dependent: :destroy

  has_one :virtual_currency_account, inverse_of: :user, dependent: :destroy
  belongs_to :location, inverse_of: :user, dependent: :destroy
  accepts_nested_attributes_for :location, update_only: true

  has_one :messenger_bot, class_name: 'MessengerBot', foreign_key: 'user_id', dependent: :destroy
  has_one :device

  has_many :guesses, class_name: 'GuessGameAnswer', foreign_key: 'about_user_id', dependent: :destroy
  has_many :answers, class_name: 'GuessGameAnswer', foreign_key: 'by_user_id', dependent: :destroy
  has_many :guess_games, class_name: 'GuessGame', foreign_key: 'by_user_id', dependent: :destroy
  has_many :guessed_about_games, class_name: 'GuessGame', foreign_key: 'about_user_id', dependent: :destroy

  has_many :anon_guess_game_answer, class_name: 'AnonGuessGameAnswer', foreign_key: 'about_user_id', dependent: :destroy

  has_many :friend_stories, class_name: 'FriendStory', foreign_key: 'user_id', dependent: :destroy
  has_many :read_friend_stories, class_name: 'FriendStoriesUsersRead', foreign_key: 'user_id', dependent: :destroy

  #scopes
  scope :admin, -> { where(admin: true) }

  rails_admin do
    excluded_fields = %i(active_conversations_count branch_link blocked_users blocking_users device external_image_url external_auth_providers followers initiated_conversations liked_posts last_active_at messages_received_count messenger_bot page_views password password_confirmation positive_post_ratings_received_count post_skips posts posts_count primary_photo purchase_receipts purchased_virtual_products rated_posts ratings received_messages received_virtual_products relationships reverse_relationships salt sent_messages targeted_conversations tokens unread_messages user_relationships viewed_pages user_job_lock user_photos)

    show do
      exclude_fields(*excluded_fields)
    end

    edit do
      exclude_fields(*excluded_fields)
    end
  end

  # serialization, remove the user password
  # Exclude password info from json output.
  def serializable_hash(options = {})
    options[:except] ||= [:password, :email, :encrypted_password, :salt, :image, :email_verification_token, :email_verification_deadline, :refresh_token, :password_digest, :reset_password_token]
    result = super(options)

    # add the conversations with a given user if argument is supplied
    if options[:add_conversations_with_user]
      conv =  Conversation.for_users self, options[:add_conversations_with_user]
      result['conversation'] = conv if conv
    end

    # add various user message fields to help sort users if supplied
    if options[:message_count_with]
      messages = UserMessage.with_users(id, options[:message_count_with].id)
      result['message_count'] = messages.count
      last_message = messages.order("created_at desc").first
      result['last_message_date'] = last_message.created_at if last_message
      result['unread_message_count'] = messages.joins(:conversation).where("recipient_user_id = ? and read_by_recipient = ?", options[:message_count_with].id, false).count
    end

    # set the is new flag if we set it during creation
    if is_new
      result['is_new'] = true
    end

    if options[:current_user_id]
      if options[:current_user_id] == id
        result['email'] = email
        result['device_id'] = uuid
        result['seconds_until_post_allowed'] = seconds_until_post_allowed
        # !IMPORTANT: when returning the your user object during login if app does not see your photo it will ask for one.  However, your photo is there just not moderated.
        # Not using thumb_url as that is generated on a job which may not be generated in time.
        result['external_image_url'] = my_primary_photo&.url if !result['external_image_url'] || result['external_image_url'].empty?
      else
        # this assumes you are eager loading both friendships and friend requests with every user object
        friend_request = self.friendships.find{|friendship| friendship.friend_id == options[:current_user_id] } ||
          self.friend_requests.find{|friend_request| friend_request.user_id == options[:current_user_id] }
        if friend_request.nil?
          result['is_friend'] = false
          result['is_a_friend'] = "no"
        elsif friend_request.status == "accepted"
          result['is_friend'] = true
          result['is_a_friend'] = "yes"
        else
          result['is_friend'] = false
          result['is_a_friend'] = "pending"
        end
      end
    end

    if !result['external_image_url'] && primary_photo&.url
      update_attribute :external_image_url, primary_photo.thumb_url
      result['external_image_url'] = external_image_url
    end

    # remove keys
    result.delete('uuid')               # used device
    result.delete('friendships')        # used just to query friendship
    result.delete('friend_requests')    # used to just query friendship

    # !FIXME: this needs user_settings to be added to includes. used in frontend to show the premium badge when not current user
    result['is_subscribed'] = is_pro?

    result['dob'] = result['dob']&.in_time_zone&.as_json  if result['dob']
    result['last_active_at'] = result['last_active_at']&.in_time_zone&.as_json  if result['last_active_at']
    result['created_at'] = result['created_at']&.in_time_zone&.as_json  if result['created_at']
    result['updated_at'] = result['updated_at']&.in_time_zone&.as_json  if result['updated_at']
    result['location'] = location.as_json  if result['location']
    result
  end

  def set_refresh_token
    refresh_token = nil
    while (true)
      refresh_token = SecureRandom.hex(10)
      encrypted_refresh_token = Digest::SHA2.hexdigest(refresh_token)
      if User.find_by(refresh_token: encrypted_refresh_token).nil?
        self.refresh_token = encrypted_refresh_token
        self.save!
        break
      end
    end
    refresh_token
  end

  def self.authenticate(email, submitted_password)
     user = User.find_by_email(email);

     (user && user.has_password?(submitted_password)) ? user : nil
  end

  def self.authenticate_with_salt(id, cookie_salt)
     user = find_by_id(id)
     (user && user.salt == cookie_salt) ? user : nil
  end

  def has_password?(submitted_password)
     encrypted_password == encrypt(submitted_password)
  end

  def activate (key)
    if key == salt
      self.update_attribute( :activated, true)
    end
  end

  def is_pro?
    # Allow a full manual override
    return true if user_settings.pro_subscription_expiration && user_settings.pro_subscription_expiration >= Time.now
    false
  end

  def hidden?
    (hidden_reason && !hidden_reason.empty?) or false
  end

  def banned?
    (ban_reason && !ban_reason.empty?) or false
  end

  def starred?
    (star_reason && !star_reason.empty?) or false
  end

  def profile_photo
    return external_image_url if !external_image_url.nil? && !external_image_url.empty?  # primary_photo.url should be cached here now.
    return primary_photo&.url
  end

  def last_notification
    notifications.order("apn_notifications.sent_at desc").limit(1).first
  end

  def random_password
    self.password= Digest::SHA1.hexdigest("--#{Time.now.to_s}----")[0,12]
    self.password_confirmation = self.password
  end

  def set_new_flag
    self.is_new = true
  end

  def create_settings
    self.user_settings = UserSetting.create
  end

  def reply_count
    sent_messages.post_replies.count
  end

  def post_rating_count
    ratings.visible.where(:target_type => RELATIONSHIP_TYPE_POST).count
    #changing from the number of ratings you received
    #Rating.where(:target_type => RELATIONSHIP_TYPE_POST).where("value > 0").where("target_id in (?)", posts.collect(&:id)).count
  end

  def post_rating_received_count
    Rating.where(:target_type => RELATIONSHIP_TYPE_POST).where("value > 0").where("target_id in (?)", posts.collect(&:id)).count
  end

  def stars_received_count
    Conversation.where(:initiating_user_id => id).where(:starred_by_posting_user => true).count
  end

  def age
    return nil if !dob
    ((Time.zone.now - dob.to_time) / 1.year.seconds).floor
  end

  def older_than_minimum_age
    if dob && dob <= 18.years.ago
      return true
    end
    return false
  end

  def check_minimum_age
    return true unless dob
    if !older_than_minimum_age
      errors.add(:dob, "must be older than 18.")
    end
  end

  def ban_if_below_minimum_age
    return true unless dob
    if !older_than_minimum_age
      reason = "You must be at least 18 years old to use Friended."
      # !IMPORTANT: this uses update_attribute to not trigger callbacks which would then loop infinitely.
      update_attribute :ban_reason, reason
      update_attribute :hidden_reason, reason
      DeleteUserPhotosJob.set(wait:1.second).perform_later(self.id)  # delete underage user_photos. Wait period is because Amazon lambda job is importing FB photos independently.
    end
  end

  def name
    first_name.to_s + " " + last_name.to_s
  end

  def abbreviated_name
    first_name.to_s + " " + last_name[0].to_s + "."
  end

  def last_post
    posts.ordered_lifo.first
  end

  def blocked_ids
    ids = self.sent_user_blocks.select(:blocked_user_id).collect(&:blocked_user_id)
    ids += self.received_user_blocks.select(:user_id).collect(&:user_id)
    ids.delete(self.id)
    return ids
  end

  def friend_ids
    self.friends.select(:friend_id).map{|f| f.friend_id }
  end

  def friends_with? user
    !Friendship.where(user: self).where(friend: user).where(status: "accepted").first.nil?
  end


  #facebook helpers

  def fb_user_id= fb_id
    # if not already set to another user, then create a new link
    if(!ExternalAuthProvider.where(:provider_type => PROVIDER_FACEBOOK).where.not(:user_id => self.id).empty?)
      ExternalAuthProvider ext = ExternalAuthProvider.new
      ext.user = self
      ext.provider_type = PROVIDER_FACEBOOK
      ext.provider_id = fb_id
    else
      raise "Facebook ID Already Assigned"
    end
  end

  def fb_user_id
    # load providers for user and get id
    e = ExternalAuthProvider.where(:provider_type => PROVIDER_FACEBOOK).where(:user_id => self.id)
    if !e.empty?
      e.first.provider_id
    end
  end

  def self.find_by_fb_user_id(fb_id)
    # load providers by user
    e = ExternalAuthProvider.where(provider_type: PROVIDER_FACEBOOK).where(provider_id: fb_id)
    if !e.empty?
      e.first.user
    end
  end

  def self.with_token(token, provider)
    logger.tagged('User#with_token') do
      user = Token.user_for_stored_external_token(token, provider)
      user = ExternalAuthProvider.user_for_token(token, provider) if !user
      return user
      # user = User.from_fb_token(token)
      # return user
    end
  end

  def self.from_fb_token(access_token)
    graph = Koala::Facebook::API.new(access_token)
    result = graph.get_object("me", fields: 'first_name,last_name,id,email,gender,age_range,birthday' )
    raise Exceptions::AuthFailed, 'Facebook API access failed.' unless result && !result.empty?
    result.deep_symbolize_keys!

    user = User.find_by(:provider_id => result[:id], :provider => "facebook")
    if user.nil?
      user = User.new
    end
    user.first_name = result[:first_name]
    user.last_name = result[:last_name]
    user.email = result[:email]
    user.gender = result[:gender]
    user.dob = Date.strptime(result[:birthday], '%m/%d/%Y') if result[:birthday]
    user.estimated_dob = false if user.dob
    user.provider = "facebook"
    user.provider_id = result[:id]

    # ensure we have set the gender to male, female or else set to unknown
    if user.gender != GENDER_MALE && user.gender != GENDER_FEMALE
      user.gender = UNKNOWN
    end
    user
  rescue Koala::Facebook::APIError => e
    logger.error(e.message)
    raise Exceptions::AuthFailed, 'Facebook API access failed.'
  end

# !IMPORTANT: this uses Faker which is  only included in development not production gemfile.  Enable for load testin
  def self.new_dummy
    User.new(
      first_name: Faker::Name.first_name,
      last_name: Faker::Name.last_name,
      email: Faker::Internet.email,
      gender: [GENDER_MALE, GENDER_FEMALE, UNKNOWN].sample,
      dob: Faker::Date.birthday(18, 65)
    )
  end

  def self.from_external_token(access_token, provider)
    return User.new_dummy if CONSTANTS[:LOAD_TESTING_ENABLED]
    raise Exceptions::AuthFailed, 'Missing Facebook Token' unless provider == PROVIDER_FACEBOOK && access_token
    User.from_fb_token(access_token)
  end

  def load_image_url_from_fb_if_no_photos
    return unless fb_user_id && user_photos&.count&.zero?
    photo = UserPhoto.new
    photo.external_image_url = external_image_url ? external_image_url : "https://graph.facebook.com/#{fb_user_id}/picture?width=400"
    photo.order_index = 0
    photo.user = self
    photo.save!
    update_attribute :external_image_url, nil
  end

  #relationship helpers

  def conversations
    Conversation.where("initiating_user_id = ? or target_user_id = ?",self.id, self.id)
  end

  def post_count
    posts.count
  end

  def device_count
    push_devices.count
  end

  def unread_and_visible_messages
    received_messages.user_visible.joins(:conversation).where(:read_by_recipient => false).where("conversations.is_active = true or conversations.expires_at > ?",Time.now)
  end

  def unread_visible_friend_messages
    friend_ids = self.friend_ids
    unread_and_visible_messages.where('user_id in (?)', friend_ids)
  end

  def friend_activity_count
    unread_visible_friend_messages.count
  end

  def activity_count
    # activity count is unread messages from active conversations or conversations that haven't been expired
    # !FIXME:  Need to handle the case where a user hides a conversation without tapping into it to read it.
    unread_and_visible_messages.count
  end

  # calculate seconds until next post allowed
  def seconds_until_post_allowed
    # no posts yet or only one reply to an intro question means you can post right now...
    if posts.count.zero? || (posts.count == 1 && last_post.poll_question.intro_only)
      0
    else
      user_settings.next_post_allowed.to_i - Time.current.to_i
    end
  end

  # set next_post_allowed to appropriate time in the future
  def update_post_allowed_interval!
    if is_pro? # || user_settings.is_free_cohort?  # NOTE: only going to give paid user this premium post interval.
      user_settings.update_attribute(:next_post_allowed, Time.current + CONFIG[:premium_post_interval].to_i.seconds)
    else
      user_settings.update_attribute(:next_post_allowed, Time.current + CONFIG[:allowed_post_interval].to_i.seconds)
    end
  end

  # set next_post_allowed to allow immediately
  def reset_post_allowed_interval!
    user_settings.update_attribute(:next_post_allowed, Time.current)
  end

  def update_posts
    if self.location_id_changed? || self.gender_changed? || self.dob_changed?
      self.posts.update_all location_id: self.location_id, gender: self.gender, dob: self.dob
    end
  end

  def set_device_blacklist_state
    return unless self.device
    self.device.is_blacklisted = (self.hidden_reason && self.hidden_reason != "") ? true : false
    self.device.save
  end

  def update_device
    if self.hidden_reason_changed? and self.device
      self.set_device_blacklist_state
    end
  end

  def track_user
    # this is to track server_created for a snap chat registered user, since user details is updated in a separate user update. dob is usually updated in this call since user needs a dob and would not have had one previously
    if self.dob_changed? && self.dob_was.nil? && !email.nil? && !email.empty?
      UpdateUserToCustomerioJob.perform_later(self.id)
      SendEventToCustomerIOJob.perform_later("server_created_user", id)
    elsif !email.nil? && !email.empty?
      UpdateUserToCustomerioJob.set(wait: 1.minute).perform_later(self.id)
    end
    UpdateUserToLocalyticsJob.set(wait: 1.minute).perform_later(self.id)
  end

  def set_branch_link
    self.update_attribute :branch_link, Branch.get_user_link(self, feature: "User Profile Link")
  end

  def create_user_job_lock!
    UserJobLock.create!(user_id: id)
  end

  def track_create_event
    return unless !email.nil? && !email.empty? && !dob.nil?  # this will not fire on a snap chat registered user

    SendEventToCustomerIOJob.perform_later("server_created_user", id)
  end

  def track_destroy_event
    return unless email

    SendEventToCustomerIOJob.perform_later("server_deleted_user", id)
  end

  def create_virtual_currency_account!
    VirtualCurrencyAccount.create!(user: self, balance: VirtualCurrencyAccount::STARTING_BALANCE)
  end

  def ban_with_reason reason
    update_attributes(ban_reason: reason, hidden_reason: reason)
  end

  def recent_block_count
    received_user_blocks.where.not("block_flag is null or block_flag = 0").where("created_at > ? ", Time.now - 24.hours).count
  end

  def recent_spam_block_count
    received_user_blocks.where("block_flag = 3").where("created_at > ? ", Time.now - 24.hours).count
  end

  def set_count_columns
    user = self
    user.posts_count = user.posts.count
    user.positive_post_ratings_received_count = user.posts.joins(:ratings).where("ratings.value > 0").count
    user.followers_count = user.followers.count
    user.messages_received_count = user.received_messages.count
    user.active_conversations_count = user.conversations.where(:is_active => true).count

    #set the last active date based on what is available
    user.last_active_at = user.created_at
    last_message = user.sent_messages.order("created_at desc").first
    if last_message
      user.last_active_at = last_message.created_at
    end

    last_post = user.posts.order("created_at desc").first
    if last_post and last_post.created_at > user.last_active_at
      user.last_active_at = last_post.created_at
    end
    user.save
  end

  def virtual_currency_balance
    if virtual_currency_account
      virtual_currency_account.balance
    else
      0
    end
  end

  def safe_destroy
    transaction do

      #safely delete messages and posts by hard deleting those without images first and then
      #destroy the ones that are left so the images get removed.
      sent_messages.where(:image => nil).where(:external_image_url => nil).delete_all
      sent_messages.destroy_all
      received_messages.where(:image => nil).where(:external_image_url => nil).delete_all
      received_messages.destroy_all
      posts.where(:image => nil).where(:external_image_url => nil).delete_all
      posts.destroy_all

      #delete all relationships that have no dependencies
      conversations.delete_all
      relationships.delete_all
      page_views.delete_all
      post_skips.delete_all
      ratings.delete_all
      sent_user_blocks.delete_all
      received_user_blocks.delete_all
      tokens.delete_all

      #destroy self
      destroy
    end
  end

  def latest_purchase_receipt
    purchase_receipts.reload
    purchase_receipts&.first
  end

  def latest_product_id
    latest_purchase_receipt&.product_id
  end

  def latest_subscription_price
    latest_purchase_receipt&.price&.to_f
  end

  def referral
    Referral.find_by(device: self.device)
  end

  def referred_by(referring_device)
    referral = Referral.create_with(self.device, referring_device)
    if referral
      self.user_settings.subscription_state = "free"
      self.user_settings.pro_subscription_expiration = Time.now + 30.days
      self.user_settings.save
    end
    return referral
  end

  def referrals_count
    Referral.referrals_count_for(self)
  end

  def create_email_verification_token
    self.email_verification_token = SecureRandom.urlsafe_base64.to_s
    self.email_verification_deadline = Time.now + 3.days
    save
  end

  def validate_email_verification_token(token)
    return false unless token && email_verification_token_valid?(token)

    self.is_email_verified = true
    save
  end

  def email_verification_token_valid?(token)
    email_verification_token == token && email_verification_deadline >= Time.now
  end

  def self.fb_id_for fb_token
    #call graph api /me/fields=id, return id
    request_path = "https://graph.facebook.com/v3.2/me?fields=id&access_token=#{fb_token}"

    begin
      response = open(request_path).read
      json = JSON.parse(response)
    rescue Exception => e
      return nil
    end

    #read id from response
    json["id"]
  end

  def self.external_id_for_token(access_token, provider)
    if CONSTANTS[:LOAD_TESTING_ENABLED]
      return access_token.to_s.truncate(191)  # use access_token as id
    elsif provider == PROVIDER_FACEBOOK
      User.fb_id_for access_token
    end
  end

  private

  def set_password_for_facebook_users
    if self.provider == "facebook" && self.password_digest.nil?
      self.password = Digest::SHA1.hexdigest("--#{Time.now.to_s}----")[0,8]
      self.password_confirmation = self.password
    end
  end

  def encrypt_password
    self.salt = make_salt if new_record?
    if(self.password && !password.blank?)
      self.encrypted_password = encrypt(self.password)
    end
  end

  def encrypt(string)
    secure_hash("#{salt}--#{string}")
  end

  def make_salt
    secure_hash("#{Time.now.utc}--#{password}")
  end

  def secure_hash(string)
    Digest::SHA2.hexdigest(string)
  end

  def set_last_name
    if self.last_name.nil?
      self.last_name = ""
    end
  end
end
