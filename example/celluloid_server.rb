require 'awesome_print'
require 'base64'
require 'celluloid/current'
require 'celluloid/io'
require 'http/2'
require 'http_parser'
require 'stringio'

class H2CServer
  include Celluloid::IO
  extend Forwardable
  def_delegators :@logger, :info, :error, :warn


  def initialize port:
    @logger = ::Logger.new STDOUT
    @port = port
    @server = Celluloid::IO::TCPServer.new @port
  end

  def listen
    info "listening on #{@port}"
    loop { async.handle socket: @server.accept }
  end

  def handle socket:
    info "\n\nnew connection!"
    p = HTTP2::Server.new

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

    up = UpgradeParser.new p, socket
    parser = up

    while !socket.closed? && !(socket.eof? rescue true) # rubocop:disable Style/RescueModifier
      begin
        data = socket.readpartial(1024)

        begin
          parser << data

        rescue HTTP::Parser::Error => hpe
          parser = p
          retry

        end

      rescue Errno::ECONNRESET => e
        warn "client closed connection."
        socket.close

      rescue => e

        error "Exception: #{e}, #{e.message} - closing socket."
        socket.close
      end
    end
  end

  class Stream

    def initialize logger: nil, stream:
      @logger, @stream = logger, stream
      @headers, @buffer = {}, StringIO.new

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

      @stream.on :half_close do
        log "client half_close"
        log "buffer: '#{buffer}'"

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

    def buffer
      @buffer.to_s
    end

  end

  class UpgradeParser

    HOST           = /host/i
    HTTP2_SETTINGS = /http2-settings/i

    UPGRADE_RESPONSE = ("HTTP/1.1 101 Switching Protocols\n" +
                        "Connection: Upgrade\n" +
                        "Upgrade: h2c\n\n").freeze

    VALID_UPGRADE_METHODS = %w[GET OPTIONS]

    attr_reader :complete

    def initialize conn, sock
      @complete, @conn, @sock = false, conn, sock
      @parser = ::HTTP::Parser.new self
    end

    def << data
      @parser << data
      if @complete
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

        @conn.upgrade_stream headers: h, settings: @http2_settings
      end
    end

    def on_headers_complete headers
      @headers = headers
      @http2_settings = headers.find {|(k,_)| k =~ HTTP2_SETTINGS}[1] rescue nil
      @host = headers.find {|(k,_)| k =~ HOST}[1] rescue nil
    end

    def on_message_complete
      @complete = true
    end
  end

end

s = H2CServer.new port: 8080
s.listen
