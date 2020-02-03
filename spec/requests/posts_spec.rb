require 'spec_helper'
require 'sidekiq/testing'

describe "Posts" do
  include ActiveJob::TestHelper
  let(:user) { Fabricate(:user, admin: true) }
  let(:user_w_photo) { Fabricate(:user_with_photo) }
  let(:user_w_needs_moderation_photo) { Fabricate(:user_with_needs_moderation_photo) }
  let(:access_token) { JsonWebToken.encode(user_id: user.id).access_token }
  let(:access_token_w_photo) { JsonWebToken.encode(user_id: user_w_photo.id).access_token }
  let(:access_token_needs_moderation) { JsonWebToken.encode(user_id: user_w_needs_moderation_photo.id).access_token }
  let(:facebook_auth) { Fabricate(:external_auth_with_facebook, user: user) }
  let(:facebook_auth_w_photo) { Fabricate(:external_auth_with_facebook, user: user_w_photo) }
  let(:facebook_auth_needs_moderation) { Fabricate(:external_auth_with_facebook, user: user_w_needs_moderation_photo) }
  let(:token) { Fabricate(:token, user: user, hashed_access_token: Digest::SHA2.hexdigest(access_token), provider: 'facebook') }
  let(:token_w_photo) { Fabricate(:token, user: user_w_photo, hashed_access_token: Digest::SHA2.hexdigest(access_token_w_photo), provider: 'facebook') }
  let(:token_needs_moderation) { Fabricate(:token, user: user_w_needs_moderation_photo, hashed_access_token: Digest::SHA2.hexdigest(access_token_needs_moderation), provider: 'facebook') }
  let(:headers) {
    {
      'Authorization' => "Bearer #{access_token}",
      'Provider' => 'facebook',
      'HTTP_ACCEPT' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  }
  let(:headers_w_photo) {
    {
      'Authorization' => "Bearer #{access_token_w_photo}",
      'Provider' => 'facebook',
      'HTTP_ACCEPT' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  }
  let(:headers_needs_moderation) {
    {
      'Authorization' => "Bearer #{access_token_needs_moderation}",
      'Provider' => 'facebook',
      'HTTP_ACCEPT' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  }

  before(:each) do
    Timecop.scale(3600) # turn seconds into hours to help testing
    user
    user_w_photo
    user_w_needs_moderation_photo
    # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
    user.is_new = false
    user_w_photo.is_new = false
    user_w_needs_moderation_photo.is_new = false
    token
    token_w_photo
    token_needs_moderation

    allow_any_instance_of(Aws::SNS::Client).to receive(:publish).and_return(true)
  end

  describe "user with profile photos that need moderation" do
    it 'does not show posts created by an unmoderated use' do
      post "/poll_questions/550/posts", {post: {response_text:'response'} }, headers_w_photo
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["needs_moderation"]).to eq false
      post_id = JSON.parse(response.body)["id"]
      visible_post = Post.find(post_id)

      post "/poll_questions/550/posts", {post: {response_text:'response'} }, headers_needs_moderation
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["needs_moderation"]).to eq true

      get "/posts/feed", nil, headers
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["results"]).to eq([visible_post].as_json(include: [:poll_question, :user]))
    end

    it 'does show posts in the feed once a user\'s photos have been moderated use' do

      post "/poll_questions/550/posts", {post: {response_text:'needs mod'} }, headers_needs_moderation
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["needs_moderation"]).to eq true
      post_id = JSON.parse(response.body)["id"]
      post_needs_moderation = Post.find(post_id)

      post "/poll_questions/550/posts", {post: {response_text:'response'} }, headers_w_photo
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["needs_moderation"]).to eq false
      post_id = JSON.parse(response.body)["id"]
      visible_post = Post.find(post_id)

      # moderate user photos
      post "/mod/user_photos", {moderated: [user_w_needs_moderation_photo.all_user_photos.first.id]}, headers
      expect(response.status).to eq 200

      post_needs_moderation.reload
      visible_post.reload

      get "/posts/feed", nil, headers
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)["results"]).to eq([visible_post, post_needs_moderation].as_json(include: [:poll_question, :user]))
    end
  end

end
