require_relative 'helper'
require 'http_parser'
require 'base64'
require 'pry'

options = { port: 8080 }
OptionParser.new do |opts|
  opts.banner = 'Usage: server.rb [options]'

  opts.on('-s', '--secure', 'HTTPS mode') do |v|
    options[:secure] = v
  end

  opts.on('-p', '--port [Integer]', 'listen port') do |v|
    options[:port] = v
  end
end.parse!

puts "Starting server on port #{options[:port]}"
server = TCPServer.new(options[:port])

if options[:secure]
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.cert = OpenSSL::X509::Certificate.new(File.open('keys/mycert.pem'))
  ctx.key = OpenSSL::PKey::RSA.new(File.open('keys/mykey.pem'))
  ctx.npn_protocols = [DRAFT]

  server = OpenSSL::SSL::SSLServer.new(server, ctx)
end

class UpgradeHandler

  VALID_UPGRADE_METHODS = %w[GET OPTIONS]
  UPGRADE_RESPONSE = ("HTTP/1.1 101 Switching Protocols\n" +
                      "Connection: Upgrade\n" +
                      "Upgrade: h2c\n\n").freeze

  attr_reader :complete, :headers, :parsing

  def initialize conn, sock
    @conn, @sock = conn, sock
    @complete, @parsing = false, false
    @parser = ::HTTP::Parser.new(self)
  end

  def <<(data)
    @parsing ||= true
    @parser << data
    if complete

      @sock.write UPGRADE_RESPONSE

      # The first HTTP/2 frame sent by the server MUST be a server connection
      # preface (Section 3.5) consisting of a SETTINGS frame (Section 6.5).
      # https://tools.ietf.org/html/rfc7540#section-3.2
      #
      buf = HTTP2::Buffer.new Base64.decode64(headers['HTTP2-Settings'])
      @conn.settings HTTP2::Framer.frame_settings(buf.length, buf)

      h = {
        ':scheme'    => 'http',
        ':method'    => @parser.http_method,
        ':authority' => headers['Host'],
        ':path'      => @parser.request_url
      }
      @conn.new_stream upgrade: true, headers: h.to_a

    end
  end

  def complete!; @complete = true; end

  def on_headers_complete(headers)
    @headers = headers
  end

  def on_message_complete
    raise unless VALID_UPGRADE_METHODS.include?(@parser.http_method)
    @parsing = false
    complete!
  end

end

loop do
  sock = server.accept
  puts 'New TCP connection!'

  conn = HTTP2::Server.new
  conn.on(:frame) do |bytes|
    # puts "Writing bytes: #{bytes.unpack("H*").first}"
    sock.write bytes
  end
  conn.on(:frame_sent) do |frame|
    puts "Sent frame: #{frame.inspect}"
  end
  conn.on(:frame_received) do |frame|
    puts "Received frame: #{frame.inspect}"
  end

  conn.on(:stream) do |stream|
    log = Logger.new(stream.id)
    req, buffer = {}, ''

    stream.on(:active) { log.info 'client opened new stream' }
    stream.on(:close) do
      log.info 'stream closed'
    end

    stream.on(:headers) do |h|
      req = Hash[*h.flatten]
      log.info "request headers: #{h}"
    end

    stream.on(:data) do |d|
      log.info "payload chunk: <<#{d}>>"
      buffer << d
    end

    stream.on(:half_close) do
      log.info 'client closed its end of the stream'

      response = nil
      if req[':method'] == 'POST'
        log.info "Received POST request, payload: #{buffer}"
        response = "Hello HTTP 2.0! POST payload: #{buffer}"
      else
        log.info 'Received GET request'
        response = 'Hello HTTP 2.0! GET request'
      end

      stream.headers({
        ':status' => '200',
        'content-length' => response.bytesize.to_s,
        'content-type' => 'text/plain',
      }, end_stream: false)

      # split response into multiple DATA frames
      stream.data(response.slice!(0, 5), end_stream: false)
      stream.data(response)
    end
  end

  uh = UpgradeHandler.new(conn, sock)

  while !sock.closed? && !(sock.eof? rescue true) # rubocop:disable Style/RescueModifier
    data = sock.readpartial(1024)
    # puts "Received bytes: #{data.unpack("H*").first}"

    begin
      case
      when !uh.parsing && !uh.complete

        if data.start_with?(*UpgradeHandler::VALID_UPGRADE_METHODS)
          uh << data
        else
          uh.complete!
          conn << data
        end

      when uh.parsing && !uh.complete
        uh << data

      when uh.complete
        conn << data

      end

    rescue => e
      puts "Exception: #{e}, #{e.message} - closing socket."
      sock.close
    end
  end
end
