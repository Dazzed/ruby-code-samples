# frozen_string_literal: true

Fabricator(:user) do
  first_name { sequence(:first_name) { |i| "First#{i}" } }
  last_name { sequence(:last_name) { |i| "Last#{i}" } }
  email { Faker::Internet.email }
  password "foobaz123"
  gender { [GENDER_MALE, GENDER_FEMALE, UNKNOWN].sample }
  dob { Faker::Date.birthday(18, 65) }
  star_count 0
  posts_count 0
  positive_post_ratings_received_count 0
  followers_count 0
  messages_received_count 0
  active_conversations_count 0
  last_active_at { |u| u['created_at'] }
end

Fabricator(:user_with_photo, from: :user) do
  after_create do |user|
    1.times do
      user_photo = Fabricate(:user_photo, user: user, order_index: 0, needs_moderation: false)
      user.external_image_url = user_photo.url
      user.save
    end
  end
end

Fabricator(:user_with_needs_moderation_photo, from: :user) do
  after_create do |user|
    1.times do
      user_photo = Fabricate(:user_photo, user: user, order_index: 0, needs_moderation: true, moderated: false)
      user.external_image_url = user_photo.url
      user.save
    end
  end
end

Fabricator(:user_with_location, from: :user) do
  after_create do |user|
    user.location = Fabricate(:location)
    user.save!
  end
end

Fabricator(:pro_user, from: :user) do
  after_create do |user|
    user.user_settings.update_attributes(pro_subscription_expiration: Time.current + 24.hours)
  end
end
