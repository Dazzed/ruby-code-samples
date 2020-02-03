class GuessGameAnswer < ActiveRecord::Base
  include GuessGameHelper

  attr_accessible :by_user_id, :about_user_id, :guess_game_choice_id, :choice, :by_user, :about_user, :game

  validates_presence_of :by_user
  validates_presence_of :about_user
  validates_presence_of :choice
  validates_uniqueness_of :question, scope: [:by_user_id, :about_user_id]  # !IMPORTANT: we moved the uniqueness constraint to the db since this doesn't really work effectively.

  belongs_to :by_user, class_name: 'User', foreign_key: 'by_user_id', inverse_of: :answers
  belongs_to :about_user, class_name: 'User', foreign_key: 'about_user_id', inverse_of: :guesses
  belongs_to :choice, class_name: 'GuessGameChoice', foreign_key: 'guess_game_choice_id'
  belongs_to :question, class_name: 'GuessGameQuestion', foreign_key: 'guess_game_question_id'
  belongs_to :game, class_name: 'GuessGame', foreign_key: 'guess_game_id'

  before_validation :assign_question
  before_create     :assign_game, :check_if_correct
  after_create      :check_if_game_has_all_answers, :by_user_checks_game
  after_save        :correct_answers_about_me_job
  after_destroy     :check_if_game_has_all_answers

  rails_admin do
    excluded_fields = %i(question, game)

    edit do
      exclude_fields(*excluded_fields)
    end
  end

  def serializable_hash(options = {})
    result = super(options)
    result['created_at'] = result['created_at']&.in_time_zone&.as_json
    result['updated_at'] = result['updated_at']&.in_time_zone&.as_json
    return result
  end

  def about_user_checks_game
    self.game.check(self.about_user) if self.game
  end

  def by_user_checks_game_job
    begin
      return unless self.game
      ByUserChecksGameJob.set(wait: 1.second).perform_later(self.game.id)
    rescue Exception => e
      # We rescue any exception so that Job failure does not impact saving to the db.
      logger.error {"Critical error trying to launch ByUserChecksGameJob with GuessGameAnswer.id=#{self.id}"}
    end
  end

  def by_user_checks_game
    self.game.check(self.by_user) if self.game
  end

  def check_if_game_has_all_answers
    return if self.by_user == self.about_user
    self.game&.check_if_game_has_all_answers
  end

  def assign_game
    return if self.by_user == self.about_user
    self.game = get_latest_game(self.by_user, self.about_user)
  end

  def assign_question
    return unless self.guess_game_question_id.nil?
    self.guess_game_question_id = self.choice.question.id
  end

  def check_if_correct
    return unless self.by_user_id != self.about_user_id

    answer = GuessGameAnswer.where(guess_game_question_id: self.guess_game_question_id).where(about_user_id: self.about_user_id).where(by_user_id: self.about_user_id).first
    if answer
      self.is_correct = false
      self.is_correct = true if answer.choice == self.choice
    end
  end

  def correct_answers_about_me_job
    begin
      return unless self.by_user_id == self.about_user_id
      ScoreGuessGameAnswersJob.set(wait: 1.second).perform_later(self.id)
    rescue Exception => e
      # We rescue any exception so that Job failure does not impact saving to the db.
      logger.error {"Critical error trying to launch ScoreGuessGameAnswersJob with GuessGameAnswer.id=#{self.id}"}
    end
  end

  def correct_answers_about_me
    return unless self.by_user_id == self.about_user_id

    answers = GuessGameAnswer.where(guess_game_question_id: self.guess_game_question_id).where(about_user_id: self.by_user_id).where.not(by_user_id: self.by_user_id)
    answers.each do |a|
      a.update_attribute(:is_correct, a.choice == self.choice)   # this will trigger check_game callbacks for all answers which will implement game logic
      a.about_user_checks_game  # trigger check game
    end
  end

  def text
    self.choice.text
  end

end
