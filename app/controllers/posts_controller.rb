class PostsController < ApplicationController

  include StringsHelper
  include NotificationHelper

  before_filter :authenticate, :except => [:build]
  before_filter :correct_user, :only => [:update, :save_image, :destroy, :repost]

  def create
    # see if the user is allowed to post first
    # if we pass the ignore param, skip this check
    if !params['ignore-limit']

      # see if the last post was made after the allowed post interval
      # we also check the posts count to avoid hitting this issue when a post is made just after the tutorial
      seconds_left = current_user.seconds_until_post_allowed
      if seconds_left > 0
        # if it was then we must have a purchased post remaining or throw a 403
        if current_user.user_settings.purchased_posts_remaining <= 0
          response.status = 403
          render json: { error: "You are not allowed to post for #{(current_user.seconds_until_post_allowed / 60).to_i} minutes", exceeded_post_limit: true }
          return
        else
          if !current_user.is_pro?


            should_decrement_remaining_posts = true
          end
        end
      end
    end

    # remove the ignore limit from params if it was passed in
    params.except!('ignore-limit')

    # get our json parameters
    adjusted_params = get_request_as_json(params, :post)

    # determine if the user has already posted for this poll question and if so return that object and move on
    existing_post = Post.where(user: current_user.id).where(poll_question_id: params[:poll_question_id]).where(deleted: false).first
    if existing_post
      response.status = 404
      respond_to do |format|
        format.json { render json: {success: false, error: "You've already posted this icebreaker before"} }
      end
      return
    end

    # verify our response is not profane
    # filter_text = leek_clean adjusted_params[:response_text]
    # if Obscenity.profane?(filter_text)
    #   puts "OBSCENITY: Message rejected #{adjusted_params[:response_text]} due to #{Obscenity.offensive(filter_text)}"
    #   response.status = 400
    #   render json: { error: "Woah there! Would you kiss your mother with that mouth? Try again.", profane: true }
    #   return
    # end

    # perform special logic to allow the client to pass in an image or image url
    image = nil

    # rename image_url to external_image_url if it was supplied
    if adjusted_params[:image_url]
      adjusted_params[:external_image_url] = adjusted_params[:image_url]
      adjusted_params.except!(:image_url, :base64_image)

    # if we were supplied a base64 version of the image file, parse it and load it
    elsif adjusted_params[:base64_image]

      # create a temp file from the image
      tempfile = Tempfile.new("photoupload")
      tempfile.binmode
      tempfile << Base64.decode64(params[:base64_image])
      tempfile.rewind

      # remove the base64 parameter before we try to parse the post object json
      # as well as any other image parameters
      adjusted_params.except!(:base64_image, :image_url, :external_image_url)

      # create our image
      image = ActionDispatch::Http::UploadedFile.new({ filename: 'post_image.jpeg', type: 'image/jpeg', tempfile: tempfile })
    end

    # trip our white space
    adjusted_params[:response_text] = adjusted_params[:response_text].strip if adjusted_params[:response_text]

    # create our post from json params
    @object = Post.new(adjusted_params)

    # denormalize user filters to post
    @object.gender = current_user.gender
    @object.dob = current_user.dob  if current_user.unbanded_user.nil? && !current_user.admin # do not set dob if unbanded user
    @object.location_id = current_user.location_id

    # set our image to the base64 encoded version if we passed it in
    @object.image = image

    @object.mood = "friendly" if !@object.mood || @object.mood == "" || @object.mood == nil

    # !IMPORTANT: set needs_moderation flag. If user does not have a publicly viewable photo, do not allow their post to be viewable by setting needs_moderation = true
    @object.needs_moderation = current_user.primary_photo&.url ? false : true
    @object.moderated = false

    # set our poll question and user for this post
    if params[:poll_question_id]
      @object.poll_question = PollQuestion.find(params[:poll_question_id])
    end
    @object.user = current_user

    ActiveRecord::Base.transaction do
      # check if Post is solicitation attempt
      solicitation = PostFilter.matches?(@object.response_text)

      if @object.save
        flag_user_suspended!(@object.id) if solicitation

        # GeneratePostImageJob.set(wait: 3.seconds).perform_later(@object.id) unless solicitation

        current_user.update_post_allowed_interval!

        # We are no longer going to send pushes to people who are following you.
        # send_sns_notification 'icebreaker_posted', { postId: @object.id, userId: current_user_id, postText: @object.response_text } unless current_user.hidden?

        UpdateFriendsWithNewPostJob.perform_later(@object.id) unless current_user.hidden?

        # decrement our remaining paid posts if we are supposed to
        if should_decrement_remaining_posts
          current_user.user_settings.purchased_posts_used = current_user.user_settings.purchased_posts_used + 1
          current_user.user_settings.save
        end

        respond_to do |format|
          format.json { render json: @object }
        end

      else
        respond_to do |format|
          format.json { render json: { result: 'Error' } }
        end
      end
    end
  end

  def show
    id = params[:id]

    begin
      @object = Post.find(params[:id])
    rescue => e
      response.status = 404
      render :json => {:error => "This post has been removed"}
      return
    end

    #add a page view
    PageView.add_for_post @object, current_user

    respond_to do |format|
      format.json { render json: { result: @object.as_json(include: [:poll_question, :user], methods: [:rating_count, :page_view_count]) } }
      format.html
    end

  end

  def update
    # load old post
    @object = Post.find params[:id]

    # get our json parameters
    adjusted_params = get_request_as_json(params, :post)

    # perform special logic to allow the client to pass in an image or image url
    image = nil

    # rename image_url to external_image_url if it was supplied
    # NOTE: the client may pass in the image URL, which was returned as a link to our amazon s3 resource.
    #  in this case, with the code below we'll handle it like it is an external url and thus the tokens
    # won't generate properly. In order to avoid this case, we check for the amazon s3 bucket url and ignore
    # the passed in URL if it matches this case

    if adjusted_params[:image_url] && !adjusted_params[:base64_image]

      # if we have an internal saved image, ensure that this url wasn't just passed right back to us. If it was, then
      # this is just the same image and we shouldn't set it as an external url- or it will not get properly tokenized
      if !@object.image_url or !adjusted_params[:image_url].include? URI.parse(@object.image_url).host
        adjusted_params[:external_image_url] = adjusted_params[:image_url]
      end

      adjusted_params.except!(:image_url, :base64_image)

      # if we were supplied a base64 version of the image file, parse it and load it
    elsif adjusted_params[:base64_image]

      # remove the old image if it existed
      @object.external_image_url = nil
      @object.remove_image! if @object.image
      @object.save!

      # create a temp file from the image
      tempfile = Tempfile.new("photoupload")
      tempfile.binmode
      tempfile << Base64.decode64(params[:base64_image])
      tempfile.rewind

      # remove the base64 parameter before we try to parse the post object json
      # as well as any other image parameters
      adjusted_params.except!(:base64_image, :image_url, :external_image_url)

      # create our image
      image = ActionDispatch::Http::UploadedFile.new({ filename: 'post_image.jpeg', type: 'image/jpeg', tempfile: tempfile })
    end

    # set our image to the base64 encoded version if we passed it in
    @object.image = image

    ActiveRecord::Base.transaction do
      # check if Post is solicitation attempt
      solicitation = PostFilter.matches?(adjusted_params[:response_text])

      # update the object with the json parameters hash
      if @object.update_attributes(adjusted_params)
        flag_user_suspended!(@object.id) if solicitation

        respond_to do |format|
          format.json { render json: @object }
        end
      else
        respond_to do |format|
          format.json { render json: { result: 'Error' } }
        end
      end
    end
  end

  def index
    # ensure we passed in a user param unless we are admin
    if !params[:user_id] and !current_user.admin
      deny_access
      return
    end

    @objects = Post.where(:deleted => false)

    if params[:user_id]

      @user = User.find(params[:user_id])

      @objects = @objects.where(:user_id => @user).order("posts.created_at DESC")
    end

    if params[:search]
      @objects = @objects.where("response_text LIKE (?)", "%#{params[:search]}%")
    end

    # TODO v1.01 uses this data from the users/id endpoint. This is only here for backwards compat. Remove when appropriate
    #  is_friend = false
    #  conversation_id = nil
    #  if params[:user_id] and params[:user_id].to_i != current_user.id
    #    other_user = User.find(params[:user_id])
    #    is_friend = other_user.followed_by? current_user
    #    conversation = Conversation.for_users_and_post other_user, current_user, nil
    #    conversation_id = conversation.id if conversation
    #  elsif params[:user_id] and params[:user_id].to_i == current_user.id
    #    add_unread_count = true
    #  end

    if params[:max]
      @objects = @objects.limit(params[:max])
    end

    rating_ids = current_user.liked_posts.collect(&:id)
    @objects = @objects.includes({:conversations =>  [{:initiating_user => [:user_settings]}, {:target_user => [ :user_settings]} ]}, :page_views, :poll_question)

    respond_to do |format|
      format.json  {
        if params[:offset]
          limit = params[:max] || 10
          total = @objects.count
          @objects = @objects.offset(params[:offset]).limit(limit)
          render :json => {:results => @objects.as_json(:include => :poll_question, :methods => (@user.id == current_user.id) ? [:page_view_count, :rating_count] : [:rating_count], :rated_ids => rating_ids), max: limit.to_i, offset: params[:offset].to_i, total: total }
        else
          render :json => {:results => @objects.as_json(:include => :poll_question, :methods => (@user.id == current_user.id) ? [:page_view_count, :rating_count] : [:rating_count], :rated_ids => rating_ids) }
        end
        @objects = nil # for gc
      }
      format.html {
        @objects = @objects.order("posts.created_at desc")
        @objects = @objects.paginate( :page => params[:page] )
      }
    end
  end


  # filter logic for the feed as of 1-17-18
  #  1- filter to only posts that have been flagged less than 3 times and have not been deleted
  #  2- filter out posts created by the current user
  #  3- filter out any posts by users who you have blocked or that have blocked you
  #  4- filter out any posts that have been explicitly skipped by the client
  #  5- filter out any posts that the user has rated or skipped
  #  6- filter out any posts that you have answered
  #  7- if the gender filter is provided, filter to those
  #  8- if the friends parameter is supplied filter to only users you are following
  #  9- apply the max offset supplied, run the query, sort by creation date and return
  def feed
    rendered_posts = now_posts or []
    rendered_posts += posts_from_last_active(rendered_posts.map{|p| p["id"]}) if rendered_posts.empty? || (params[:max] && rendered_posts.count < params[:max].to_i)
    rendered_posts += recent_posts(rendered_posts.map{|p| p["id"]}) if rendered_posts.empty? || (params[:max] && rendered_posts.count < params[:max].to_i)
    rendered_posts += all_posts(rendered_posts.map{|p| p["id"]}) if rendered_posts.empty? || (params[:max] && rendered_posts.count < params[:max].to_i)

    rendered_posts = rendered_posts.take(params[:max].to_i) if params[:max]

    respond_to do |format|
      format.json { render json: { results: rendered_posts } }
    end
  end

  def conversations
    post = Post.find_by(id: params[:id])
    unless post
      response.status = 404
      render json: { error: 'This post has been removed' }
      return
    end

    if post.user != current_user
      deny_access
      return
    end

    blocked_ids = current_user.blocked_ids
    post_replies = UserMessage.user_visible.where(initiating_post: post).where.not(user_id: blocked_ids).select(:conversation_id, :text)
    conversations_ids = post_replies.collect(&:conversation_id)

    # create a map of all the post reply text by conversation id, so we can render the initiating message
    post_reply_by_conversation = {}
    post_replies.each do |reply|
      post_reply_by_conversation[reply.conversation_id] =  reply.text
    end
    results = Conversation.where(id: conversations_ids).order("most_recent_message_id desc")

    # reduce queries
    results = results.includes([
              {
                initiating_user: [
                  :user_settings,
                  :friendships,
                  :friend_requests,
                  :location
                ]
              },
              {
                target_user: [
                  :user_settings,
                  :friendships,
                  :friend_requests,
                  :location
                ]
              }
            ])

    respond_to do |format|
      format.json { render json: { results: results.as_json(include: [], methods: [], current_user: current_user, unread_count_for_user_id: current_user_id, post_reply_by_conversation: post_reply_by_conversation) } }
    end
  end

  def save_image
    if @object.user != current_user
      deny_access
      #since deny access assumes content type is html if it is not
      return
    end

    tempfile = Tempfile.new("photoupload")
    tempfile.binmode
    tempfile << request.body.read
    tempfile.rewind

    photo_params = params.slice(:filename, :type, :head).merge(:tempfile => tempfile)
    photo = ActionDispatch::Http::UploadedFile.new(photo_params)

    #set our post variables
    @object.external_image_url = nil
    @object.image = photo

    if @object.save
      render :json => @object
    else
      format.json  { render :json => {:result => "failure", :errors => errors}
      @object = nil #for gc
      }
    end
  end

  def destroy
    @object.deleted = true
    @object.save!

    respond_to do |format|
      format.json  {render :json => {:result => "success"}}
      format.html  {redirect_to posts_path, :flash => {:success => "Object Deleted"}}
    end
  end

  def flag
    begin
      post = Post.find(params[:id])
    rescue => e
      response.status = 404
      render :json => {:error => "This post has been removed"}
      return
    end

    #make a new post skip for this post / user
    #this will prevent us from flagging more than once per user also
    @object = PostSkip.new
    @object.user = current_user
    @object.post = post
    @object.save!

    #increase the flag count
    post.flag_count = post.flag_count + 1

    if post.flag_count >= 3
      post.update_attribute :deleted, true
    end

    #make sure we don't have an empty poll question which we have seen happen rarely
    if !post.poll_question
      post.destroy
    else
      post.save!
    end

    render :json => post

    @object = nil #for gc
  end

  def repost
    post = Post.find(params[:id])
    post.update_attribute :created_at, Time.zone.now
    render :json => post
  end

  def build  # test rendering html post
    post = Post.find(params[:id])
    original_style = params[:original] ? true : false
    profile_photo_url = post.user.profile_photo ? post.user.profile_photo : nil
    background_image_url = profile_photo_url
    background_image_url = post.image.url ? post.image.url : nil if original_style
    locals = {
      text: "#{post.poll_question.feed_display_format}".gsub(/%@/,"#{post.response_text}"),
      background_image_url: background_image_url,
      background_color: post.background_color ? post.background_color : "#F9306D",
      mood: post.mood,
      profile_photo_url: profile_photo_url,
      first_name: post.user.first_name
    }

    render "renderer", locals: locals, layout: false, status: 200
  end

  private

  def posts_from_last_active(post_ids_to_skip = [])
    posts = fetch_feed("active", post_ids_to_skip)
    logger.debug { "GET /posts/feed - Found #{posts.length} Posts for User: #{current_user.id} with gender: #{params[:gender]}, location_type: #{params[:location_type]} in #{CONSTANTS[:posts_feed_recent_window_minutes]} minutes" }
    PostsFeedResult.create(user: current_user, num_results: posts.length, gender_filter: params[:gender], mood_filter: params[:mood], location_filter: params[:location_type], time_filter: "active-#{CONSTANTS[:last_active_window_minutes]}-mins")
    posts
  end

  def now_posts(post_ids_to_skip = [])
    posts = fetch_feed("now", post_ids_to_skip)
    logger.debug { "GET /posts/feed - Found #{posts.length} Posts for User: #{current_user.id} with gender: #{params[:gender]}, location_type: #{params[:location_type]} in #{CONSTANTS[:posts_feed_recent_window_minutes]} minutes" }
    PostsFeedResult.create(user: current_user, num_results: posts.length, gender_filter: params[:gender], mood_filter: params[:mood], location_filter: params[:location_type], time_filter: "now-#{CONSTANTS[:posts_feed_recent_window_minutes]}-mins")
    posts
  end

  def recent_posts(post_ids_to_skip = [])
    posts = fetch_feed("recent", post_ids_to_skip)
    logger.debug { "GET /posts/feed - Found #{posts.length} Posts for User: #{current_user.id} with gender: #{params[:gender]}, location_type: #{params[:location_type]} in #{CONSTANTS[:posts_feed_timebox_hours]} hours" }
    PostsFeedResult.create(user: current_user, num_results: posts.length, gender_filter: params[:gender], mood_filter: params[:mood], location_filter: params[:location_type], time_filter: "recent-#{CONSTANTS[:posts_feed_timebox_hours]}-hours")
    posts
  end

  def all_posts(post_ids_to_skip = [])
    fetch_feed("all", post_ids_to_skip)
  end

  def fetch_feed(by = "all", post_ids_to_skip = [])
    if by == "active"
      posts = Post.answerable.by_active_users
    elsif by == "now"
      posts = Post.answerable.now
    elsif by == "recent"
      posts = Post.answerable.recent
    else
      posts = Post.answerable
    end

    skip_user_ids = []

    # Filter out posts from this user
    skip_user_ids << current_user.id

    # filter out any where the user has been blacklisted
    skip_user_ids << current_user.sent_user_blocks.select(:blocked_user_id).collect(&:blocked_user_id)
    skip_user_ids << current_user.received_user_blocks.select(:user_id).collect(&:user_id)
    posts = posts.not_user_ids(skip_user_ids.flatten.compact)

    # Filter out any passed in by the skip parameter
    if params[:skip]
      string_array = params[:skip].split(',')
      int_array = string_array.map(&:to_i)
      posts = posts.where.not(id: int_array)
    end

    # filter out any that we have skipped or liked
    skip_ids = by == "recent" || by == "now" ? current_user.post_skips.recent.select(:post_id).collect(&:post_id) : current_user.post_skips.select(:post_id).collect(&:post_id)
    rated_ids = by == "recent" || by == "now" ? current_user.rated_posts.recent.select(:id).collect(&:id) : current_user.rated_posts.select(:id).collect(&:id)
    skip_ids += rated_ids
    skip_ids = skip_ids | post_ids_to_skip
    if skip_ids.count > 0
      posts = posts.where.not(id: skip_ids)
    end

    # filter out any that we have answered
    answered_ids = by == "recent" || by == "now" ? current_user.sent_messages.recent.joins(:initiating_post).select('posts.id').collect(&:id).uniq : current_user.sent_messages.joins(:initiating_post).select('posts.id').collect(&:id).uniq
    if answered_ids.count > 0
      posts = posts.where.not(id: answered_ids)
    end

    if params[:gender] && (params[:gender] == 'male' || params[:gender] == 'female')
      posts = posts.where('posts.gender = ?', params[:gender])
    end

    # apply age filter with current settings
    apply_bands = CONFIG[:post_feed_age_banding] && !current_user.admin? && current_user.unbanded_user.nil?
    if apply_bands && (current_user.user_settings.feed_filter_max || current_user.user_settings.feed_filter_min)
      filtered = posts
      if current_user.user_settings.feed_filter_max
        filtered = filtered.where('posts.dob <= ? or posts.dob is null', current_user.user_settings.feed_filter_min)
      end
      if current_user.user_settings.feed_filter_min
        filtered = filtered.where('posts.dob >= ?  or posts.dob is null', current_user.user_settings.feed_filter_max)
      end

      posts = filtered  # even if filtered.count = 0 we set posts as age banding is required.

    # attempt to apply age filter with new settings
    elsif apply_bands && current_user.dob
      current_max = current_user.dob
      current_min = current_user.dob
      AGE_RANGES.each do |range|
        next unless (current_user.dob < Time.now - range[0].years) && (current_user.dob > Time.now - range[1].years)
        if current_min < Time.now - range[0].years
          current_min = Time.now - range[0].years
        end
        if current_max > Time.now - range[1].years
          current_max = Time.now - range[1].years
        end
      end

      if current_min != current_max
        unfiltered = posts
        filtered = unfiltered.where('(posts.dob <= ? and posts.dob >= ?) or posts.dob is null', current_min,  current_max )
        posts = filtered # even if filtered.count = 0 we set posts as age banding is required.
        current_user.user_settings.update_attribute :feed_filter_max, current_max
        current_user.user_settings.update_attribute :feed_filter_min, current_min
      end
    end

    # filter by mood
    posts = posts.where(mood: params[:mood]) if params[:mood]

    # begin setting up results
    posts = posts.includes([:poll_question, { user: [:user_settings] }])
    if by == "active"
      posts = posts.order(user_last_active_at: :desc)
    else
      posts = posts.order(created_at: :desc)
    end

    # filter by location_type
    if params[:location_type]
      if current_user&.location&.latitude && current_user&.location&.longitude
        case params[:location_type]
        when 'nearby'
          # default ordered by closest first
          near_locations = current_user&.location&.nearbys(CONFIG[:location_distance]) || []
          local_posts = posts.where(location_id: near_locations.map(&:id))
          if by == "active"
            local_posts = local_posts.order(user_last_active_at: :desc)
          else
            local_posts = local_posts.order(created_at: :desc)
          end
          posts = local_posts unless by == "recent" && local_posts.count <= 0
        end
      end
      current_user.user_settings.update_attribute(:location_type, params[:location_type])
    end

    # add paging
    if params[:max]
      posts = posts.limit(params[:max].to_i)
    end

    posts = posts.as_json(include: [:poll_question, :user])
    posts = posts.each{|p| p["created_at"] = p["user_last_active_at"]} if by == "active"  #rewrite the created_at time field so people see a more recent time stamp
    return posts
  end

  def correct_user
    @object = Post.find params[:id]

    if current_user and current_user.admin
      return true
    end

    if @object.user != current_user
      deny_access
    end
  end

  def flag_user_suspended!(post_id)
    current_user.update_attributes!(hidden_reason: "Suspended account: violation of terms #{Time.current.strftime('%Y%m%d')} for Post #{post_id}")
  end
end
