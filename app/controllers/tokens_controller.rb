class TokensController < ApplicationController

  include ExternalAuthHelper
  include TokensHelper
  include NotificationHelper
  include UsersHelper

  def create
    user = User.authenticate params[:username],params[:password]
    printf params.inspect
    if user
      Token.where(:user => user).delete_all
      token = Token.generate (user)
    else
      response.status = 403
      render :json => {:errors => "Invalid login"}
      return
    end

    if token.save
      render json: token, :include => :user, :methods => [:access_token, :refresh_token], :except => [:hashed_access_token, :hashed_refresh_token]
    else
      render :json => {:errors => "invalid login"}
    end
  end

  def login
    user = User.find_by_email(params[:email])
    begin
      if user&.authenticate(params[:password])
        refresh_token = user.set_refresh_token
        jwt = JsonWebToken.encode(user_id: user.id)
        render json: {user: user.as_json(current_user_id: user.id), expires_on: jwt.expiration.in_time_zone&.as_json, access_token: jwt.access_token, refresh_token: refresh_token}, status: :ok
      else
        render json: { error: 'unauthorized', message: "Incorrect username/password" }, status: :unauthorized
      end
    rescue => e
      logger.error { "User email: #{params[:email]} - Error: #{e.message}" }
      render json: { error: 'unauthorized', message: "Incorrect username/password" }, status: :unauthorized
    end
  end

  def get_new_access_token
    refresh_token = params[:refresh_token]
    user = User.find_by(refresh_token: Digest::SHA2.hexdigest(refresh_token))
    if !user.nil?
      jwt = JsonWebToken.encode(user_id: user.id)
      new_refresh_token = user.set_refresh_token
      render json: { expires_on: jwt.expiration.in_time_zone&.as_json, access_token: jwt.access_token,refresh_token: new_refresh_token}, status: 200
    else
      render json: { error: "invalid_refresh_token", message: "Refresh Token Not Valid. Please Login" }, status: 400
    end
  end

  def refresh
    token = Token.refresh(params[:refresh_token])
    if token.save
      render json: token, :methods => [:access_token, :refresh_token], :except => [:hashed_access_token, :hashed_refresh_token]
    else
      render :json => {:errors => "refresh token invalid"}
    end
  end

  def web_external_auth
    begin
      user = do_external_auth params[:access_token], params[:provider]
      if user.admin
        sign_in user
        redirect_to '/home'
      else
        redirect_to root_path
      end
    rescue StandardError
      redirect_to root_path, :flash => {:errors => "Unable to link. This account may be linked with another user."}
    end
  end

  def external_auth
    device = nil
    device = Device.find_or_create_by(uuid: params[:device_id]) if params[:device_id]  # client has passed a unique device id see if we have one

    referring_device = nil
    referring_device = Device.find_by(uuid: params[:referring_device_id]) if params[:referring_device_id]  # client has passed a unique device id see if we have one

    begin
      if params[:token][:provider] == "facebook"
        user = do_external_auth params[:token][:access_token], params[:token][:provider], device, referring_device
      elsif params[:token][:provider] == "snapchat"
        user = do_snapchat_auth params[:token][:provider_id], params[:token][:provider], device, referring_device
      end
      refresh_token = user.set_refresh_token
      jwt = JsonWebToken.encode(user_id: user.id)
      render json:
      {
        "id": user.id,
        "expires_on": jwt.expiration.in_time_zone&.as_json,
        "refresh_by": nil,
        "user_id": user.id,
        "provider": params[:token][:provider],
        "access_token": jwt.access_token,
        "refresh_token": refresh_token,
        "user": user.as_json(current_user_id: user.id).merge({"post_count": user.post_count, "virtual_currency_balance": user.virtual_currency_balance, "referral": user.referral}).merge(user_settings: user.user_settings).merge({"is_new": user.is_new,
    		"email": user.email,
		    "device_id": (!user.device.nil?) ?  user.device.uuid : nil,
		    "seconds_until_post_allowed": 0,
		    "is_subscribed": user.is_pro?})
      }
    rescue Exceptions::AuthForbidden => error
      render json: { error: error.message, message: error.message }, status: :forbidden
    rescue Exceptions::AuthFailed => error
      render json: { error: error.message, message: error.message }, status: :unauthorized
    rescue StandardError => error
      print error
      render json: { error: "#{error}", message: "#{error}" }, status: 400
    end
  end

  def destroy
    if current_user and @token
      Token.find_by_unhashed_token(@token).delete
    end

    sign_out
    request.env['HTTP_REFERER'] = nil
    respond_to do |format|
      format.json {
        render :json => {:result => "success"}
      }
      format.html { redirect_to root_path}
    end
  end

  private

  def do_snapchat_auth snapchat_id, provider, device = nil, referring_device = nil
    errors = {}
    user = nil

    user = User.find_by(:provider => provider, :provider_id => snapchat_id)
    created_user = false
    unless user
      user = create_new_snapchat_user(snapchat_id, provider)
      created_user = true
    end

    user = save_user_and_device(user, device, created_user, referring_device)

    check_if_unbanded_user(user)

    # return the user
    user
  end

  def do_external_auth access_token, provider, device = nil, referring_device = nil
    errors = {}
    user = nil

    # validate the token first by pulling the external id for the token
    external_id = User.external_id_for_token access_token, provider
    raise Exceptions::AuthFailed, 'Facebook API access failed.' unless external_id
    user = User.find_by(:provider => provider, :provider_id => external_id)
    created_user = false
    unless user
      user = create_new_user(access_token, provider)
      if user.new_record?
        created_user = true
      end
    end

    user = save_user_and_device(user, device, created_user, referring_device)

    check_if_unbanded_user(user)

    if created_user
      create_external_auth_provider(user, external_id, provider)
      send_sns_notification 'user_registered', { userId: user.id, fbToken: access_token }
      initiate_email_verification(user)
    end

    # return the user
    user
  end

  def save_user_and_device(user, device, created_user, referring_device)
    user.uuid = device.uuid if device # add the uuid to user. this is used to track clone accounts

    # check if a blacklisted device is logging in.
    user.hidden_reason = 'device is blacklisted' if device_blacklisted?(device, user)

    if created_user && device && User.find_by(uuid: device.uuid, admin: false)
      previous_user = User.find_by(uuid: device.uuid, admin: false)
      provider = (previous_user.provider.nil? || previous_user.provider.empty?) ? "email" : previous_user.provider
      raise Exceptions::AuthFailed, "You seem to already have an account registered using #{provider}. Try logging in with that before contacting support@friendedmail.com."
    end

    # validate the everything saves correctly and link the new token with the user
    if !user.save
      raise "Problem saving user account: #{user.errors.full_messages.join(',')}"
    end

    # update device record to associate with this user
    associate_user_with_device(user, device)

    # !IMPORTANT: after user is saved, if user is underage the hidde_reason/ban_reason will be filled so we need to update the device blacklist state
    user.set_device_blacklist_state

    # add a referral if we were provided a referring user id
    # IMPORTANT: this must come after device is created
    referral = user.referred_by(referring_device) if referring_device

    # save Cohort if cohorts feature is enabled
    if CONFIG[:enable_cohorts] && created_user
      if cohort_override = params[:cohort_name]
        cohort = Cohort.find_by(name: cohort_override)
        user.user_settings.save_cohort(cohort.id) if cohort
      else
        assign_ab_alternative(user)
      end
    end

    unless validate_ip(user)
      raise Exceptions::AuthFailed, 'Unfortunately, Friended is not available in your country. Please contact support@friendedmail.com if this has been an error'
    end

    # raise an error if during user.save user was detected to be underage and then banned
    raise Exceptions::AuthFailed, user.ban_reason if user.banned?

    # return the token
    user
  end

  def save_user!(user)
    return false unless user.save!
  end

  def create_new_snapchat_user(snapchat_id, provider)
    # generate a password since it is requred.
    password = generated_password
    user = User.new
    user.password = password
    user.password_confirmation = user.password
    user.provider = provider
    user.provider_id = snapchat_id
    user.gender = UNKNOWN
    user.estimated_dob = true
    user
  end

  def create_new_user(access_token, provider)
    # generate a password since it is requred.
    password = generated_password
    create_user_from_external_token(access_token, provider, password)
  end

  def create_user_from_external_token(access_token, provider, password)
    user = User.from_external_token access_token, provider
    user.password = password
    user.password_confirmation = user.password
    user
  end

  def create_external_auth_provider(user, external_id, provider)
    e = ExternalAuthProvider.new
    e.provider_id = external_id
    e.provider_type = provider
    e.user = user
    e.save!
  end

end
