require 'helper'

RSpec.describe HTTP2::Server do
  before(:each) do
    @srv = Server.new
  end

  let(:f) { Framer.new }

  context 'initialization and settings' do
    it 'should return even stream IDs' do
      expect(@srv.new_stream.id).to be_even
    end

    it 'should emit SETTINGS on new connection' do
      frames = []
      @srv.on(:frame) { |recv| frames << recv }
      @srv << CONNECTION_PREFACE_MAGIC

      expect(f.parse(frames[0])[:type]).to eq :settings
    end

    it 'should initialize client with custom connection settings' do
      frames = []

      @srv = Server.new(settings_max_concurrent_streams: 200,
                        settings_initial_window_size:    2**10)
      @srv.on(:frame) { |recv| frames << recv }
      @srv << CONNECTION_PREFACE_MAGIC

      frame = f.parse(frames[0])
      expect(frame[:type]).to eq :settings
      expect(frame[:payload]).to include([:settings_max_concurrent_streams, 200])
      expect(frame[:payload]).to include([:settings_initial_window_size, 2**10])
    end
  end

  it 'should allow server push' do
    client = Client.new
    client.on(:frame) { |bytes| @srv << bytes }

    @srv.on(:stream) do |stream|
      expect do
        stream.promise(':method' => 'GET') {}
      end.to_not raise_error
    end

    client.new_stream
    client.send HEADERS.deep_dup
  end

  let(:server){ Server.new }

  context 'server API' do
    context 'half_closed client stream' do

      let(:client)      { Client.new }
      let(:srv_headers) { Hash.new }

      before do
        server.on(:frame_sent)     { |f| puts "S >> #{truncate_keys(f.dup)}" }
        server.on(:frame_received) { |f| puts "S << #{truncate_keys(f.dup)}" }

        client.on(:frame_sent)     { |f| puts "C >> #{truncate_keys(f.dup)}" }
        client.on(:frame_received) { |f| puts "C << #{truncate_keys(f.dup)}" }

        server.on(:stream) do |stream|
          stream.on(:headers)    { |h| srv_headers.merge! Hash[h] }
        end

      end

      it 'should handle sending data larger than window' do
        mutex = Mutex.new
        condition = ConditionVariable.new

        # server stream for later...
        server_stream = nil

        # pipe for client -> server
        cr, cw = IO.pipe

        # route client outbound packets to server
        client.on(:frame) { |bytes| cw << bytes }
        ct = Thread.new do
          begin
            while r = cr.read(1); server << r; end
          rescue IOError
          end
        end

        # pipe for server -> client
        sr, sw = IO.pipe

        # route server outbound packets to client
        server.on(:frame) { |bytes| sw << bytes }
        st = Thread.new do
          begin
            while r = sr.read(1); client << r; end
          rescue IOError
          end
        end

        # signal when that half_close happens
        server.on(:stream) { |stream| stream.on(:half_close) { server_stream = stream; condition.signal } }

        # exceed the window
        content_length = HTTP2::DEFAULT_FLOW_WINDOW + 1
        payload = 'x' * content_length

        # client received response
        client_rcvd_headers = {}
        client_rcvd_data = ''

        # trigger half_close
        client_stream = client.new_stream

        # set up client header callback
        client_stream.on(:headers) { |h| client_rcvd_headers.merge! Hash[h] }

        # set up client specifc data callback that signals
        client_stream.on(:data) do |d|
          client_rcvd_data += d

          # this unblocks the test, but note there's another sleep after to give the thread
          # some time
          condition.signal if client_rcvd_data.length >= HTTP2::DEFAULT_FLOW_WINDOW
        end

        # send headers and data from client
        client_stream.headers(':method' => 'GET', ':path' => '/', ':authority' => 'foo')
        client_stream.data('')

        # wait for the signal that server received the "request"
        mutex.synchronize { condition.wait(mutex) }

        # verify server results
        expect(srv_headers[':method']).to eq 'GET'
        expect(srv_headers[':path']).to eq '/'
        expect(srv_headers[':authority']).to eq 'foo'

        # respond in kind
        expect(server_stream).to_not be_nil
        server_stream.headers('content-length' => content_length.to_s)
        server_stream.data(payload)

        # wait for client receipt
        mutex.synchronize { condition.wait(mutex) }

        # the condition is signaled when the length hits the DEFAULT_FLOW_WINDOW, so
        # sleep a little bit to give the read thread a chance.
        sleep 1

        # make sure client got what we sent
        expect(client_rcvd_data.length).to eq content_length

        # todo: more expectations

        server.goaway
        [sr, sw, cr, cw].each &:close

        ct.join
        st.join
      end
    end
  end
end
