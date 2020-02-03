require 'spec_helper'
require 'sidekiq/testing'

describe "Users" do
  include ActiveJob::TestHelper
  let(:user) { Fabricate(:user) }
  let(:friend) { Fabricate(:user) }
  let(:access_token) { JsonWebToken.encode(user_id: user.id).access_token }
  let(:access_token_friend) { JsonWebToken.encode(user_id: friend.id).access_token }
  let(:facebook_auth) { Fabricate(:external_auth_with_facebook, user: user) }
  let(:facebook_auth_friend) { Fabricate(:external_auth_with_facebook, user: friend) }
  let(:token) { Fabricate(:token, user: user, hashed_access_token: Digest::SHA2.hexdigest(access_token), provider: 'facebook') }
  let(:friend_token) { Fabricate(:token, user: friend, hashed_access_token: Digest::SHA2.hexdigest(access_token_friend), provider: 'facebook') }
  let(:headers) {
    {
      'Authorization' => "Bearer #{access_token}",
      'Provider' => 'facebook',
      'HTTP_ACCEPT' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  }
  let(:headers_friend) {
    {
      'Authorization' => "Bearer #{access_token_friend}",
      'Provider' => 'facebook',
      'HTTP_ACCEPT' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  }

  before(:each) do
    Timecop.scale(3600) # turn seconds into hours to help testing
    user
    friend
    # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
    user.is_new = false
    friend.is_new = false
    token
    friend_token

    allow_any_instance_of(ImageUploader).to receive(:thumb).and_return(OpenStruct.new({url: "https://s3.amazonaws.com/friended-media/FriendedDeepView.png", file: OpenStruct.new({exists?: true }) }))
    allow_any_instance_of(ImageUploader).to receive(:file).and_return(OpenStruct.new({url: "https://s3.amazonaws.com/friended-media/FriendedDeepView.png", exists?: true }))
  end

  describe "Users" do
    it 'ensure an external_image_url is returned if a user has user_photos' do
      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)

      user_photo = Fabricate(:user_photo, user: user)
      user.update_attribute(:external_image_url, nil)

      get "/users/#{user.id}", nil, headers_friend
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(user_photo.image.thumb.url)
    end

    it 'does not return an external_image_url to another user if the only photo needs moderation and is unmoderated ' do
      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)

      user_photo = Fabricate(:user_photo, user: user, needs_moderation: true, moderated: false)
      user.update_attribute(:external_image_url, nil)

      get "/users/#{user.id}", nil, headers_friend
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)
    end

    it 'does not return an external_image_url to another user if the only photo has deleted set to true ' do
      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)

      user_photo = Fabricate(:user_photo, user: user, needs_moderation: false, deleted: true)
      user.update_attribute(:external_image_url, nil)

      get "/users/#{user.id}", nil, headers_friend
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)
    end

    it 'does not return an external_image_url to current_user if the only photo has deleted set to true ' do
      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)

      user_photo = Fabricate(:user_photo, user: user, needs_moderation: false, deleted: true)
      user.update_attribute(:external_image_url, nil)

      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)
    end

    it 'does return external_image_url to current_user even if the only photo needs moderation and is unmoderated ' do
      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to eq(nil)

      user_photo = Fabricate(:user_photo, user: user, needs_moderation: true, moderated: false)
      user.update_attribute(:external_image_url, nil)

      get "/users/current", nil, headers
      returned_user = JSON.parse(response.body)["result"]
      expect(returned_user["id"]).to eq(user.id)
      expect(returned_user["external_image_url"]).to_not eq(nil)
      expect(returned_user["external_image_url"]).to eq(user_photo.url)
    end
  end

  describe "Friends" do
    it 'returns "no" if no friendship request found, "pending" friendship when a friend request is sent, and "yes" if friendship is accepted' do
      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("no")

      post "/users/#{friend.id}/friends", nil, headers

      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("pending")

      post "/users/#{user.id}/friends", nil, headers_friend

      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("yes")

      get "/users/#{user.id}", nil, headers_friend
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("yes")
    end

    it 'returns "no" if no friendship request found, "pending" friendship when a friend request is received, and "yes" if friendship is accepted' do
      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("no")

      post "/users/#{user.id}/friends", nil, headers_friend

      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("pending")

      post "/users/#{friend.id}/friends", nil, headers

      get "/users/#{friend.id}", nil, headers
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("yes")

      get "/users/#{user.id}", nil, headers_friend
      expect(JSON.parse(response.body)["result"]["is_a_friend"]).to eq("yes")
    end

    it 'triggers a push notification to initial requester when friendship is accepted' do
      assert_enqueued_with(
        job: SendAPNJob) do
        post "/users/#{friend.id}/friends", nil, headers
        expect(response.status).to eq 200
        post "/users/#{user.id}/friends", nil, headers_friend
        expect(response.status).to eq 200
      end
    end

    it 'set conversation to active when a friendship is accepted' do
      message = Fabricate(:user_message, user: user, recipient_user: friend)
      expect(message.conversation.is_active).to eq(false)

      post "/users/#{friend.id}/friends", nil, headers
      expect(response.status).to eq 200
      post "/users/#{user.id}/friends", nil, headers_friend
      expect(response.status).to eq 200

      message = UserMessage.last
      expect(message.user_id).to eq(user.id)
      expect(message.recipient_user_id).to eq(friend.id)
      expect(message.conversation.is_active).to eq(true)
    end

    it 'destroys friendship when a user is blocked' do
      friendship1 = Fabricate(:friendship, user: user, friend: friend)
      friendship2 = Fabricate(:friendship, user: friend, friend: user)
      expect(friendship2.status).to eq "accepted"
      expect(Friendship.all.count).to eq 2

      post "/users/#{friend.id}/user_blocks", nil, headers
      expect(response.status).to eq 200
      expect(Friendship.all.count).to eq 0
    end

    it 'triggers a push notification when a friend request is sent' do
      Fabricate(:apn_device, user_id: friend.id)
      friend_settings = Fabricate(:user_setting, user: friend)
      message = "#{user.first_name} sent you a friend request!"
      assert_enqueued_with(
        job: SendAPNJob,
        args: [
          [friend.id],
          {
            type: 'friend_request',
            route: {
              link: 'messages',
              objectId: "new"
            },
            friend_request: {
              user_id: user.id,
              user_first_name: "#{user.first_name}",
              user_profile_image_url: user.profile_photo,
              user_dob: user.dob.in_time_zone&.as_json,
              user_is_premium: user.is_pro?
            },
            title: message,
            user_first_name: "#{user.first_name}",
            user_profile_image_url: user.profile_photo
          }
        ]
      ) do
        post "/users/#{friend.id}/friends", nil, headers
        expect(response.status).to eq 200
      end
    end

    it 'triggers a push notification if user accepts a friend request' do
      Fabricate(:apn_device, user_id: friend.id)
      Fabricate(:friendship, user: friend, friend: user)
      message = "#{self.user.first_name} accepted your friend request!"
      assert_enqueued_with(
        job: SendAPNJob,
        args: [
          [friend.id],
          {
            type: "friend_request_accepted",
            route: {
              link: 'profile',
              objectId: "#{self.user.id}"
            },
            title: message,
            toaster_body: message,
            user_first_name: "#{user.first_name}",
            user_profile_image_url: user.profile_photo
          }
        ]
      ) do
        post "/users/#{friend.id}/friends", nil, headers
        expect(response.status).to eq 200
      end
    end

    it 'returns 200 when successfully deleting a friend request' do
      post "/users/#{user.id}/friends", nil, headers_friend

      delete "/users/#{friend.id}/friends", nil, headers
      expect(response.status).to eq 200
    end

    it 'returns 200 when successfully deleting your friend request' do
      post "/users/#{friend.id}/friends", nil, headers

      delete "/users/#{friend.id}/friends", nil, headers
      expect(response.status).to eq 200
    end

    it 'returns 200 when successfully deleting a friendship' do
      post "/users/#{user.id}/friends", nil, headers_friend
      post "/users/#{friend.id}/friends", nil, headers
      friendship = Friendship.where(user: user, friend: friend).first
      expect(friendship.status).to eq "accepted"
      delete "/users/#{friend.id}/friends", nil, headers
      expect(response.status).to eq 200
      friendship = Friendship.where(user: user, friend: friend).first
      expect(friendship).to eq nil
    end

    it 'returns 403 if you try to delete a nonexistent request' do
      delete "/users/#{friend.id}/friends", nil, headers
      expect(response.status).to eq 403
    end
  end
end
