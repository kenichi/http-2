require 'awesome_print'
require 'base64'
require 'celluloid/current'
require 'celluloid/io'
require 'http/2'
require 'http_parser'

# a simple Celluloid::IO-based server
#
class H2CServer
  include Celluloid::IO

  # mimic Celluloid::Logger
  #
  extend Forwardable
  def_delegators :@logger, :info, :error, :warn

  # create a new service on the given port
  #
  def initialize port:
    @logger = ::Logger.new STDOUT
    @port = port
    @server = Celluloid::IO::TCPServer.new @port
  end

  # start accepting connections
  #
  def listen
    info "listening on #{@port}"
    loop { async.handle socket: @server.accept }
  end

  # handle each connection asynchronously
  #
  def handle socket:

    info "\n\nnew connection!"

    # fire up the H2 parser
    #
    p = HTTP2::Server.new

    # set event handlers
    #
    p.on :frame do |bytes|
      socket.write bytes
    end

    p.on :frame_received do |f|
      info "frame_received: #{f.inspect}"
    end

    p.on :frame_sent do |f|
      info "frame_sent: #{f.inspect}"
    end

    p.on :stream do |s|
      Stream.new logger: @logger, stream: s
    end

    # fire up a http/1.x parser wrapper, this will handle incoming H1 requests,
    # raising on H2 direct, or switching to H2 parser after responding with 101
    # upgrade and firing off stream 1 response.
    #
    up = UpgradeParser.new p, socket
    parser = up

    # read loop
    #
    while !socket.closed? && !(socket.eof? rescue true) # rubocop:disable Style/RescueModifier
      begin
        data = socket.readpartial(1024)

        # shovel read data in to whichever parser
        #
        begin
          parser << data

        # flip to H2 parser if H2 direct
        #
        rescue HTTP::Parser::Error => hpe
          parser = p
          retry
        end

      # handle every other error with a note and a close
      #
      rescue => e
        error "Exception: #{e}, #{e.message} - closing socket."
        socket.close
      end
    end
  end

  # wrap up stream handling in instances of this
  #
  class Stream

    def initialize logger: nil, stream:
      @logger, @stream = logger, stream

      # storage for event data delivery
      #
      @headers, @buffer = {}, ''

      # set event handlers
      #
      @stream.on :active do
        log "client opened stream"
      end

      @stream.on :close do
        log "client closed stream"
      end

      @stream.on :headers do |h|
        @headers = Hash[*h.flatten]
        log "headers:"
        ap @headers
      end

      @stream.on :data do |d|
        log "recv data: #{d.inspect}"
        @buffer << d
      end

      # respond to a request stream
      #
      @stream.on :half_close do
        log "client half_close"
        log "buffer: '#{@buffer}'"

        h = {
          ':status'        => '200',
          'content-type'   => 'text/plain',
          'content-length' => '0'
        }
        @stream.headers h, end_stream: true
      end
    end

    def log msg
      @logger.info "[stream #{@stream.id}] #{msg}" if @logger
    end

  end

  # HTTP::Parser wrapper to deal with:
  #     * direct H2 requests
  #     * 101 upgrade requests
  #
  class UpgradeParser

    # HTTP header keys are case-insensitive
    #
    HOST           = /host/i
    HTTP2_SETTINGS = /http2-settings/i

    UPGRADE_RESPONSE = ("HTTP/1.1 101 Switching Protocols\n" +
                        "Connection: Upgrade\n" +
                        "Upgrade: h2c\n\n").freeze

    VALID_UPGRADE_METHODS = %w[GET OPTIONS]

    # return new wrapper instance
    #
    # @param conn [HTTP2::Server] `HTTP2::Server` instance with events configured
    # @param sock [TCPSocket] underlying socket
    #
    def initialize conn, sock
      @complete, @conn, @sock = false, conn, sock
      @parser = ::HTTP::Parser.new self
    end

    # parse data read from client
    #
    def << data

      # will raise HTTP::Parser::Error if direct H2 (i.e. PRI *...)
      #
      @parser << data

      # HTTP::Parser will callback given obj (self in this case) and
      # `on_message_complete` will set +@complete+.
      #
      if @complete

        # create H2-like headers from H1 style request
        #
        h = {
          ':scheme'    => 'http',
          ':method'    => @parser.http_method,
          ':authority' => @host,
          ':path'      => @parser.request_url
        }.merge @headers

        raise unless VALID_UPGRADE_METHODS.include? h[':method']
        @sock.write UPGRADE_RESPONSE

        @parser = @conn   # flip to h2 parser, and...
        @complete = false # never do this again

        # respond to upgrade request on stream 1
        #
        @conn.upgrade_stream headers: h, settings: @http2_settings
      end
    end

    # callback for HTTP::Parser headers
    #
    def on_headers_complete headers
      @headers = headers
      @http2_settings = headers.find {|(k,_)| k =~ HTTP2_SETTINGS}[1] rescue nil
      @host = headers.find {|(k,_)| k =~ HOST}[1] rescue nil
    end

    # callback for HTTP::Parser completion
    #
    def on_message_complete
      @complete = true
    end
  end

end

# fire up the server!
#
s = H2CServer.new port: 8080
s.listen
