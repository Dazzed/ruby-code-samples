# frozen_string_literal: true

Fabricator(:post) do
  # user_id nil
  response_text { Faker::Lorem.paragraph(10)[0..190] }
  external_image_url { Faker::Internet.url }
  poll_question { PollQuestion.order('RAND()').first }
  flag_count 0
  post_skip_count 0
  rating_count 0
  deleted false

  after_create do |post|
    post.gender = post.user.gender if post.user
    post.dob = post.user.dob if post.user
    post.location_id = post.user.location_id if post.user
    post.save
  end
end