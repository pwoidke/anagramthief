require 'em-http-request'
require 'em-synchrony'
require 'cancelable_fiber'

require 'log4r-color'

require 'steal_engine'
#require 'steal_engine_brute'
require 'word_matcher'
require 'random_dists'

include Log4r

class StealBot
  include Log4r
ColorOutputter.new 'color', {:colors =>
  {
    :debug  => :dark_gray,
    :info   => :light_blue,
    :warn   => :yellow,
    :error  => :pink,
    :fatal  => {:color => :red, :background => :white}
  }
}
  @@log = Logger.new('StealBot')
  @@log.add('color')

  MIN_LEN = 3

  def initialize(user_id, lookup_tree, word_ranks, play_token, settings)
    @user_id = user_id
    @lookup_tree = lookup_tree
    @word_ranks = word_ranks
    @play_token = play_token
    self.settings = settings

    @serial = 1
  end

  def settings=(settings)
    @settings = {
      :max_rank => settings['max_rank'] || 30000,
      :max_steal_len => settings['max_steal_len'] || 5,
      :max_word_len => settings['max_word_len'] || 0,
      :delay_ms_mean => settings['delay_ms_mean'] || 1000,
      :delay_ms_stdev => settings['delay_ms_stdev'] || 0,
      :delay_ms_per_kcost => settings['delay_ms_per_kcost'] || 0,
      :delay_ms_per_word_considered => settings['delay_ms_per_word_considered'] || 0,
    }
  end

  def ssend(type, data={})
    serial = @serial
    @serial += 1
    msg = {:_t => type, :_s => serial}.merge(data).to_json
    @@log.debug "#{@user_id}: OUT>> #{msg}"
    @http.send msg
  end

  def got_update(msg)
    @fiber.cancel if @fiber

    @fiber = CancelableFiber.new {
      stealable = []
      msg['players_order'].each do |p_id|
        stealable += msg['players'][p_id]['words']
      end

      pool = msg['pool']

      @@log.info "#{@user_id}: #{stealable} and #{pool}"

      word_filter = lambda {|words| words.select {|w|
        next false if w.length < MIN_LEN

        if @settings[:max_word_len] > 0
          next false if w.length > @settings[:max_word_len]
        end

        if @settings[:max_rank] > 0 and @word_ranks.include? w
          next false if @word_ranks[w] > @settings[:max_rank]
        end

        # Too expensive.
        #t = Time.now
        #match_result = WordMatcher.word_match(pool, stealable, w)
        #t = Time.now - t
        #@@log.error "WM #{w} took #{t}ms"
        #next false unless match_result and match_result[0][0] == :ok

        next true
      }}

      start_time = Time.now

      @lookup_tree.clear_cost
      res, cost = StealEngine.search(
        @lookup_tree,
        pool.shuffle,
        stealable.shuffle,
        @settings[:max_steal_len],
        &word_filter
      )
      t = Time.now - start_time

      @@log.debug "#{@user_id}: Stealengine: #{res || 'nil'} -- took #{t*1000}ms, #{@lookup_tree.accumulated_cost} total cost (== #{cost})"

      unconditional_delay_ms = RandomDists.gaussian(@settings[:delay_ms_mean], @settings[:delay_ms_stdev])
      @@log.debug "#{@user_id}: Unconditional delay: #{unconditional_delay_ms}ms"
      EventMachine::Synchrony.sleep(unconditional_delay_ms/1000.0 - (Time.now - start_time))

      cost_delay_ms = @settings[:delay_ms_per_kcost]*cost/1000.0
      @@log.debug "#{@user_id}: Cost delay: #{cost_delay_ms}ms"
      EventMachine::Synchrony.sleep cost_delay_ms/1000.0

      if res
        word = res[0]
        @@log.info "#{@user_id}: Claiming #{word}"

        ssend 'claim', {:word => word}

      else
        if msg['pool_remaining'] > 0
          @@log.info "#{@user_id}: Flipping char..."

          #EventMachine::Synchrony.sleep 1

          ssend 'flip'
        else
          @@log.info "#{@user_id}: Ending game..."

          ssend 'vote_done', {:vote => true}
        end
      end
    }
    @fiber.resume
  end

  def run
    @@log.info "#{@user_id}: StealBot starting..."

    @http = EventMachine::HttpRequest.new("ws://#{GAME_HOST}:#{GAME_PORT}/websocket").get :timeout => 0
    @http.errback do |e|
      @@log.error "#{@user_id}: StealBot received error: #{e}"
    end
    @http.callback do
      @@log.info "#{@user_id}: Logging in..."
      ssend 'identify', {:id_token => @play_token}
    end
    @http.stream do |msg_|
      @@log.debug "#{@user_id}: IN << #{msg_}"

      begin
        msg = JSON.parse(msg_)

        if msg['_t'] == 'update'
          got_update msg
        end
      rescue StandardError => e
        @@log.error ": (StandardError) #{e.inspect}\n#{e.backtrace.join "\n"}"
      end
    end
    @http.disconnect do
      @@log.info "#{@user_id}: StealBot disconnected."
    end
  end

  def stop
    @@log.info "Stopping bot #{@play_token}"
    if @http
      @fiber.cancel
      @http.close_connection
      @http = nil
    end
  end
end