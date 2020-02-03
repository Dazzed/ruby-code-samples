class GuessGame < ActiveRecord::Base
  include GuessGameHelper
  include NotificationHelper
  include FirebaseHelper

  has_many :answers, class_name: 'GuessGameAnswer', dependent: :destroy     # this should be dependen destroyed by user
  belongs_to :user_message, class_name: 'UserMessage', dependent: :destroy  # this should be dependen destroyed by user
  belongs_to :by_user, class_name: 'User', foreign_key: 'by_user_id'
  belongs_to :about_user, class_name: 'User', foreign_key: 'about_user_id'

  def serializable_hash(options = {})
    result = super(options)

    result.delete('user_message_id')
    result.delete('have_all_answers')

    result["is_guessing_done"] = self.have_all_answers
    result["current_guesses"] = self.answers.count
    result["total_guesses_needed"] = max_game_questions()
    result["score"] = score_game(self.answers) if self.is_guessing_scored

    result
  end

  def by_user_photo_url
    self.by_user.profile_photo
  end

  def about_user_photo_url
    self.about_user.profile_photo
  end

  def is_guessing_scored
    return is_guessing_game_scored(self.answers)
  end

  def score
    return score_game(self.answers)
  end

  def check_if_game_has_all_answers
    is_guessing_done = does_game_have_all_guesses(self.answers)
    self.update_attribute :have_all_answers, is_guessing_done if is_guessing_done != self.have_all_answers
  end

  def check_after_by_user_guesses
    self.check(self.by_user)
  end

  def check_after_about_user_answers
    self.check(self.about_user)
  end

  # !IMPORTANT: This game code is a bit convoluted but here are the cases its trying to handle
  # 1. Guesser completes all guesses in a game, but, game cannot be scored because guessee has not answered - Create user message and send push notification to guessee
  # 2. Guesser completes all guesses in a game, and game can be scored because guessee has already answered those questions - Create user message and send push notification to guessee with score
  # 3. Guessee has answered all questions in a game, and the game can now be scored - Update existing user message in chat and send push notification to guesser letting them know that they can see their correct guesses.

  def check(user_who_last_answered)
    if self.have_all_answers
      if self.is_guessing_scored
        score = (self.score*100).to_i
        msg_text, push_text = generate_messages_for_scored_game(user_who_last_answered, score)
        create_or_update_game_message(msg_text, push_text, user_who_last_answered)
      elsif self.user_message.nil?
        msg_text, push_text = generate_messages_for_guessing_done()
        create_or_update_game_message(msg_text, push_text, user_who_last_answered)
      end
    end
  end

  def generate_messages_for_scored_game(user_who_last_answered, score)
    # gender_pronoun = self.by_user.gender == 'male' ? 'he' : 'she'
    msg_text = "#{self.by_user.first_name} made some guesses and was #{score}% right about you."
    msg_text += "#{self.by_user.first_name} seems to get you." if score >= 70
    push_text = msg_text
    push_text = "You were #{score}% right about #{self.about_user.first_name}. See your results" if user_who_last_answered != self.by_user

    return msg_text, push_text
  end

  def generate_messages_for_guessing_done
    gender_pronoun = (self.by_user.gender == 'male') ? 'he' : 'she'
    msg_text = "#{self.by_user.first_name} made some guesses about you.  See if #{ gender_pronoun } was right."

    client_version = self.about_user.user_settings.client_version
    msg_text += "\r\n\r\n #{unsupported_message(client_version)}" if client_version && !support_guessgame?(client_version)

    return msg_text, msg_text
  end

  def create_or_update_game_message(msg_text, push_text, user_who_last_answered)
    # do not message if user has blocked me
    return nil if self.about_user.blocked_users.include?(self.by_user) || self.by_user.blocked_users.include?(self.about_user)

    self.with_lock do  # !IMPORTANT: this lock seems to protect if frontend is sending duplicate POST answers. May need some looking into

      if self.user_message.nil?
        msg_was_created = true
        self.user_message = UserMessage.new(
          user_id: self.by_user.id,
          recipient_user_id: self.about_user.id,
          text: msg_text,
          game: self
        )
      else
        msg_was_created = false
        self.user_message.update_attribute(:text, msg_text)
      end

      # lock on target user as they may be reading their messages right now (and thereby updating their messages' read_by_recipient flag) and/or updating the relevant Conversation...
      self.user_message.recipient_user.with_lock do
        self.user_message.conversation = Conversation.for_users(self.user_message.user.id, self.user_message.recipient_user.id) if !self.user_message.conversation
        if !self.user_message.conversation
          # create our conversation
          self.user_message.conversation = Conversation.create!(
            initiating_user: self.user_message.user,
            target_user: self.user_message.recipient_user,
            initiating_message: self.user_message,
            most_recent_message: self.user_message,
            expires_at: Time.now + 24.hours
          )
        else
          self.user_message.conversation.most_recent_message = self.user_message
          self.user_message.conversation.expires_at = Time.now + 24.hours
          self.user_message.conversation.save!
          self.user_message.updated_at = Time.now
          self.user_message.created_at = Time.now
        end

        if self.user_message.save
          self.save  if msg_was_created  # save game with user_message

          # make sure this gets set since the message hadn't been created previously
          self.user_message.conversation.update_attribute(:most_recent_message, self.user_message) if msg_was_created

          # we also need to update the updated_at time stamp so we can sort these conversations based on activity
          self.user_message.conversation.update_attribute :hidden_by_target_user, false
          self.user_message.conversation.update_attribute :hidden_by_initiating_user, false
          self.user_message.conversation.update_attribute :updated_at, Time.now

          self.user_message.conversation.reset_unread_counts

          # update user counts
          recipient_user = self.user_message.recipient_user
          recipient_user.update_attribute :messages_received_count, recipient_user.messages_received_count + 1 if msg_was_created
          recipient_user.update_attribute :active_conversations_count, recipient_user.conversations.where(:is_active => true).count
          self.user_message.user.update_attribute :active_conversations_count, self.user_message.user.conversations.where(:is_active => true).count

          # setup push recipients
          if user_who_last_answered == self.by_user
            push_sender = self.by_user
            push_recipient = self.about_user
          else
            push_sender = self.about_user
            push_recipient = self.by_user
          end

          send_new_message_push_to(push_sender, push_recipient, push_text)

          firebase_send_message(self.user_message) unless !msg_was_created
        end
      end

    end
  end
end
