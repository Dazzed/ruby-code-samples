# frozen_string_literal: true

class Post < ActiveRecord::Base
  include NotificationHelper

  BOOST_POST_INTERVAL = 20.minutes

  attr_protected :conversation_count, :post_skip_count

  belongs_to :user
  belongs_to :poll_question

  has_many :post_skips
  has_many :user_messages, foreign_key: :initiating_post_id
  has_many :conversations, through: :user_messages

  has_many :page_views, -> { where(page_type: RELATIONSHIP_TYPE_POST) }, dependent: :destroy,
           foreign_key: 'page_id', class_name: 'PageView'

  has_many :ratings, -> { where(target_type: RELATIONSHIP_TYPE_POST) }, dependent: :destroy,
           foreign_key: 'target_id'

  has_many :negative_ratings, -> { where(target_type: RELATIONSHIP_TYPE_POST).where('value < 0') },
           foreign_key: 'target_id', class_name: 'Rating'

  has_many :positive_ratings, -> { where(target_type: RELATIONSHIP_TYPE_POST).where('value > 0') },
           foreign_key: 'target_id', class_name: 'Rating'

  validates :user, :presence => true
  validates :poll_question, :presence => true
  validates :response_text, :presence => true

  scope :answerable, -> { joins('LEFT OUTER JOIN users on users.id = posts.user_id').where("users.hidden_reason IS NULL or users.hidden_reason = ''").where('posts.flag_count < ? and posts.deleted = ? and (posts.needs_moderation = false or (posts.moderated = true and posts.needs_moderation = true))', CONSTANTS[:flag_threshold], false) }
  scope :not_user_ids, lambda { |user_ids| where.not(user_id: user_ids) }
  scope :recent, -> { where('posts.created_at > ?', CONSTANTS[:posts_feed_timebox_hours].hours.ago) }
  scope :now, -> { where('posts.created_at > ?', CONSTANTS[:posts_feed_recent_window_minutes].minutes.ago) }
  scope :by_active_users, -> { where('posts.user_last_active_at > ?', CONSTANTS[:last_active_window_minutes].minutes.ago).order('posts.user_last_active_at DESC').limit(300) }
  scope :ordered_lifo, -> { order('posts.created_at DESC') }

  # ***BEWARE NOTE! the ONLY reason why we *DONT* need to look at `ban_reason` when determining visibility ("visible", vs "hidden") is cos
  # ***             all banning code right now (currently User#ban_if_below_minimum_age, User#ban_with_reason) updates `hidden_reason` as well!
  scope :unmoderated, -> { where(moderated: false) }
  scope :visible, -> {
    where(deleted: false)
    .joins('LEFT JOIN users ON posts.user_id = users.id').where("users.hidden_reason is NULL OR users.hidden_reason = ''")
  }
  scope :hidden, -> {
    joins('LEFT JOIN users ON posts.user_id = users.id').where("deleted = ? OR (users.hidden_reason is NOT NULL AND users.hidden_reason != '')", true)
  }
  scope :offensive, -> {
    joins('LEFT JOIN user_blocks ON blocked_user_id = posts.user_id').where('block_flag = ?', Enums::UserBlockFlags[:offensive]).group('posts.id')

  }
  scope :underage, -> {
    joins('LEFT JOIN user_blocks ON blocked_user_id = posts.user_id').where('block_flag = ?', Enums::UserBlockFlags[:underage]).group('posts.id')
  }

  before_destroy :delete_remote_image
  after_create :increment_user_posts_count

  mount_uploader :image, ImageUploader
  process_in_background :image
  mount_uploader :share_image, ImageUploader
  process_in_background :share_image

  # serialization, remove the user password
  def serializable_hash(options = {})
    # get the supplied external_image_url field or the embedded / uploaded image file
    options[:except] ||= [:image, :external_image_url, :share_image, :dob, :gender, :location_id]
    result =  super options
    result['image_url'] = self.external_or_uploaded_image_url
    result['share_image_url'] = self.share_image.url

    # this has been replaced by the unread message count. If it gets added back in be sure to remove the line
    # that adds this variable during the unread message load
    # if the unread for user param is specified load that value
    # if options[:unread_count_for_user]
    #   #result['unread_message_count'] = self.unread_count_for_user options[:unread_count_for_user]
    #   result['unread_conversation_count'] = self.unread_conversation_count_for_user options[:unread_count_for_user]
    # end

    # load the conversation that exists for this user and this post
    if options[:conversation_with_user_id]
      conversation = Conversation.where(:initiating_user_id => options[:conversation_with_user_id]).first
      if conversation
        result['conversation_id'] = conversation.id
        result['conversation'] = conversation
      end
    end

    # if the unread for user param is specified load that value
    if options[:friend_with_user]
      result['is_friend'] = self.user.followed_by? options[:friend_with_user]
    end

    # find the number of unread messages for this post given the user id supplied
    if options[:add_unread_count_for_user_id]
      unread_messages = self.user_messages.where("user_messages.recipient_user_id = ? and user_messages.read_by_recipient = ?", options[:add_unread_count_for_user_id], false)
      result['unread_message_count'] = unread_messages.count

      # we store this here for backwards compatibility.
      result['unread_conversation_count'] = result['unread_count']
    end

    if options[:rated_ids]
      result['liked_by_current_user'] = options[:rated_ids].include? self.id
    end

    result['created_at'] = result['created_at'].as_json
    result['updated_at'] = result['updated_at'].as_json

    result
  end

  def update_friends
    return if self.deleted

    friend_requests = Friendship.where(friend_id: self.user_id)
    friend_requests.each do |request|
      send_push_to(self.user, request.user,
        type: 'user_post',
        route: {
          link: 'post',
          objectId: "#{self.id}"
        },
        title: request.status == "pending" ? "Someone you're interested in just posted" : "A friend of yours just posted",
        body: "#{self.user.first_name}: #{self.full_text}"
      )
    end
  end

  def positive_rating_count
    positive_ratings.visible.count
  end

  def negative_rating_count
    negative_ratings.visible.count
  end

  # def post_skip_count
  #   post_skips.count
  # end

  def unread_count_for_user user
    self.user_messages.where.not(:user => user).where(:read_by_recipient => false).count
  end

  def unread_conversation_count_for_user user
    self.user_messages.joins(:conversation).where.not(:user => user).where(:read_by_recipient => false).select("count(conversations.id) as c").group("conversations.id").collect(&:c).count
  end

  def page_view_count
    # !FIXME: on release of 2.0 remove return of 0
    # 0
    blocked_ids = self.user.blocked_ids
    blocked_ids = [''] unless blocked_ids.any?
    self.ratings.visible.where('ratings.user_id not in (?)',blocked_ids).count + self.user_messages.user_visible.where('user_messages.user_id not in (?)',blocked_ids).count
  end

  #get the supplied external_image_url field or the embedded / uploaded image file
  def external_or_uploaded_image_url
    self.external_image_url && !self.external_image_url.empty? ? self.external_image_url : self.image_url
  end

  def last_message_date
    self.updated_at
  end

  #generate a float timestamp
  def timestamp
    created_at.to_f
  end

  #remove the image if it was uploaded to s3
  def delete_remote_image
    if image
      self.remove_image!
      self.save
    end
    true
  end

  def full_text
    self.poll_question.post_display_format.gsub(/(%@)/, self.response_text)
  end

  def reset_rating_count
    update_attribute :rating_count, positive_ratings.count
  end

  def increment_user_posts_count
    user.update_attribute :posts_count, user.posts_count + 1
  end

  def boost_post!
    now = Time.current
    update_attributes(created_at: now + BOOST_POST_INTERVAL, updated_at: now + BOOST_POST_INTERVAL)
  end
end





# == Schema Information
#
# Table name: posts
#
#  id                 :integer         not null, primary key
#  response_text      :string
#  external_image_url :text
#  image              :string
#  user_id            :integer
#  poll_question_id   :integer
#  created_at         :datetime        not null
#  updated_at         :datetime        not null
#  flag_count         :integer         default("0")
#  deleted            :boolean         default("f")
#  post_skip_count    :integer         default("0")
#  background_color   :string
#  rating_count       :integer         default("0")
#
