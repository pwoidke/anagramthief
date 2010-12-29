class PlayController < ApplicationController
  require 'term/ansicolor'
  require 'pp'
  include Term::ANSIColor

  before_filter :load_game, :except => [:list]
  after_filter :save_game, :except => [:list]
  helper_method :jchan

  def list
    require_user or return

    @games = Game.all
  end

  def load_game
    require_user or return
    @me = current_user
    @me_id = @me.id_s

    if params[:id]
      @game_id = params[:id]
      if !@me.game_id or @me.game_id != @game_id
        # update the old game
        #jpublish_refresh_state @me.game.id
        # FIXME can't have -all- clients asking for refresh to be published

        @me.game_id = @game_id
        @me.save
      end
    else
      @game_id = @me.game_id
    end

    begin
      @game = Game.find(@game_id)
    rescue ActiveRecord::RecordNotFound
      redirect_to play_list_url unless @game
      return
    end

    @state = GameState.load @game_id
    unless @state
      logger.info "Creating GameState #{@game_id}"
      @state = GameState.new @game_id
      @state.restart
    else
      logger.debug "Loaded game: #{@state.to_json}"
    end

    just_joined = !@state.players.include?(@me_id)
    @state.add_player(@me_id) if just_joined

    @state.player(@me_id).beat_heart

    @state.load_player_users
    became_active, became_inactive =
      @state.update_active_players @game.users.map {|u| u.id_s}

    @players = @state.players_order.map{|id| @state.player(id)}

    became_active << @me_id if just_joined
    jpublish_players_update :added => became_active unless
      became_active.empty? and became_inactive.empty?
  end

  def save_game
    #purged = @state.purge_inactive_players
    purged = nil
    if purged
      jpublish_players_update :removed => purged
    end

    #unless @state.is_saved
      @state.save
      logger.debug 'Saved game: '+@state.to_json
    #end
  end

  def play
    # Render template, show state
  end

  def heartbeat
    render :text => 'OK'
  end

  def flip_char
    char = @state.flip_char
    if char
      jpublish 'pool_update', @me, :body => render_to_string(:partial => 'pool_info')

      msg = "flipped '#{char}'"

      jpublish 'action', @me, :body => msg

      render :json => {:status => true}
    else
      render :json => {:status => false, :message => 'No more letters to flip.'}
    end
  end

  def claim
    word = params[:word].upcase

    result, new_word, words_stolen, pool_used =
      @state.claim_word(@me_id, word)

    case result
    when :ok then
      jpublish_players_update :new_word_id => [@me_id, new_word.id]
      jpublish_pool_update

      pool_used_letters = []
      pool_used.each do |ltr, ct|
        pool_used_letters += [ltr] * ct
      end
      
      msg = "claimed #{word} by"
      msg += " stealing #{words_stolen.join ', '}" unless words_stolen.empty?
      msg += " and" unless words_stolen.empty? or pool_used_letters.empty?
      msg += " taking #{pool_used_letters.join ', '}"

      jpublish 'action', @me, :body => msg
      render :json => {:status => true}

    when :word_too_short then
      jpublish 'action', @me, :body => "tried to claim #{word}, but it's too short"

      render :json => {:status => false}
      #render :json => {:status => false,
        #:message => "#{word} is too short"}

    when :word_not_in_dict then
      jpublish 'action', @me, :body => "tried to claim #{word}, but it's not in the dictionary"

      render :json => {:status => false}
      #render :json => {:status => false,
        #:message => "#{word} is not in the dictionary"}

    when :word_not_extended then
      jpublish 'action', @me, :body => "tried to claim #{word}, but it would be stealing without extending"

      render :json => {:status => false}
      #render :json => {:status => false,
        #:message => "Claiming #{word} would be stealing without extending"}

    when :word_not_available then
      jpublish 'action', @me, :body => "tried to claim #{word}, but it's not on the board"

      render :json => {:status => false}
      #render :json => {:status => false,
        #:message => "#{word} can't be made with the letters on the board"}

    end
  end

  def chat
    jpublish 'chat', @me,
      :body => render_to_string(
        :inline => 'says: <%= message %>',
        :locals => {:message => params[:message]},
      )
    render :text => 'OK'
  end

  def vote_quorum
    (@state.num_active_players + 1) / 2
  end

  def vote_restart
    vote = (params[:vote] != 'false');
    @state.vote_restart(@me_id, vote)

    num_voted = @state.num_voted_restart
    num_needed = vote_quorum

    message = (vote ? 'voted to restart' : 'canceled vote')
    message += "<br />#{num_voted} votes/#{num_needed} needed"

    if num_voted >= num_needed
      message += "<br /><strong>Game Restarted!</strong>"
      @state.restart

      jpublish_pool_update
      jpublish_players_update :restarted => true
    else
      jpublish_players_update
    end

    jpublish 'action', @me, :body => message
    render :text => 'OK'
  end


  protected

  def jpublish_pool_update
    jpublish 'pool_update', nil, :body => render_to_string(:partial => 'pool_info')
  end

  #def jpublish_refresh_state(game_id)
    #jpublish 'refresh_state', nil, {}, game_id
  #end

  def jpublish_players_update(addl={})
    rendered_players = {}
    @state.players.each do |user_id, player| 
      rendered_players[user_id] =
          render_to_string(:partial => 'player', :object => player)
    end
    jpublish 'players_update', nil, {
      :body => rendered_players,
      :order => @state.players_order,
    }.merge(addl)
  end

  def jpublish(type, from_user, data, game_id=nil)
    from = {}
    from = {:from => {
      :id => from_user.id_s,
      :name => from_user.name,
      :first_name => from_user.first_name,
      :last_name => from_user.last_name,
      :profile_pic => from_user.profile_pic,
    }} if from_user

    out = {:type => type}.merge(from).merge(data)
    logger.debug green "**PUBLISH** #{PP.pp out,''}"
    Juggernaut.publish jchan(@game_id), out
  end

  def jchan(id)
    "/anathief/game/#{id}"
  end
end