class GuessGameController < ApplicationController
  include GuessGameHelper

  before_filter :authenticate, except: [:guess, :answer_anonymously, :update_anonymous_name]

  def index
    games = GuessGame.where(about_user: current_user)

    games = games.group(:about_user_id) if params[:unique_people]

    if params[:filter] == "unfinished"
      games = games.where(have_all_answers: true)
      games = games.select{ |g| !g.is_guessing_scored }
    end

    respond_to do |format|
      response.status = 200
      format.json { render json: {
        games: games.as_json(methods: [:by_user_photo_url])
      }}
    end

  end

  def show
    game = GuessGame.find_by(id: params[:id].to_i)

    return render json: { error: 'Game id is invalid.' }, status: 403 if game.nil?

    return render json: { error: 'You are not a participant in this game.' }, status: 403 if game.by_user != current_user && game.about_user != current_user

    respond_to do |format|
      response.status = 200
      format.json { render json: {
        game: get_full_game(game)
      }}
    end
  end

  def link
    if can_share_guessgame?(current_user)
      rankings = get_anon_rankings_for(current_user)
      host_url = "#{configatron.app_host_url}" == "configatron.app_host_url" ? root_url : "#{configatron.app_host_url}/"  # !HACK: ugly check
      return render json: {
        error: false,
        url: "#{host_url}guess_game/guess?user_id=#{current_user.id}",
        max_guesses: anon_max_guesses(),
        anonymous_guesser_count: rankings.count,
        anonymous_friend_count: rankings.select{|r| r.score >= 0.5 }.count
      }
    else
      return render json: {"error":true, "error_message":"you have not answered sufficient questions about yourself to invite others", max_guesses: @@anon_max_guesses}
    end
  end

  def guess
    @user = User.find(params[:user_id]) if !params[:user_id].nil?
    @user = User.first if @user.nil?  # !FIXME: this is kind of hacky

    @questions = get_random_questions_user_has_answered(@user, @@anon_max_guesses)
    @questions_json =  @questions.to_json(include: {choices: {:me => false}}, name: @user.first_name)
    @download_link =  configatron.app_download_link_for_guessgame_share
    @localytics_api_key = ENV["LOCALYTICS_APP_KEY"] || "e591ce716aca9aa781ba9bb-e5f89a1e-5b52-11e6-b2a4-00342b7f5075"

    render layout: "guess_game"
  end

  def answer_anonymously
    about_user = User.find_by(id: params[:about_user_id].to_i) if params[:about_user_id]
    return render json: {error: true, message: "Unable to find user"}, status: 403 if about_user.nil?

    answers = answer_anon(params[:source], params[:uuid], about_user, params[:choice_ids])
    rankings = get_anon_rankings_for(about_user)

    SendEventToCustomerIOJob.perform_later("server_received_anonymous_guesses", about_user.id, {
      anonymous_guesser_count: rankings.count,
      anonymous_friend_count: rankings.select{|r| r.score >= 0.5 }.count
    })

    return render json: {
      rankings: rankings
    }, status: 200
  end

  def update_anonymous_name
    uuid = params[:uuid]
    name = params[:name]
    return render json: {error: true, message: "Missing uuid"}, status: 400 if uuid.nil? || name.nil?
    AnonGuessGameAnswer.where(uuid: uuid).update_all name: name
    return render json: {message: "success!", name: name}, status: 200
  end

  def response_for_unanswered_game_questions(game_id)
    game = GuessGame.find_by(id: game_id)
    return render json: { error: 'Invalid game id.' }, status: 403 if game.nil?

    return render json: { error: 'This game is not about you.' }, status: 403 if game.about_user != current_user

    questions = get_unanswered_game_questions_using(game)
    return render json: {
        guess_game_questions: questions.as_json(include: {choices: {:me => true}}),
    }, status: 200
  end

  def response_for_single_question(question_id)
    question = GuessGameQuestion.find_by(id: question_id)
    return render json: { error: 'Invalid question id.' }, status: 403 if question.nil?

    return render json: {
        about_user: current_user.as_json(include: :user_photos, :current_user_id => current_user.id),
        guess_game_question: question.as_json(include: {choices: {:me => true}})
    }, status: 200
  end

  # GET questions to guess on someone else or
  def questions
    @current_user = current_user
    if params[:question_id]
      return response_for_single_question(params[:question_id].to_i)
    elsif params[:game_id]
      return response_for_unanswered_game_questions(params[:game_id].to_i)
    elsif params[:about_user_id]
      @about_user = User.find_by(id: params[:about_user_id].to_i)
    else
      @about_user = @current_user
    end

    @questions = get_questions(@current_user, @about_user, params[:max])

    if @current_user != @about_user
      @questions_for_me = get_questions_I_should_answer_today(@current_user)
      @questions_for_me_json = @questions_for_me.as_json(include: {choices: {:me => true}})
      @questions_json = @questions.as_json(include: :choices, :name => @about_user.first_name)
    else
      @questions_json = @questions.as_json(include: {choices: {:me => true}})
    end

    render json: {
        about_user: @about_user.as_json(include: :user_photos, :current_user_id => @current_user.id),
        guess_game_questions: @questions_json,
        questions_for_me: @questions_for_me_json
      }
  end

  def response_for_one_answer(by_user, about_user, guess_game_choice_id)
    answer = answer_question(current_user, about_user, guess_game_choice_id)
    return render json: {
      answer: answer.as_json(include: [:question], methods: [:text]),
      about_user: about_user.as_json(include: :user_photos, :current_user_id => current_user.id),
      game: answer.game
    }, status: 200
  end

  # POST answers as guesses for someone else or to answer your own questions
  def answer
    if params[:about_user_id]
      about_user = User.find_by(id: params[:about_user_id].to_i)
    else
      about_user = current_user
    end

    # update current_user's last post to since they are active on the app now
    current_user.posts.where(deleted: false).order(created_at: :desc).first&.update_attribute  :user_last_active_at, Time.now

    return render json: { error: 'The user you want to guess does not exist.' }, status: 403 if about_user.nil?

    last_answer = nil
    begin
      if params[:guess_game_choice_id]
        return response_for_one_answer(current_user, about_user, params[:guess_game_choice_id].to_i)
      elsif params[:guess_game_choice_ids]
        answers, game = answer_questions(current_user, about_user, params[:guess_game_choice_ids])
      end
    rescue Exceptions::GuessGameError => error
      response = { error: error.message}
      return render json: response, status: 403
    rescue Exception => error
      response = { error: error.message}
      return render json: response, status: 403
    end

    render json: {
      answers: answers.as_json(include: [:question], methods: [:text]),
      about_user: about_user.as_json(include: :user_photos, :current_user_id => current_user.id),
      game: game
    }, status: 200
  end


  def answers
    answers = nil
    if params[:game_id]
      game = GuessGame.find_by(id: params[:game_id].to_i)
      return render json: { error: 'Game id is invalid.' }, status: 403 if game.nil?
      return render json: { error: 'You are not a participant in this game.' }, status: 403 if game.by_user != current_user && game.about_user != current_user
      answers = game.answers
    else
      answers = GuessGameAnswer.where(by_user: current_user).where(about_user: current_user).order('created_at desc')
    end

    answers.includes(:choice)

    respond_to do |format|
      response.status = 200
      format.json { render json: {
        answers: answers.as_json(include: [], methods: [:text])
      }}
    end
  end

  # GET popular guesses about you
  def popular_guesses
    about_user = User.find_by(id: params[:about_user_id].to_i)
    return render json: { error: 'User cannot be found.' }, status: 403 if about_user.nil?

    popular_guesses = get_popular_guesses_about(about_user)

    respond_to do |format|
      response.status = 200
      format.json { render json: {
        popular_guesses: popular_guesses
      }}
    end
  end

end
