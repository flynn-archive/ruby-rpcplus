require "celluloid/io"
require "yajl"

module RPCPlus
  class Client
    include Celluloid::IO
    finalizer :shutdown

    def initialize(host, port)
      @seq = 0
      @requests = {}

      @sock = Celluloid::IO::TCPSocket.new(host, port)
      @sock.write("CONNECT /_goRPC_ HTTP/1.0\r\nAccept: application/vnd.flynn.rpc-hijack+json\r\n\r\n")
      response = @sock.readline(/\r?\n/)
      raise 'invalid response' if !response.start_with?('HTTP/1.0 200')
      @sock.readline(/\r?\n/)
      async.read_responses
    end

    def request(method, arg, &block)
      req = { 'id' => @seq+=1, 'method' => method, 'params' => [arg] }
      future = Celluloid::Future.new
      @requests[req['id']] = { stream: block, future: future }
      Yajl::Encoder.encode(req, @sock)

      # block until stream is done, so that the block doesn't become invalid due
      # to https://github.com/celluloid/celluloid/pull/245
      future.value if block

      future
    end

    private

    def shutdown
      @sock.close if @sock
    end

    def read_responses
      loop do
        response = Yajl::Parser.parse(@sock.readline)
        req = @requests[response['id']]
        next if !req
        if req[:stream] && !response['error']
          req[:stream].call(response['result'])
          next
        end
        req[:future].signal(Response.new(response["result"]))
        @requests.delete(response['id'])
      end
    end
  end
end
