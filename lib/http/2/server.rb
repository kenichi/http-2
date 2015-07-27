require 'base64'

module HTTP2
  # HTTP 2.0 server connection class that implements appropriate header
  # compression / decompression algorithms and stream management logic.
  #
  # Your code is responsible for feeding request data to the server object,
  # which in turn performs all of the necessary HTTP 2.0 decoding / encoding,
  # state management, and the rest. A simple example:
  #
  # @example
  #     socket = YourTransport.new
  #
  #     conn = HTTP2::Server.new
  #     conn.on(:stream) do |stream|
  #       ...
  #     end
  #
  #     while bytes = socket.read
  #       conn << bytes
  #     end
  #
  class Server < Connection
    # Initialize new HTTP 2.0 server object.
    def initialize(**settings)
      @stream_id    = 2
      @state        = :waiting_magic

      @local_role   = :server
      @remote_role  = :client

      super
    end

    # handle HTTP 1.1 Upgrade connections by responding with stream 1, see
    # `example/celluloid_server.rb`.
    #
    # @param headers [Hash] request headers including H2 pseudo-headers
    # @param settings [String] HTTP2-Settings header value
    #
    def upgrade_stream(**args)

      # convenience convert
      args[:headers] = args[:headers].to_a if Hash === args[:headers]

      # parse settings
      buf = Buffer.new Base64.decode64(args.delete(:settings))
      payload = Framer.frame_settings(buf.length, buf)
      self.settings(payload)

      # fire up the stream
      new_stream **args.merge(upgrade: true)

    end

    private

    # Handle locally initiated server-push event emitted by the stream.
    #
    # @param args [Array]
    # @param callback [Proc]
    def promise(*args, &callback)
      parent, headers, flags = *args
      promise = new_stream(parent: parent)
      promise.send(
        type: :push_promise,
        flags: flags,
        stream: parent.id,
        promise_stream: promise.id,
        payload: headers.to_a,
      )

      callback.call(promise)
    end
  end
end
