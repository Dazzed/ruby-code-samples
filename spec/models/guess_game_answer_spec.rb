require 'rails_helper'

RSpec.describe GuessGameAnswer, type: :model do
  describe 'db columns' do
    it { expect(subject).to have_db_column :id }
    it { expect(subject).to have_db_column :guess_game_choice_id }
    it { expect(subject).to have_db_column :by_user_id }
    it { expect(subject).to have_db_column :about_user_id }
    it { expect(subject).to have_db_column :guess_game_id }
    it { expect(subject).to have_db_column :guess_game_question_id }
    it { expect(subject).to have_db_column :is_correct }
    it { expect(subject).to have_db_column :created_at }
    it { expect(subject).to have_db_column :updated_at }
  end

  context "relationships" do
    it { expect(subject).to belong_to(:by_user) }
    it { expect(subject).to belong_to(:about_user) }
    it { expect(subject).to belong_to(:choice) }
    it { expect(subject).to belong_to(:question) }
    it { expect(subject).to belong_to(:game) }
  end

  it 'returns choice text' do
    by_user = Fabricate(:user)
    about_user = Fabricate(:user)
    question = Fabricate(:guess_game_question)
    choice = Fabricate(:guess_game_choice, question: question)
    answer = GuessGameAnswer.create!(by_user: by_user, about_user: about_user, choice: choice)
    expect(answer.text).to eq choice.text
  end

  describe 'when answers are created' do
    it 'automatically assigned a question' do
      by_user = Fabricate(:user)
      about_user = Fabricate(:user)
      question = Fabricate(:guess_game_question)
      choice = Fabricate(:guess_game_choice, question: question)
      answer = GuessGameAnswer.create!(by_user: by_user, about_user: about_user, choice: choice)
      expect(answer.guess_game_question_id).to eq(question.id)
    end

    it 'automatically assigns a game if not answering for yourself' do
      by_user = Fabricate(:user)
      about_user = Fabricate(:user)
      question = Fabricate(:guess_game_question)
      choice = Fabricate(:guess_game_choice, question: question)
      answer = GuessGameAnswer.create!(by_user: by_user, about_user: about_user, choice: choice)
      expect(answer.game).not_to eq nil
    end

    it 'triggers a check answers job if answers a question about me' do
      ActiveJob::Base.queue_adapter = :test
      by_user = Fabricate(:user)
      about_user = Fabricate(:user)
      question = Fabricate(:guess_game_question)
      choice = Fabricate(:guess_game_choice, question: question)
      answer = GuessGameAnswer.new(by_user: by_user, about_user: by_user, choice: choice)
      expect {
        answer.save
      }.to have_enqueued_job(ScoreGuessGameAnswersJob).with(answer.id)
    end

    it 'does not trigger a check answers job if answers a question about someone else' do
      ActiveJob::Base.queue_adapter = :test
      by_user = Fabricate(:user)
      about_user = Fabricate(:user)
      question = Fabricate(:guess_game_question)
      choice = Fabricate(:guess_game_choice, question: question)
      answer = GuessGameAnswer.create!(by_user: by_user, about_user: about_user, choice: choice)
      expect {
        answer.save
      }.not_to have_enqueued_job(ScoreGuessGameAnswersJob).with(answer.id)
    end

  end
end
