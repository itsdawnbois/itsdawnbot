require 'dotenv/load'
require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'net/http'
require 'logger'
require 'colorize'

require 'pry'

discord_token = ENV['DISCORD_TOKEN']
log_level = ENV['DEBUG_LEVEL']

module Kernel
  def jitter
    rand
  end

  # tick every x milliseconds
  def tick_every_with_jitter(interval)
    Thread.new do
      loop do
        sleep(interval * jitter)
        yield
      end
    end
  end
end

class Bot
  DISCORD_API_URL = 'https://discord.com/api/'

  def initialize(discord_token, log_level)
    @discord_token = discord_token
    @intent = 33349
    @connected = false
    @gateway_url = get_gateway_url
    @log_level = log_level
    @logger = Logger.new(STDOUT)
  end

  def start
    EM.run do
      self.ws = Faye::WebSocket::Client.new(gateway_url)

      ws.on :open do |event|
        log_event(:open)
      end

      ws.on :message do |event|
        data = JSON.parse(event.data, symbolize_names: true)

        log_event(:message, event.data)

        handle_message(data)
      end

      ws.on :close do |event|
        log_message(:close, [event.code, event.reason].join(', '))
        heartbeat_thread&.kill
        self.ws = nil
      end
    end
  end

  private

  attr_reader :discord_token, :intent, :log_level, :logger
  attr_accessor :ws, :heartbeat_interval, :heartbeat_thread, :s_field,
    :connected, :gateway_url, :session_id

  def jitter
    rand
  end

  def get_gateway_url
    uri = 'https://discord.com/api/gateway/bot'
    uri = URI(uri)
    
    headers = {
      'Authorization' => 'Bot ' + discord_token
    }
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri.request_uri, headers)
    
    response = http.request(request)
    
    puts response.body

    self.gateway_url = "#{JSON.parse(response.body)['url']}?v=10&encoding=json"
  end

  def log_event(event, data = nil)
    logger.add(Logger::INFO, ['Received event:', event, 'with data:', data ? data : 'no data'].join(' '))
  end

  def log_message(type, data)
    logger.add(Logger::INFO, ['Received message of type:', type, ' | with data:', data].join(' '))
  end

  def log_general(message)
    logger.add(Logger::DEBUG, message.colorize(:green))
  end

  def log_error(message)
    logger.add(Logger::ERROR, message.colorize(:red))
  end

  def log_warn(message)
    logger.add(Logger::WARN, message.colorize(:yellow))
  end
  
  def handle_message(data)
    op = data[:op]
    self.s_field = data[:s]
  
    case op
    when 0
      log_message(:dispatch, data)

      case data[:t]
      when 'READY'
        log_general('Bot is ready')

        self.gateway_url = data[:d][:resume_gateway_url]
        self.session_id = data[:d][:session_id]
      when 'MESSAGE_CREATE'
        message_id = data[:d][:id]
        channel_id = data[:d][:channel_id]

        get_message(channel_id, message_id)
      end
    when 1
      log_message(:heartbeat, data)
      send_heartbeat
    when 9
      log_error('Invalid session, reidentifying')
      identify!
    when 10
      log_message(:hello, data)

      self.heartbeat_interval = data[:d][:heartbeat_interval] / 1000

      send_heartbeat

      self.heartbeat_thread = tick_every_with_jitter(heartbeat_interval) do
        send_heartbeat
      end
    when 11
      log_message(:heartbeat_ack, data)

      if !connected
        identify!
      end
    else
      log_warn(:unknown, data)
    end
  end

  def get_message(channel_id, message_id)
    response = request_from_api("/channels/#{channel_id}/messages/#{message_id}", 'get')

    if response[:content] == '!ping'
      request_from_api("/channels/#{channel_id}/messages", "post", { content: 'Pong!' })
    end
  end

  def request_from_api(endpoint, method, data = nil)
    uri = URI(DISCORD_API_URL + endpoint)

    headers = {
      'Authorization' => 'Bot ' + discord_token
    }

    request = Net::HTTP.const_get(method.capitalize).new(uri.request_uri, headers)

    if data
      request.body = JSON.dump(data)
      request['Content-Type'] = 'application/json'
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    log_general("Request to #{endpoint} returned #{response.code}")
    log_general(response.body)

    JSON.parse(response.body, symbolize_names: true)
  end

  def send_heartbeat
    log_general 'Sending heartbeat'
    ws.send(JSON.dump({ op: 1, d: s_field }))
  end

  def identify!
    log_general 'Sending identify'
    ws.send(JSON.dump({
      op: 2,
      d: {
        token: discord_token,
        intents: intent,
        properties: {
          '$os': 'linux',
          '$browser': 'discord.rb',
          '$device': 'discord.rb'
        },
        presence: {
          status: 'online',
          afk: false,
          activities: [{
            name: 'with Ruby',
            type: 0
          }]
        }
      }
    }))
    self.connected = true
  end
end

bot = Bot.new(discord_token, log_level)
bot.start