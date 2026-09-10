# encoding: utf-8

#--
# Copyright DataStax, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

require 'spec_helper'
require 'socket'
require 'openssl'
require 'timeout'

# These specs only ever talk to loopback sockets opened by the spec itself.
module Cassandra
  class Cluster
    describe(IoReactor) do
      # Wraps IO.select so the spec can see how often, and for how long, the
      # reactor loop goes to sleep.
      class CountingSelector
        attr_reader :calls, :timeouts

        def initialize
          @calls    = 0
          @timeouts = []
        end

        def select(readables, writables, errorables, timeout)
          @calls += 1
          @timeouts << timeout
          ::IO.select(readables, writables, errorables, timeout)
        end
      end

      let(:selector) { CountingSelector.new }
      let(:reactor)  { IoReactor.new(selector: selector) }

      after do
        begin
          reactor.stop.value
        rescue
          nil
        end
      end

      def free_port
        server = ::TCPServer.new('127.0.0.1', 0)
        port   = server.addr[1]
        server.close
        port
      end

      def reactor_threads
        ::Thread.list.select {|t| t.name == IoReactor::THREAD_NAME}
      end

      describe('thread') do
        it 'is named io_reactor while running and exits on stop' do
          before = ::Thread.list.size

          reactor.start.value
          await { reactor_threads.size == 1 }

          reactor.stop.value
          await { ::Thread.list.size <= before }
          expect(reactor_threads).to be_empty
        end
      end

      describe('when idle') do
        it 'sleeps in select without a timeout instead of ticking' do
          reactor.start.value
          sleep(0.3)

          # start plus draining the unblocker; a ticking reactor would have
          # woken up a few hundred times by now with a small tick resolution
          expect(selector.calls).to be <= 3
          expect(selector.timeouts.last).to be_nil
        end

        it 'wakes up for a timer scheduled while it is asleep' do
          reactor.start.value
          sleep(0.1)

          started = ::Time.now
          reactor.schedule_timer(0.05).value
          expect(::Time.now - started).to be < 1
        end

        it 'sleeps only until the next timer is due' do
          reactor.start.value
          sleep(0.1)

          reactor.schedule_timer(0.2)
          await { selector.timeouts.last && selector.timeouts.last <= 0.2 }
          expect(selector.timeouts.last).to be > 0
        end
      end

      describe('TLS handshake') do
        let(:server) { ::TCPServer.new('127.0.0.1', 0) }
        let(:port)   { server.addr[1] }

        after { server.close unless server.closed? }

        context('when the server accepts TCP but never answers the handshake') do
          it 'fails within the connect timeout instead of hanging' do
            reactor.start.value

            started  = ::Time.now
            future   = reactor.connect('127.0.0.1', port, timeout: 0.5, ssl: true)
            accepted = server.accept

            expect { future.value }.to raise_error(Ione::Io::ConnectionTimeoutError, /TLS handshake/)
            expect(::Time.now - started).to be < 3

            # the half-open socket is closed, not left in the loop: reading
            # drains the ClientHello and then hits EOF instead of blocking
            expect { ::Timeout.timeout(2) { accepted.read } }.not_to raise_error
            accepted.close
          end

          it 'does not spin the reactor loop while the handshake is pending' do
            reactor.start.value

            future = reactor.connect('127.0.0.1', port, timeout: 1, ssl: true)
            accepted = server.accept
            begin
              future.value
            rescue Ione::Io::ConnectionTimeoutError
              nil
            end
            accepted.close

            # the stock reactor selects the socket for writability, which
            # returns immediately, and goes round tens of thousands of times
            expect(selector.calls).to be < 20
          end
        end

        context('against a local TLS server') do
          let(:key) { ::OpenSSL::PKey::RSA.new(2048) }
          let(:cert) do
            cert = ::OpenSSL::X509::Certificate.new
            cert.version    = 2
            cert.serial     = 1
            cert.subject    = ::OpenSSL::X509::Name.parse('/CN=127.0.0.1')
            cert.issuer     = cert.subject
            cert.public_key = key.public_key
            cert.not_before = ::Time.now - 60
            cert.not_after  = ::Time.now + 3600
            cert.sign(key, ::OpenSSL::Digest::SHA256.new)
            cert
          end
          let(:server_context) do
            ctx      = ::OpenSSL::SSL::SSLContext.new
            ctx.cert = cert
            ctx.key  = key
            ctx
          end
          let(:client_context) do
            ctx             = ::OpenSSL::SSL::SSLContext.new
            ctx.verify_mode = ::OpenSSL::SSL::VERIFY_NONE
            ctx
          end

          it 'completes the handshake and receives data' do
            ssl_server = ::OpenSSL::SSL::SSLServer.new(server, server_context)
            server_thread = ::Thread.new do
              socket = ssl_server.accept
              socket.write('hello')
              socket.flush
              sleep(0.2)
              socket.close
            end

            reactor.start.value
            connection = reactor.connect('127.0.0.1', port, timeout: 5, ssl: client_context).value
            expect(connection).to be_connected

            received = +''
            connection.on_data {|data| received << data}
            await { received == 'hello' }

            server_thread.join(5)
          end
        end
      end

      describe('plain TCP') do
        it 'fails fast when nothing is listening' do
          reactor.start.value

          started = ::Time.now
          future  = reactor.connect('127.0.0.1', free_port, timeout: 5)
          expect { future.value }.to raise_error(Ione::Io::ConnectionError)
          expect(::Time.now - started).to be < 2
        end
      end
    end
  end
end
