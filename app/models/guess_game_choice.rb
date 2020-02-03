class GuessGameChoice < ActiveRecord::Base
  attr_accessible :text, :hidden, :guess_game_question_id, :my_text

  validates :text, :presence => true
  validates :my_text, :presence => true

  belongs_to :question, class_name: 'GuessGameQuestion', inverse_of: :choices, foreign_key: 'guess_game_question_id'
  has_many :answers, class_name: 'GuessGameAnswer', foreign_key: 'guess_game_choice_id', dependent: :destroy

  rails_admin do
    excluded_fields = %i(answers)

    show do
      exclude_fields(*excluded_fields)
    end

    edit do
      exclude_fields(*excluded_fields)
    end
  end

  def serializable_hash(options = {})
    result = super(options)

    result[:text] = self.my_text if options[:me]

    result.delete('my_text')
    result.delete('created_at')
    result.delete('updated_at')
    result.delete('hidden')
    result
  end
end
