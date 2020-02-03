# frozen_string_literal: true

describe Post do
  let(:user) { Fabricate(:user) }

  describe 'db columns' do
    it { expect(subject).to have_db_column :id }
    it { expect(subject).to have_db_column :response_text }
    it { expect(subject).to have_db_column :external_image_url }
    it { expect(subject).to have_db_column :image }
    it { expect(subject).to have_db_column :user_id }
    it { expect(subject).to have_db_column :poll_question_id }
    it { expect(subject).to have_db_column :flag_count }
    it { expect(subject).to have_db_column :deleted }
    it { expect(subject).to have_db_column :post_skip_count }
    it { expect(subject).to have_db_column :background_color }
    it { expect(subject).to have_db_column :rating_count }
    it { expect(subject).to have_db_column :mood }
    it { expect(subject).to have_db_column :created_at }
    it { expect(subject).to have_db_column :updated_at }
  end

  describe 'relationships' do
    it { expect(subject).to belong_to(:user) }
    it { expect(subject).to belong_to(:poll_question) }
    it { expect(subject).to have_many(:post_skips) }
    it { expect(subject).to have_many(:user_messages) }
    it { expect(subject).to have_many(:conversations) }
    it { expect(subject).to have_many(:page_views) }
    it { expect(subject).to have_many(:ratings) }
    it { expect(subject).to have_many(:negative_ratings) }
    it { expect(subject).to have_many(:positive_ratings) }
  end

  describe 'scopes' do
    it 'offers retrieving only answerable posts' do
      expect(Post.answerable.to_sql).to eq Post.joins('LEFT OUTER JOIN users on users.id = posts.user_id').where("users.hidden_reason IS NULL or users.hidden_reason = ''").where('posts.flag_count < ? and posts.deleted = 0 and (posts.needs_moderation = false or (posts.moderated = true and posts.needs_moderation = true))', CONSTANTS[:flag_threshold]).to_sql
    end

    it 'offers only retrieving recent posts' do
      now = Time.current
      Timecop.freeze(now) do
        expect(Post.recent.to_sql).to eq Post.all.where('posts.created_at > ?', now - CONSTANTS[:posts_feed_timebox_hours].hours).to_sql
      end
    end
  end

  describe 'boost_post!' do
    it 'sets created_at BOOST_POST_INTERVAL minutes into the future' do
      now = Time.current.to_date.to_datetime # MySQL & Rails < 5.x have a problem with timestamp precision so cap to start of day
      Timecop.freeze(now) do
        user = Fabricate(:user)
        post = Fabricate(:post, user: user)
        initial_created_at = post.created_at
        post.boost_post!
        expect(post.created_at).to eq initial_created_at + Post::BOOST_POST_INTERVAL
      end
    end
  end

  describe 'conversations' do
    it 'can find all Conversations initiated with a UserMessage reply to a Post' do
      post1 = Fabricate(:post, user: user)
      user2 = Fabricate(:user)
      message1 = Fabricate(:user_message, user: user2, recipient_user: user, initiating_post: post1)
      user3 = Fabricate(:user)
      message2 = Fabricate(:user_message, user: user3, recipient_user: user, initiating_post: post1)
      message3 = Fabricate(:user_message, user: user, recipient_user: user3)
      expect(post1.conversations).to include(message1.conversation, message2.conversation)
    end
  end
end
