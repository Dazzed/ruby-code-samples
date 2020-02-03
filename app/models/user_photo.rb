class UserPhoto < ActiveRecord::Base
  include ModerationHelper

  attr_accessible :order_index, :user_id, :image, :moderated, :needs_moderation, :external_image_url, :source

  validates :user, :presence => true

  # !IMPORTANT: because soft deletes is temporary and for internal use only, use as default scope to reduce code change
  default_scope { order("order_index asc, updated_at desc") }

  #relationships
  belongs_to :user
  has_and_belongs_to_many :aws_hits

  mount_uploader :image, ImageUploader
  process_in_background :image

  before_save :check_underage, :track_user

  rails_admin do
    excluded_fields = %i(external_image_url)

    show do
      exclude_fields(*excluded_fields)
    end

    edit do
      exclude_fields(*excluded_fields)
    end
  end

  #serialization, remove the user password
  # Exclude password info from json output.
  def serializable_hash(options={})
    if !options
      options = {}
    end
    options[:except] ||= [ :external_image_url, :image]
    result =  super options
    result['image_url'] = self.external_image_url ? self.external_image_url : self.image_url
    result['created_at'] = result['created_at']&.in_time_zone&.as_json  if result['created_at']
    result['updated_at'] = result['updated_at']&.in_time_zone&.as_json  if result['updated_at']
    result
  end

  def thumb_url
    return self.external_image_url if !self.image.image?   # if we don't have an image file then try to return the external_image_url
    self.image.generate_thumb if !self.image.thumb?  # generate thumbnail image if the thumbnail file does not exist (this happens in the background)
    return self.image.thumb.url # return thumbnail url optimistically assuming thumbnail generation will succeed.
  end

  def url
    self.external_image_url ? self.external_image_url : self.image_url
  end

  def moderate(approved)
    self.moderated = true
    self.deleted = !approved
    self.save

    if !self.user.nil? && approved
      UserPhoto.reindex self.user
      posts = self.user.posts.where(needs_moderation: true).where(moderated: false).order(created_at: :desc)
      if posts.count > 0
        posts.update_all(moderated: true)
        self.user.posts.joins(:poll_question).where('poll_questions.intro_only is true').update_all(external_image_url: self.user.primary_photo&.url)
      end
    end
  end


  def self.reindex user
    return if user.nil?

    connection.execute("
      update user_photos
      inner join (
        select *,
        @rank:=@rank+1 as row_number
        from user_photos
         cross join (select @rank := -1) r
         where user_id = #{user.id}
         and deleted is false
         order by order_index asc, updated_at desc
         ) as t
        on user_photos.id = t.id
        set user_photos.order_index = row_number")
    user.external_image_url = user.primary_photo&.thumb_url
    user.save
  end

  def check_underage
    return false if !user.nil? && !user.older_than_minimum_age
    return true
  end

  def track_user
    user.track_user if !user.nil?
  end

end
# == Schema Information
#
# Table name: user_photos
#
#  id                 :integer         not null, primary key
#  user_id            :integer
#  image              :string
#  external_image_url :string
#  order_index        :integer
#  created_at         :datetime
#  updated_at         :datetime
#

