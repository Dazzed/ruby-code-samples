# frozen_string_literal: true

describe User do
  describe 'validations' do
    it 'should create a new instance with valid attributes' do
      User.create!(Fabricate.attributes_for(:user))
    end

    it 'should not require a first_name' do
      no_name_user = User.new(Fabricate.attributes_for(:user).except(:first_name))
      no_name_user.should be_valid
    end

    it 'should not require a last_name' do
      no_name_user = User.new(Fabricate.attributes_for(:user).except(:last_name))
      no_name_user.should be_valid
    end

    it 'should allow blank email' do
      no_em_user = User.new(Fabricate.attributes_for(:user).except(:email))
      no_em_user.should be_valid
    end

    it "should allow blank dob" do
      no_dob_user = User.new(Fabricate.attributes_for(:user).except(:dob))
      no_dob_user.should be_valid
    end

    it 'should reject long first name' do
      long_name = 'a' * 51
      long_name_user = User.new(Fabricate.attributes_for(:user).merge(first_name: long_name))
      long_name_user.should_not be_valid
    end

    it 'should reject long last name' do
      long_name = 'a' * 51
      long_name_user = User.new(Fabricate.attributes_for(:user).merge(last_name: long_name))
      long_name_user.should_not be_valid
    end

    it 'should accept valid email' do
      addresses = %w[user@foo.com THE_USER@foo.bar.org first.Last@Foo.Jp]
      addresses.each do |address|
        valid_user = User.new(Fabricate.attributes_for(:user).merge(email: address))
        valid_user.should be_valid
      end
    end

    it 'should reject invalid email' do
      addresses = %w[user@foo,com THE_USER_at_foo.bar.org first.last@foo.]
      addresses.each do |address|
        invalid_user = User.new(Fabricate.attributes_for(:user).merge(email: address))
        invalid_user.should_not be_valid
      end
    end

    it 'should reject dup emails' do
      user = Fabricate(:user)
      user_dup = User.new(Fabricate.attributes_for(:user).merge(email: user.email))
      user_dup.should_not be_valid
    end

    it 'should reject dup emails diff case' do
      user = Fabricate(:user)
      user_dup = User.new(Fabricate.attributes_for(:user).merge(email: user.email.upcase))
      user_dup.should_not be_valid
    end
  end

  describe 'dob' do
    it 'bans and hides a user who is under 18' do
      underage_user = User.create!(Fabricate.attributes_for(:user).merge(dob: 17.years.ago))
      expect(underage_user.ban_reason).to eq "You must be at least 18 years old to use Friended."
      expect(underage_user.hidden_reason).to eq "You must be at least 18 years old to use Friended."
    end

    it 'allows an update to 18+ years' do
      user = User.create!(Fabricate.attributes_for(:user))
      date = 19.years.ago
      user.update_attributes!(dob: date)
      expect(user.dob).to eq date
      expect(user.ban_reason).to be nil
    end

    it 'should ban and hide a user who updates to <18 years as well as blacklist the user\'s device' do
      user = User.create!(Fabricate.attributes_for(:user))
      device = Device.create!(user: user, uuid: SecureRandom.uuid)
      date = 17.years.ago
      expect(device.is_blacklisted).to eq false
      user.update_attributes!(dob: date)
      device.reload
      expect(user.dob).to eq date
      expect(user.ban_reason).to eq 'You must be at least 18 years old to use Friended.'
      expect(user.hidden_reason).to eq "You must be at least 18 years old to use Friended."
      expect(device.is_blacklisted).to eq true
    end
  end

  describe 'scopes' do
    it 'offers retrieving only admin users' do
      expect(User.admin.to_sql).to eq User.all.where(admin: true).to_sql
    end
  end

  describe 'passwords' do
    subject { Fabricate(:user) }

    it 'should have a password attribute' do
      subject.should respond_to(:password)
    end

    it 'should have a password conf attribute' do
      subject.should respond_to(:password_confirmation)
    end
  end

  describe 'password validation' do
    it 'should require a password' do
      User.new(Fabricate.attributes_for(:user).merge(password: '', password_confirmation: '')).should_not be_valid
    end

    it 'should require a matching password conf' do
      User.new(Fabricate.attributes_for(:user).merge(password_confirmation: 'invalid')).should_not be_valid
    end

    it 'should reject short password' do
      short = 'a' * 5
      hash = Fabricate.attributes_for(:user).merge(password: short, password_confirmation: short)
      User.new(hash).should_not be_valid
    end

    it 'should reject long password' do
      long = 'a' * 41
      hash = Fabricate.attributes_for(:user).merge(password: long, password_confirmation: long)
      User.new(hash).should_not be_valid
    end
  end

  describe 'password encryption' do
    subject { Fabricate(:user) }

    it 'should have a salt' do
      subject.should respond_to(:salt)
    end

    it 'should have an encry pass attr' do
      subject.should respond_to(:encrypted_password)
    end

    it 'should set the encry pass attr' do
      subject.encrypted_password.should_not be_blank
    end

    describe 'has password method' do
      it 'should exist' do
        subject.should respond_to(:has_password?)
      end

      it 'should return false if no match' do
        subject.has_password?('invalid').should be false
      end
    end

    describe 'authenticate method' do
      let(:user) { Fabricate(:user) }

      it 'should respond to auth' do
        described_class.should respond_to(:authenticate)
      end

      it 'should return nil on email/pass mismatch' do
        described_class.authenticate(user.email, 'wrongpass').should be_nil
      end

      it 'should return nil on no user' do
        described_class.authenticate('barfoo', user.password)
      end

      it 'should return user if matched' do
        auth = described_class.authenticate(user.email, user.password)
        auth.should == user
      end
    end
  end

  describe 'fb id attribute' do
    subject { Fabricate(:user) }

    it 'should respond to fb_id' do
      subject.should respond_to(:fb_user_id)
    end
  end

  describe 'admin attribute' do
    subject { Fabricate(:user) }

    it 'should respond to admin' do
      subject.should respond_to(:admin)
    end

    it 'should should be false by default' do
      subject.should_not be_admin
    end

    it 'should be convertible to admin' do
      subject.toggle!(:admin)
      subject.should be_admin
    end
  end

  describe 'latest_subscription_price' do
    subject { Fabricate(:user) }

    it 'should be nil if no PurchaseReceipts' do
      expect(subject.latest_subscription_price).to eq nil
    end

    it 'should be equal to the latest PurchaseReceipt price according to expiration date' do
      Fabricate(:purchase_receipt, user: subject, price: 1.23, expires_date: Time.current)
      Fabricate(:purchase_receipt, user: subject, price: 4.56, expires_date: Time.current + 3.days)
      Fabricate(:purchase_receipt, user: subject, price: 7.89, expires_date: Time.current + 1.day)
      expect(subject.latest_subscription_price).to eq 4.56
    end
  end

  describe 'reset_post_allowed_interval!' do
    let(:user) { Fabricate(:user) }

    it 'does nothing if user has no posts' do
      expect(user.posts.count).to eq 0
      user.reset_post_allowed_interval!
      expect(user.posts.count).to eq 0
    end

    it 'does nothing if user has only an intro post' do
      intro_question = PollQuestion.find_by(intro_only: true)
      Post.create!(user: user, poll_question: intro_question, response_text: 'Your pic is my new wallpaper.')
      created_at = user.last_post.created_at
      user.reset_post_allowed_interval!
      user.last_post.reload
      expect(user.last_post.created_at).to eq created_at
    end

    it 'resets pro subscription user\'s user_settings.next_post_allowed to now' do
      allow_any_instance_of(User).to receive(:is_pro?).and_return(true)
      question = PollQuestion.find_by(intro_only: false)
      Post.create!(user: user, poll_question: question, response_text: 'Because NOT Taylor Swift.')
      now = Time.current
      Timecop.freeze(now) do
        user.reset_post_allowed_interval!
        user.user_settings.reload
        expect(user.user_settings.next_post_allowed.utc).to eq now.change(usec: 0).utc
      end
    end

    it 'resets non-pro subscription user\'s user_settings.next_post_allowed to now' do
      allow_any_instance_of(User).to receive(:is_pro?).and_return(false)
      question = PollQuestion.find_by(intro_only: false)
      Post.create!(user: user, poll_question: question, response_text: 'Pizza don\'t make itself.')
      now = Time.current
      Timecop.freeze(now) do
        user.reset_post_allowed_interval!
        user.user_settings.reload
        expect(user.user_settings.next_post_allowed.utc).to eq now.change(usec: 0).utc
      end
    end
  end

  describe 'relationships' do
    let(:user) { Fabricate(:user) }
    let(:another_user) { Fabricate(:user) }

    it { expect(subject).to belong_to(:location) }
    it { expect(subject).to have_one(:user_job_lock) }

    it 'creates the user record with associations' do
      #create child records
      question = PollQuestion.find_by(intro_only: false)
      post = Post.create!(user: user, poll_question: question, response_text: 'Because NOT Taylor Swift.')
      conversation = Conversation.create!(initiating_user: user, target_user: another_user )
      message = UserMessage.create!(user: user, recipient_user: another_user, text: "Hellooooo", conversation: conversation )
      Rating.create!(user: user, target_id: post.id, target_type: RELATIONSHIP_TYPE_POST, value: 1)
      PageView.create!(user: user, page_id: another_user.id, page_type: RELATIONSHIP_TYPE_USER)
      PostSkip.create!(user: user, post: post)

      #check user is there
      id = user.id
      expect(User.find_by_id(id)).to_not be_nil

      #check associations are gone
      expect(Post.where(user_id: id)).to_not be_empty
      expect(UserSetting.where(user_id: id)).to_not be_empty
      expect(VirtualCurrencyAccount.where(user_id: id)).to_not be_empty
      expect(UserMessage.where(user_id: id)).to_not be_empty
      expect(Conversation.where(initiating_user_id: id)).to_not be_empty
      expect(Rating.where(user_id: id)).to_not be_empty
      expect(PageView.where(user_id: id)).to_not be_empty
      expect(PostSkip.where(user_id: id)).to_not be_empty
      expect(UserJobLock.where(user_id: id)).to_not be_empty
    end
  end

  describe 'safe destroy' do
    let(:user) { Fabricate(:user) }
    let(:another_user) { Fabricate(:user) }

    it 'removes the user record and children' do
      # create child records
      question = PollQuestion.find_by(intro_only: false)
      post = Post.create!(user: user, poll_question: question, response_text: 'Because NOT Taylor Swift.')
      conversation = Conversation.create!(initiating_user: user, target_user: another_user )
      message = UserMessage.create!(user: user, recipient_user: another_user, text: "Hellooooo", conversation: conversation )
      Rating.create!(user: user, target_id: post.id, target_type: RELATIONSHIP_TYPE_POST, value: 1)
      PageView.create!(user: user, page_id: another_user.id, page_type: RELATIONSHIP_TYPE_USER)
      PostSkip.create!(user: user, post: post)

      # destroy user
      id = user.id
      user.safe_destroy

      # check user is gone
      expect(User.find_by_id(id)).to be_nil

      # check associations are gone
      expect(Post.where(user_id: id)).to be_empty
      expect(VirtualCurrencyAccount.where(user_id: id)).to be_empty
      expect(UserMessage.where(user_id: id)).to be_empty
      expect(Conversation.where(initiating_user_id: id)).to be_empty
      expect(Rating.where(user_id: id)).to be_empty
      expect(PageView.where(user_id: id)).to be_empty
      expect(PostSkip.where(user_id: id)).to be_empty

      # except what we would like to preserve
      expect(UserSetting.where(user_id: id)).to_not be_empty
    end

    it 'preserves PurchaseReceipts' do
      id = user.id
      Fabricate(:purchase_receipt, user: user)
      expect(PurchaseReceipt.where(user_id: id)).to_not be_empty
      user.safe_destroy
      expect(PurchaseReceipt.where(user_id: id)).to_not be_empty
    end
  end

  describe 'hidden?' do
    subject { Fabricate(:user) }

    it 'reports false if no hidden_reason' do
      expect(subject.hidden?).to be false
    end

    it 'reports true if hidden_reason is non-empty' do
      subject.update_attribute(:hidden_reason, 'hidden user')
      expect(subject.hidden?).to be true
    end
  end

  describe 'email verification' do
    subject { Fabricate(:user) }

    before do
      subject.create_email_verification_token
    end

    it 'should have a token' do
      subject.should respond_to(:email_verification_token)
    end

    it 'should have an expiration date' do
      subject.should respond_to(:email_verification_deadline)
    end

    it 'should set the email verification token' do
      subject.email_verification_token.should_not be_blank
    end

    it 'should set the expiration date to 72 hours from now' do
      deadline = Time.now + 3.days
      expect(subject.email_verification_deadline.utc.yday).to eql(deadline.utc.yday)
    end

    it 'should be able to set is_email_verified to true' do
      subject.toggle!(:is_email_verified)
      expect(subject.is_email_verified).to be true
    end

    it 'should reject invalid token' do
      expect(subject.validate_email_verification_token('invalid')).to be false
    end

    it 'should accept valid token' do
      token = subject.email_verification_token
      expect(subject.validate_email_verification_token(token)).to be true
    end

    it 'should reject expired token' do
      token = subject.email_verification_token
      subject.email_verification_deadline = 4.days.ago
      expect(subject.validate_email_verification_token(token)).to be false
    end

    it 'should accept non-expired token' do
      token = subject.email_verification_token
      subject.email_verification_deadline = Time.now + 1.day
      expect(subject.validate_email_verification_token(token)).to be true
    end

    it 'should not set is_email_verified to true if conditions are not met' do
      token = 'invalid'
      subject.email_verification_deadline = Time.now + 1.day
      subject.validate_email_verification_token(token)
      expect(subject.is_email_verified).to be false
    end

    it 'should set is_email_verified to true if conditions are met' do
      token = subject.email_verification_token
      subject.email_verification_deadline = Time.now + 1.day
      subject.validate_email_verification_token(token)
      expect(subject.is_email_verified).to be true
    end
  end

  describe 'db columns' do
    it { expect(subject).to have_db_column :id }
    it { expect(subject).to have_db_column :first_name }
    it { expect(subject).to have_db_column :last_name }
    it { expect(subject).to have_db_column :salt }
    it { expect(subject).to have_db_column :email }
    it { expect(subject).to have_db_column :encrypted_password }
    it { expect(subject).to have_db_column :admin }
    it { expect(subject).to have_db_column :dob }
    it { expect(subject).to have_db_column :gender }
    it { expect(subject).to have_db_column :created_at }
    it { expect(subject).to have_db_column :updated_at }
    it { expect(subject).to have_db_column :ban_reason }
    it { expect(subject).to have_db_column :hidden_reason }
    it { expect(subject).to have_db_column :star_count }
    it { expect(subject).to have_db_column :posts_count }
    it { expect(subject).to have_db_column :messages_received_count }
    it { expect(subject).to have_db_column :active_conversations_count }
    it { expect(subject).to have_db_column :last_active_at }

    it { expect(subject).to have_db_column :location_id }
    it { expect(subject).to have_db_column :estimated_dob }
    it { expect(subject).to have_db_column :star_reason }
    it { expect(subject).to have_db_column :email_verification_token }
    it { expect(subject).to have_db_column :email_verification_deadline }
    it { expect(subject).to have_db_column :is_email_verified }
    it { expect(subject).to have_db_column :uuid }
    it { expect(subject).to have_db_column :referral_link }
  end
end
