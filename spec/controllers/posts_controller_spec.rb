# frozen_string_literal: true

describe PostsController, type: :controller do
  let(:user) { Fabricate(:user_with_location) }
  let(:access_token) { JsonWebToken.encode(user_id: user.id).access_token }
  let(:facebook_auth) { Fabricate(:external_auth_with_facebook, user: user) }
  let(:token) { Fabricate(:token, user: user, hashed_access_token: Digest::SHA2.hexdigest(access_token), provider: 'facebook') }
  let(:headers) {
    {
      'Authorization' => "Bearer #{access_token}",
      'Provider' => 'facebook'
    }
  }

  before(:each) do
    user
    token
    facebook_auth
    allow(ExternalAuthProvider).to receive(:external_id_for_token).with(access_token, 'facebook').and_return(facebook_auth.provider_id)
    request.headers.merge!(headers)
    request.accept = 'application/json'
    Timecop.scale(3600) # turn seconds into hours to help testing
    # set timezone to EST to faciliate comparing JSON rendered datetimes
    Time.zone = ActiveSupport::TimeZone['Eastern Time (US & Canada)']
  end

  after(:each) do
    Time.zone = ActiveSupport::TimeZone['UTC']
  end

  describe 'GET /posts/feed' do
    before(:each) do
      # turn off age banding
      CONFIG[:post_feed_age_banding] = false
    end

    describe 'no params' do
      let(:user2) { Fabricate(:user) }

      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
      end

      it 'does not return users own Posts' do
        Fabricate(:post, user: user)
        Fabricate(:post, user: user)
        Fabricate(:post, user: user)
        get :feed
        expect(response.status).to eq 200
        expect(JSON.parse(response.body)).to eq({ 'results' => [] })
      end

      it 'returns all other users Posts' do
        now = Time.current
        Timecop.travel(now) do
          post1 = Fabricate(:post, user: user2)
          sleep 1 # ensure next post has a different created_at date when milliseconds chopped off
          post2 = Fabricate(:post, user: user2)
          sleep 1 # ensure next post has a different created_at date when milliseconds chopped off
          post3 = Fabricate(:post, user: user2)
          get :feed
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [post3, post2, post1].as_json(include: [:poll_question, :user]) })
        end
      end
    end

    describe 'by hidden user' do
      let(:hidden_user) { Fabricate(:user, hidden_reason: 'hidden user') }

      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        hidden_user.is_new = false
      end

      it 'does not return hidden user\'s posts' do
        Fabricate(:post, user: hidden_user)
        get :feed
        expect(response.status).to eq 200
        expect(JSON.parse(response.body)).to eq({ 'results' => [] })
      end
    end

    describe 'with mood filtering' do
      let(:user2) { Fabricate(:user) }

      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
      end

      it 'returns only Posts that match mood exactly' do
          post1 = Fabricate(:post, user: user2, mood: 'lungered')
          post2 = Fabricate(:post, user: user2, mood: 'flirty')
          post3 = Fabricate(:post, user: user2, mood: 'flirtymcgirty')
          post4 = Fabricate(:post, user: user2, mood: 'flirty')
          post5 = Fabricate(:post, user: user2)
          get :feed, mood: 'flirty'
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [post4, post2].as_json(include: [:poll_question, :user]) })
      end
    end

    describe 'with location filtering' do
      let(:user2) { Fabricate(:user_with_location) }
      let(:user3) { Fabricate(:user_with_location) }

      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
        user3.is_new = false
      end

      describe 'saves location_type on users UserSetting' do
        it 'saves location_type for nearby' do
          get :feed, location_type: 'nearby'
          expect(response.status).to eq 200
          user.reload
          expect(user.user_settings.location_type).to eq 'nearby'
          expect(PostsFeedResult.count).to eq 3
          expect(PostsFeedResult.first.num_results).to eq 0
          expect(PostsFeedResult.first.gender_filter).to eq nil
          expect(PostsFeedResult.first.location_filter).to eq 'nearby'
        end

        it 'saves location_type for anywhere' do
          get :feed, location_type: 'anywhere'
          expect(response.status).to eq 200
          user.reload
          expect(user.user_settings.location_type).to eq 'anywhere'
          expect(PostsFeedResult.count).to eq 3
          expect(PostsFeedResult.first.num_results).to eq 0
          expect(PostsFeedResult.first.gender_filter).to eq nil
          expect(PostsFeedResult.first.location_filter).to eq 'anywhere'
        end
      end

      describe 'nearby, user has lat/long' do
        it 'returns only Posts within LOCATION_DISTANCE' do
          # another user in the same Lat/Long
          user2.location.update_attributes(latitude: user.location.latitude, longitude: user.location.longitude)
          post_in_location1 = Fabricate(:post, user: user2)
          post_in_location2 = Fabricate(:post, user: user2)
          user3.location.update_attributes(latitude: nil, longitude: nil)
          last_post = Fabricate(:post, user: user3)
          get :feed, location_type: 'nearby'
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [post_in_location2, post_in_location1].as_json(include: [:poll_question, :user]) })
        end
      end

      describe 'nearby, user has no lat/long' do
        it 'returns just recent Posts' do
          # another user in the same Lat/Long
          user2.location.update_attributes(latitude: user.location.latitude, longitude: user.location.longitude)
          post_in_location1 = Fabricate(:post, user: user2)
          post_in_location2 = Fabricate(:post, user: user2)
          user3.location.update_attributes(latitude: nil, longitude: nil)
          last_post = Fabricate(:post, user: user3)
          # blank out users Lat/Long
          user.location.update_attributes(latitude: nil, longitude: nil)
          get :feed, location_type: 'nearby'
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [last_post, post_in_location2, post_in_location1].as_json(include: [:poll_question, :user]) })
        end
      end

      describe 'anywhere, user has lat/long' do
        it 'returns just recent Posts' do
          # another user in the same Lat/Long
          user2.location.update_attributes(latitude: user.location.latitude, longitude: user.location.longitude)
          post_in_location1 = Fabricate(:post, user: user2)
          post_in_location2 = Fabricate(:post, user: user2)
          user3.location.update_attributes(latitude: nil, longitude: nil)
          last_post = Fabricate(:post, user: user3)
          get :feed, location_type: 'anywhere'
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [last_post, post_in_location2, post_in_location1].as_json(include: [:poll_question, :user]) })
        end
      end

      describe 'anywhere, user has no lat/long' do
        it 'returns just recent Posts' do
          # another user in the same Lat/Long
          user2.location.update_attributes(latitude: user.location.latitude, longitude: user.location.longitude)
          post_in_location1 = Fabricate(:post, user: user2)
          post_in_location2 = Fabricate(:post, user: user2)
          user3.location.update_attributes(latitude: nil, longitude: nil)
          last_post = Fabricate(:post, user: user3)
          # blank out users Lat/Long
          user.location.update_attributes(latitude: nil, longitude: nil)
          get :feed, location_type: 'anywhere'
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [last_post, post_in_location2, post_in_location1].as_json(include: [:poll_question, :user]) })
        end
      end
    end

    describe 'with pagination' do
      let(:user2) { Fabricate(:user) }

      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
      end

      it 'returns only requested number of items' do
        10.times.each{ Fabricate(:post, user: user2) }
        get :feed, max: 5
        expect(JSON.parse(response.body)['results'].size).to eq 5
        expect(PostsFeedResult.count).to eq 1
        expect(PostsFeedResult.first.num_results).to eq 5
        expect(PostsFeedResult.first.gender_filter).to eq nil
        expect(PostsFeedResult.first.location_filter).to eq nil
      end

      describe 'and location filtering' do
        let(:user2) { Fabricate(:user_with_location) }
        let(:user3) { Fabricate(:user_with_location) }
        let(:posts) { [] }

        before(:each) do
          user2.location.update_attributes(latitude: user.location.latitude, longitude: user.location.longitude)
          10.times.each{ posts << Fabricate(:post, user: user2) }
          # we add a control: a Post by a User with no location that should be shown in first position
          user3.location.update_attributes(latitude: nil, longitude: nil)
          last_post = Fabricate(:post, user: user3)
          posts << last_post
        end

        describe 'nearby, user has lat/long' do
          it 'returns only requested number of items' do
            get :feed, max: 5, location_type: 'nearby'
            expect(JSON.parse(response.body)['results'].size).to eq 5
            expect(PostsFeedResult.first.num_results).to eq 5
            expect(PostsFeedResult.first.gender_filter).to eq nil
            expect(PostsFeedResult.first.location_filter).to eq 'nearby'
          end
        end

        describe 'nearby, user has no lat/long' do
          before(:each) do
            # blank out users Lat/Long
            user.location.update_attributes(latitude: nil, longitude: nil)
          end

          it 'returns only requested number of items' do
            get :feed, max: 5, location_type: 'nearby'
            expect(JSON.parse(response.body)['results'].size).to eq 5
            expect(PostsFeedResult.count).to eq 1
            expect(PostsFeedResult.first.num_results).to eq 5
            expect(PostsFeedResult.first.gender_filter).to eq nil
            expect(PostsFeedResult.first.location_filter).to eq 'nearby'
          end
        end

        describe 'anywhere, user has lat/long' do
          it 'returns only requested number of items' do
            get :feed, max: 5, location_type: 'anywhere'
            expect(JSON.parse(response.body)['results'].size).to eq 5
            expect(PostsFeedResult.count).to eq 1
            expect(PostsFeedResult.first.num_results).to eq 5
            expect(PostsFeedResult.first.gender_filter).to eq nil
            expect(PostsFeedResult.first.location_filter).to eq 'anywhere'
          end

        end

        describe 'anywhere, user has no lat/long' do
          before(:each) do
            # blank out users Lat/Long
            user.location.update_attributes(latitude: nil, longitude: nil)
            expect(PostsFeedResult.count).to eq 0
          end

          it 'returns only requested number of items' do
            get :feed, max: 5, location_type: 'anywhere'
            expect(JSON.parse(response.body)['results'].size).to eq 5
            expect(PostsFeedResult.count).to eq 1
            expect(PostsFeedResult.first.num_results).to eq 5
            expect(PostsFeedResult.first.gender_filter).to eq nil
            expect(PostsFeedResult.first.location_filter).to eq 'anywhere'
          end
        end
      end
    end
  end

  describe 'GET /posts/:id/conversations' do
    let(:user2) { Fabricate(:user) }
    let(:user3) { Fabricate(:user) }
    let(:user4) { Fabricate(:user) }

    describe 'all users visible' do
      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
        user3.is_new = false
        user4.is_new = false
      end

      describe 'validation' do
        it 'responds with 404 for post_id not found' do
          get :conversations, { id: 999_999 }
          expect(response.status).to eq 404
          expect(response.body).to eq({ error: 'This post has been removed' }.to_json)
        end
      end

      describe 'with multiple Conversations for Post' do
        it 'renders all Conversations ordered by most recent UserMessage, including initial UserMessage that started Conversation' do
          post = Fabricate(:post, user: user)
          # first Message/Conversation
          message1 = Fabricate(:user_message, user: user2, recipient_user: user, initiating_post: post)
          # first Conversation is active just in case
          message1.conversation.update_attribute(:is_active, true)
          # second Message/Conversation
          message2 = Fabricate(:user_message, user: user3, recipient_user: user, initiating_post: post)
          # second Conversation is active just in case
          message2.conversation.update_attribute(:is_active, true)
          post_reply_map = {}
          post_reply_map[message1.conversation.id] = message1.text
          post_reply_map[message2.conversation.id] = message2.text
          get :conversations, { id: post.id }
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [message2.conversation, message1.conversation].as_json(current_user: user, unread_count_for_user_id: user.id, post_reply_by_conversation: post_reply_map) })
        end
      end
    end

    describe 'some users blocked or have blocked me' do
      before(:each) do
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
        user3.is_new = false
        user4.is_new = false

        blocked_by_3 = Fabricate(:user_block, user: user3, blocked_user_id: user.id)
        blocking_4 = Fabricate(:user_block, user: user, blocked_user_id: user4.id)
      end

      describe 'with multiple Conversations for Post' do
        it 'renders only Conversations for non-blocked users, ordered by most recent UserMessage, including initial UserMessage that started Conversation' do
          post = Fabricate(:post, user: user)

          message1 = Fabricate(:user_message, user: user2, recipient_user: user, initiating_post: post)

          message2 = Fabricate(:user_message, user: user3, recipient_user: user, initiating_post: post)

          message3 = Fabricate(:user_message, user: user4, recipient_user: user, initiating_post: post)

          post_reply_map = {}
          post_reply_map[message1.conversation.id] = message1.text
          get :conversations, { id: post.id }

          expect(response.status).to eq 200
          results = JSON.parse(response.body)["results"]
          expect(results.map{|r| r["id"]}).to eq([message1.conversation.id])
        end
      end

    end

    describe 'some users hidden' do
      before(:each) do
        user3.update_attribute(:hidden_reason, 'hidden user')
        # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
        user2.is_new = false
        user3.is_new = false
        user4.is_new = false
      end

      describe 'validation' do
        it 'responds with 404 for post_id not found' do
          get :conversations, { id: 999_999 }
          expect(response.status).to eq 404
          expect(response.body).to eq({ error: 'This post has been removed' }.to_json)
        end
      end

      describe 'with multiple Conversations for Post' do
        it 'renders only Conversations for non-hidden users, ordered by most recent UserMessage, including initial UserMessage that started Conversation' do
          post = Fabricate(:post, user: user)
          # first Message/Conversation
          message1 = Fabricate(:user_message, user: user2, recipient_user: user, initiating_post: post)
          # first Conversation is active just in case
          message1.conversation.update_attribute(:is_active, true)
          # second Message/Conversation
          message2 = Fabricate(:user_message, user: user3, recipient_user: user, initiating_post: post)
          # second Conversation is active just in case
          message2.conversation.update_attribute(:is_active, true)
          post_reply_map = {}
          post_reply_map[message1.conversation.id] = message1.text
          get :conversations, { id: post.id }
          expect(response.status).to eq 200
          expect(JSON.parse(response.body)).to eq({ 'results' => [message1.conversation].as_json(current_user: user, unread_count_for_user_id: user.id, post_reply_by_conversation: post_reply_map) })
        end
      end
    end
  end

  # create a Post
  describe 'POST /poll_questions/:poll_question_id/posts' do
    let(:question) { PollQuestion.offset(rand(PollQuestion.count)).first }
    let(:intro_question) {
      # created by db/seeds
      PollQuestion.find(550)
    }

    describe 'hidden user' do
      before(:each) do
        user.update_attribute(:hidden_reason, 'hide this user')
      end

      it 'does not send SNS notification after making a Post in response to a PollQuestion' do
        expect_any_instance_of(Aws::SNS::Client).to_not receive(:publish)
        post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'response'
      end
    end

    describe 'visible user' do
      before(:each) do
        allow_any_instance_of(Aws::SNS::Client).to receive(:publish).and_return(true)
      end

      it 'allows making a Post in response to a PollQuestion' do
        post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'response'
      end

      it 'allows making a Post with a mood in response to a PollQuestion' do
        post :create, { poll_question_id: question.id, post: { response_text: 'response', mood: 'flirty' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'response'
        expect(test_post.mood).to eq 'flirty'
      end

      it 'allows another Post right away if first Post is response to intro PollQuestion' do
        # intro post
        post :create, { poll_question_id: intro_question.id, post: { response_text: 'response' } }
        expect(response.status).to eq 200
        expect(response.body).to eq Post.first.to_json
        # second post
        post :create, { poll_question_id: question.id, post: { response_text: 'response_two' } }
        expect(response.status).to eq 200
        expect(Post.count).to eq 2
        second_post = Post.last
        expect(response.body).to eq second_post.to_json
        expect(second_post.response_text).to eq 'response_two'
      end

      it 'allows another Post if the already responded to the same PollQuestion was deleted' do
        # first post
        post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
        expect(response.status).to eq 200

        # delete post
        test_post = Post.first
        test_post.deleted = true
        test_post.save

        # set next post allowed to yesterday to allow another post now...
        user.user_settings.update_attribute(:next_post_allowed, Time.current - 1.day)
        # second attempt
        post :create, { poll_question_id: question.id, post: { response_text: 'response_two' } }
        expect(response.status).to eq 200
        expect(Post.count).to eq 2
        expect(response.body).to eq Post.second.to_json
        expect(test_post.response_text).to eq 'response'
        expect(Post.second.response_text).to eq 'response_two'
      end

      it 'returns 404 Post if already responded to the same PollQuestion' do
        # first post
        post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
        expect(response.status).to eq 200
        test_post = Post.first

        # set next post allowed to yesterday to allow another post now...
        user.user_settings.update_attribute(:next_post_allowed, Time.current - 1.day)
        # second attempt
        post :create, { poll_question_id: question.id, post: { response_text: 'response_two' } }
        expect(response.status).to eq 404
        expect(Post.count).to eq 1
        expected_response = {
          success: false,
          error: "You've already posted this icebreaker before"
        }
        expect(response.body).to eq expected_response.to_json
        expect(test_post.response_text).to eq 'response'
      end

      describe 'posting interval' do
        describe 'never posted before' do
          it 'allows a post regardless of posting interval' do
            now = Time.current
            Timecop.freeze(now) do
              # not allowed for 10 minutes
              user.user_settings.update_attribute(:next_post_allowed, now + 10.minutes)
              post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
              expect(response.status).to eq 200
              test_post = Post.first
              expect(response.body).to eq test_post.to_json
              expect(test_post.response_text).to eq 'response'
              user.user_settings.reload
              expect(user.user_settings.next_post_allowed.utc).to eq (now + CONFIG[:allowed_post_interval].to_i.seconds).change(usec: 0).utc
            end
          end
        end

        describe 'for non-pro user' do
          it 'sets next post allowed interval to CONFIG[:allowed_post_interval] from now' do
            now = Time.current
            Timecop.freeze(now) do
              post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
              expect(response.status).to eq 200
              test_post = Post.first
              expect(response.body).to eq test_post.to_json
              expect(test_post.response_text).to eq 'response'
              user.user_settings.reload
              expect(user.user_settings.next_post_allowed.utc).to eq (now + CONFIG[:allowed_post_interval].to_i.seconds).change(usec: 0).utc
            end
          end

          it 'does not allow posting if next post allowed is in the future' do
            # previous Post
            Fabricate(:post, user: user)
            now = Time.current
            Timecop.freeze(now) do
              # not allowed for 10 minutes
              user.user_settings.update_attribute(:next_post_allowed, now + 10.minutes)
              post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
              expect(response.status).to eq 403
              expect(response.body).to eq({ error: 'You are not allowed to post for 10 minutes', exceeded_post_limit: true }.to_json)
            end
          end
        end

        describe 'for pro user' do
          before(:each) do
            allow_any_instance_of(User).to receive(:is_pro?).and_return(true)
          end

          it 'sets next post allowed interval to CONFIG[:premium_post_interval] from now' do
            now = Time.current
            Timecop.freeze(now) do
              post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
              expect(response.status).to eq 200
              test_post = Post.first
              expect(response.body).to eq test_post.to_json
              expect(test_post.response_text).to eq 'response'
              user.user_settings.reload
              expect(user.user_settings.next_post_allowed.utc).to eq (now + CONFIG[:premium_post_interval].to_i.seconds).change(usec: 0).utc
            end
          end

          it 'does not allow posting if next post allowed is in the future' do
            # previous Post
            Fabricate(:post, user: user)
            now = Time.current
            Timecop.freeze(now) do
              # not allowed for 10 minutes
              user.user_settings.update_attribute(:next_post_allowed, now + 10.minutes)
              post :create, { poll_question_id: question.id, post: { response_text: 'response' } }
              expect(response.status).to eq 403
              expect(response.body).to eq({ error: 'You are not allowed to post for 10 minutes', exceeded_post_limit: true }.to_json)
            end
          end
        end
      end
    end

    describe 'solicitation attempt' do
      before(:each) do
        Fabricate(:post_filter, term: 'hairy sex')
      end

      it 'marks user as hidden with correct reason' do
        post :create, { poll_question_id: question.id, post: { response_text: 'hairy sexxy' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'hairy sexxy'
        user.reload
        expect(user.hidden_reason).to eq "Suspended account: violation of terms #{Time.current.strftime('%Y%m%d')} for Post #{test_post.id}"
      end

      it 'continues to save post' do
        post :create, { poll_question_id: question.id, post: { response_text: 'hairy sexxy' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'hairy sexxy'
        expect(test_post.deleted).to be false
      end

      it 'does not send SNS notification after making a Post in response to a PollQuestion' do
        expect_any_instance_of(Aws::SNS::Client).to_not receive(:publish)
        post :create, { poll_question_id: question.id, post: { response_text: 'hairy sexxy' } }
        expect(response.status).to eq 200
        test_post = Post.first
        expect(response.body).to eq test_post.to_json
        expect(test_post.response_text).to eq 'hairy sexxy'
      end
    end
  end

  # update a Post
  describe 'PUT /posts/:id' do
    it 'allows updating response_text on a Post' do
      post1 = Fabricate(:post, user: user)
      put :update, { id: post1.id, post: { response_text: 'something newly' } }
      expect(response.status).to eq 200
      post1.reload
      expect(post1.response_text).to eq 'something newly'
    end

    it 'allows updating mood on a Post' do
      post1 = Fabricate(:post, user: user, mood: 'flirty')
      put :update, { id: post1.id, post: { mood: 'sandwichy' } }
      expect(response.status).to eq 200
      post1.reload
      expect(post1.mood).to eq 'sandwichy'
    end

    it 'allows updating mood and response_text on a Post' do
      post1 = Fabricate(:post, user: user, mood: 'flirty')
      put :update, { id: post1.id, post: { mood: 'sandwichy', response_text: 'something newly' } }
      expect(response.status).to eq 200
      post1.reload
      expect(post1.mood).to eq 'sandwichy'
      expect(post1.response_text).to eq 'something newly'
    end

    describe 'solicitation attempt' do
      before(:each) do
        Fabricate(:post_filter, term: 'hairy sex')
      end

      it 'marks user as hidden with correct reason and continues to update post' do
        post1 = Fabricate(:post, user: user)
        put :update, { id: post1.id, post: { response_text: 'hairy sexxy' } }
        expect(response.status).to eq 200
        post1.reload
        expect(post1.response_text).to eq 'hairy sexxy'
        user.reload
        expect(user.hidden_reason).to eq "Suspended account: violation of terms #{Time.current.strftime('%Y%m%d')} for Post #{post1.id}"
      end
    end
  end
end
