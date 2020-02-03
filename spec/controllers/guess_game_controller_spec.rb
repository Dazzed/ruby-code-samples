require 'rails_helper'

RSpec.describe GuessGameController, type: :controller do
  let(:user) { Fabricate(:user_with_photo) }
  let(:about_user) { Fabricate(:user_with_photo) }
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
    # override custom instance attribute that a reloaded User object will never have and is screwing up our testing
    user.is_new = false
    about_user.is_new = false
    token
    facebook_auth
    allow(ExternalAuthProvider).to receive(:external_id_for_token).with(access_token, 'facebook').and_return(facebook_auth.provider_id)
    request.headers.merge!(headers)
    request.accept = 'application/json'
    # set timezone to EST to faciliate comparing JSON rendered datetimes
    Time.zone = ActiveSupport::TimeZone['Eastern Time (US & Canada)']
  end

  after(:each) do
    Time.zone = ActiveSupport::TimeZone['UTC']
  end

  describe 'GET /guess_game/questions' do
    it 'responds with 200 and returns questions i can answer about someone' do
      questions = []
      5.times do
        questions.push(Fabricate(:guess_game_question))
      end
      get :questions, {about_user_id: about_user.id }
      expect(response.status).to eq 200
      response_question_ids = JSON.parse(response.body)['guess_game_questions'].map {|e| e["id"]}
      response_questions_for_me_ids = JSON.parse(response.body)['questions_for_me'].map {|e| e["id"]}
      response_about_user = JSON.parse(response.body)['about_user']
      questions_ids= questions.as_json(include: {choices: {:me => true}}).map {|e| e["id"]}

      expect(response_about_user).to eq(about_user.as_json(include: :user_photos, current_user_id: user.id))
      expect((response_question_ids-questions_ids).empty?).to eq true
      expect((response_questions_for_me_ids-questions_ids).empty?).to eq true
    end
  end

  describe 'GET /guess_game/popular_guesses' do
    it 'excludes blocked users from popular answers' do
      blocked_user = Fabricate(:user)
      blocking_user = Fabricate(:user)
      blocking = Fabricate(:user_block, user:about_user, blocked_user_id: blocked_user.id)
      blocked = Fabricate(:user_block, user:blocking_user, blocked_user_id: about_user.id)

      answers = []
      choice = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))
      choice2 = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))

      answers.push(Fabricate(:guess_game_answer, by_user: user, about_user: about_user, guess_game_choice_id: choice.id))
      answers.push(Fabricate(:guess_game_answer, by_user: blocked_user, about_user: about_user, guess_game_choice_id: choice.id))
      answers.push(Fabricate(:guess_game_answer, by_user: blocking_user, about_user: about_user, guess_game_choice_id: choice2.id))

      get :popular_guesses, {about_user_id: about_user.id}
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)).to eq({
        "popular_guesses" => [
          {
            "num_answers" => 1,
            "choice" => choice.text,
            "users" => [
              {
                "id" => user.id,
                "photo_url" => user.profile_photo
              }

            ]
          }
        ]
      })
    end

  end

  describe 'POST /guess_game/answer' do
    it 'responds with 200 when answering a question on someone' do
      choice = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))
      post :answer, {about_user_id: about_user.id, guess_game_choice_ids:[choice.id]}
      answer = GuessGameAnswer.last
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)).to eq({
        'answers' => [answer.as_json(include: [:question], methods: [:text])],
        'about_user' => about_user.as_json(include: :user_photos, current_user_id: user.id),
        'game' => answer.game.as_json
      })
    end

    it 'responds with 403 when answering the same question again on someone' do
      choice = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))
      post :answer, {about_user_id: about_user.id, guess_game_choice_ids:[choice.id]}
      post :answer, {about_user_id: about_user.id, guess_game_choice_ids:[choice.id]}
      expect(response.status).to eq 403
    end

    it 'responds with 200 when answering on yourself' do
      choice = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))
      post :answer, {guess_game_choice_ids:[choice.id]}
      answer = GuessGameAnswer.last

      user.reload
      expect(response.status).to eq 200
      expect(JSON.parse(response.body)).to eq({
        'answers' => [answer.as_json(include: [:question], methods: [:text])],
        'about_user' => user.as_json(include: :user_photos, :current_user_id => user.id),
        'game' => nil
      })
    end

    # !TODO: this spec needs to check the actual response.
    it 'responds with 200 and allows you to update answers on yourself yourself' do
      choice1 = Fabricate(:guess_game_choice, question: Fabricate(:guess_game_question))
      choice2 = Fabricate(:guess_game_choice, question: choice1.question)
      post :answer, {guess_game_choice_ids:[choice1.id]}
      post :answer, {guess_game_choice_ids:[choice2.id]}
      user.reload
      expect(response.status).to eq 200
    end

  end

end
