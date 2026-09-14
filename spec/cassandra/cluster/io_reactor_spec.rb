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
          ::Timeout.timeout(3) { reactor.stop.value }
        rescue
          reactor.instance_variable_get(:@io_loop).thread.kill if reactor.running?
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

        it 'wakes for timers and stops after repeated restarts' do
          ::Timeout.timeout(3) do
            3.times do
              reactor.start.value
              reactor.schedule_timer(0.01).value
              reactor.stop.value
            end
          end
          expect(reactor_threads).to be_empty
        end

        it 'restarts when start is requested while stopping' do
          ::Timeout.timeout(3) do
            reactor.start.value
            restarted = reactor.schedule_timer(0).flat_map do
              reactor.stop
              reactor.start
            end
            expect(restarted.value).to eq(reactor)
            reactor.schedule_timer(0.01).value
            reactor.stop.value
          end
        end

        it 'restarts when shutdown completes immediately after start observes stopping' do
          entered_select = ::Queue.new
          release_select = ::Queue.new
          observed_stopping = ::Queue.new
          resume_start = ::Queue.new
          begin_start = ::Queue.new
          requester = nil
          first_select = true
          paused_start = false

          allow(selector).to receive(:select).and_wrap_original do |original, *args|
            if first_select
              first_select = false
              entered_select << true
              release_select.pop
              nil
            else
              original.call(*args)
            end
          end

          lock = reactor.instance_variable_get(:@lock)
          allow(lock).to receive(:synchronize).and_wrap_original do |original, &block|
            result = original.call(&block)
            if ::Thread.current == requester && !paused_start
              paused_start = true
              observed_stopping << true
              resume_start.pop
            end
            result
          end

          ::Timeout.timeout(3) do
            reactor.start.value
            entered_select.pop
            stopped = reactor.stop
            requester = ::Thread.new do
              begin_start.pop
              reactor.start
            end
            begin_start << true

            # Let shutdown close the pipe after start releases the state lock,
            # before it can continue starting or subscribe to the stop future.
            observed_stopping.pop
            release_select << true
            stopped.value
            resume_start << true

            expect(requester.value.value).to eq(reactor)
            reactor.schedule_timer(0.01).value
            reactor.stop.value
          end
        ensure
          release_select << true
          resume_start << true
          begin_start << true
          requester.kill.join if requester && requester.alive?
        end

        it 'restores the unblocker after a reactor crash' do
          crashed = Ione::Promise.new
          reactor.on_error {|error| crashed.fulfill(error)}
          allow(selector).to receive(:select).and_wrap_original do |original, *args|
            if crashed.future.completed?
              original.call(*args)
            else
              raise 'selector failure'
            end
          end

          ::Timeout.timeout(3) do
            reactor.start.value
            expect(crashed.future.value.message).to eq('selector failure')
            reactor.start.value
            reactor.schedule_timer(0.01).value
            reactor.stop.value
          end
        end

        it 'completes the old stop future when a new run has already started' do
          shutdown_finished = ::Queue.new
          complete_stop = ::Queue.new
          paused_completion = false
          previous_thread = nil

          ::Timeout.timeout(3) do
            reactor.start.value
            await { reactor.instance_variable_get(:@io_loop).thread }
            previous_thread = reactor.instance_variable_get(:@io_loop).thread
            lock = reactor.instance_variable_get(:@lock)
            allow(lock).to receive(:synchronize).and_wrap_original do |original, &block|
              result = original.call(&block)
              if ::Thread.current == previous_thread &&
                 reactor.instance_variable_get(:@state) == IoReactor::STOPPED_STATE &&
                 !paused_completion
                paused_completion = true
                shutdown_finished << true
                complete_stop.pop
              end
              result
            end

            old_stop = reactor.stop
            shutdown_finished.pop
            reactor.start.value
            new_stop = reactor.instance_variable_get(:@stopped_promise).future
            expect(old_stop).not_to be_completed
            complete_stop << true

            expect(old_stop.value).to eq(reactor)
            expect(new_stop).not_to be_completed
            reactor.schedule_timer(0.01).value
            expect(reactor.stop).to equal(new_stop)
            new_stop.value
          end
        ensure
          complete_stop << true
          previous_thread.join(1) if previous_thread
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

        it 'does not wake itself when scheduling a timer on the reactor thread' do
          reactor.start.value
          await { selector.calls > 0 }
          unblocker = reactor.instance_variable_get(:@unblocker)
          allow(unblocker).to receive(:unblock).and_call_original

          ::Timeout.timeout(3) do
            reactor.schedule_timer(0).flat_map { reactor.schedule_timer(0.01) }.value
          end

          expect(unblocker).to have_received(:unblock).once
        end

        [:close, :drain].each do |operation|
          it "wakes when an outgoing connection receives #{operation} from another thread" do
            server = ::TCPServer.new('127.0.0.1', 0)
            reactor.start.value
            connection = reactor.connect('127.0.0.1', server.addr[1], 1).value
            accepted = server.accept
            unblocker = reactor.instance_variable_get(:@unblocker)
            events = []
            allow(unblocker).to receive(:unblock).and_wrap_original do |original|
              events << :wakeup
              original.call
            end
            connection.on_closed { events << :closed }
            sleep(0.1)
            calls = selector.calls

            connection.public_send(operation)

            expect(unblocker).to have_received(:unblock)
            expect(events.index(:wakeup)).to be < events.index(:closed)
            await { selector.calls > calls }
            expect(::Timeout.timeout(2) { accepted.read }).to eq('')
          ensure
            accepted.close if accepted && !accepted.closed?
            server.close if server && !server.closed?
          end

          it "releases a listening port when its acceptor receives #{operation}" do
            reactor.start.value
            acceptor = reactor.bind('127.0.0.1', 0, 5).value
            port = acceptor.to_io.local_address.ip_port
            unblocker = reactor.instance_variable_get(:@unblocker)
            allow(unblocker).to receive(:unblock).and_call_original
            sleep(0.1)
            calls = selector.calls

            acceptor.public_send(operation)

            expect(unblocker).to have_received(:unblock)
            await { selector.calls > calls }
            rebound = ::TCPServer.new('127.0.0.1', port)
          ensure
            rebound.close if rebound
          end

          it "wakes when an accepted connection receives #{operation} from another thread" do
            reactor.start.value
            acceptor = reactor.bind('127.0.0.1', 0, 5).value
            accepted = Ione::Promise.new
            acceptor.on_accept {|connection| accepted.fulfill(connection)}
            peer = ::TCPSocket.new('127.0.0.1', acceptor.to_io.local_address.ip_port)
            connection = ::Timeout.timeout(2) { accepted.future.value }
            unblocker = reactor.instance_variable_get(:@unblocker)
            allow(unblocker).to receive(:unblock).and_call_original
            sleep(0.1)
            calls = selector.calls

            connection.public_send(operation)

            expect(unblocker).to have_received(:unblock)
            await { selector.calls > calls }
            expect(::Timeout.timeout(2) { peer.read }).to eq('')
          ensure
            peer.close if peer && !peer.closed?
          end
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

            expect { ::Timeout.timeout(3) { future.value } }.to raise_error(Ione::Io::ConnectionTimeoutError, /TLS handshake/)
            expect(::Time.now - started).to be < 1

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
              ::Timeout.timeout(3) { future.value }
            rescue Ione::Io::ConnectionTimeoutError
              nil
            end
            accepted.close

            # the stock reactor selects the socket for writability, which
            # returns immediately, and goes round tens of thousands of times
            expect(selector.calls).to be < 20
          end

          it 'keeps an infinite timeout pending while allowing timers and shutdown' do
            accepted = nil
            ::Timeout.timeout(3) do
              reactor.start.value
              future = reactor.connect('127.0.0.1', port, timeout: Float::INFINITY, ssl: true)
              accepted = server.accept

              reactor.schedule_timer(0.05).value
              expect(future).not_to be_completed
              expect(selector.calls).to be < 20

              reactor.stop.value
              expect(future).to be_completed
              expect(accepted.read).not_to be_empty
            end
          ensure
            accepted.close if accepted
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

      describe('accept errors') do
        [::IOError, ::Errno::EBADF, ::Errno::ECONNABORTED].each do |error_class|
          it "handles #{error_class} at the listener without stopping the reactor" do
            reactor.start.value
            acceptor = reactor.bind('127.0.0.1', 0, 5).value
            allow(acceptor.to_io).to receive(:accept_nonblock).and_raise(error_class)

            expect { acceptor.read }.not_to raise_error

            expect(acceptor.closed?).to eq(error_class != ::Errno::ECONNABORTED)
            ::Timeout.timeout(2) { reactor.schedule_timer(0.01).value }
            expect(reactor).to be_running
          end
        end
      end

      describe('plain TCP') do
        context('when TCP completes while the reactor is stopped') do
          let(:clock) { double('clock', now: 100.0) }
          let(:reactor) { IoReactor.new(selector: selector, clock: clock) }

          it 'uses the completed connection even when the deadline has elapsed before restart' do
            server = ::TCPServer.new('127.0.0.1', 0)
            reactor.start.value
            reactor.stop.value
            connected = reactor.connect('127.0.0.1', server.addr[1], timeout: 0.25)
            peer = server.accept
            allow(clock).to receive(:now).and_return(100.25)

            ::Timeout.timeout(3) do
              reactor.start.value
              connected.value.write('hello')
              expect(peer.read(5)).to eq('hello')
              reactor.stop.value
            end
          ensure
            peer.close if peer
            server.close if server
          end
        end

        it 'fails fast when nothing is listening' do
          reactor.start.value

          started = ::Time.now
          future  = reactor.connect('127.0.0.1', free_port, timeout: 5)
          expect { future.value }.to raise_error(Ione::Io::ConnectionError)
          expect(::Time.now - started).to be < 2
        end

        it 'can write through a connection queued before restarting' do
          server = ::TCPServer.new('127.0.0.1', 0)
          reactor.start.value
          reactor.stop.value
          connected = reactor.connect('127.0.0.1', server.addr[1], timeout: 1)
          accepted = server.accept

          ::Timeout.timeout(3) do
            reactor.start.value
            connected.value.write('hello')
            expect(accepted.read(5)).to eq('hello')
            reactor.stop.value
          end
        ensure
          accepted.close if accepted
          server.close if server
        end

        it 'connects and writes with an infinite timeout' do
          accepted = nil
          server = ::TCPServer.new('127.0.0.1', 0)
          ::Timeout.timeout(3) do
            reactor.start.value
            connection = reactor.connect('127.0.0.1', server.addr[1], Float::INFINITY).value
            accepted = server.accept
            connection.write('hello')
            expect(accepted.read(5)).to eq('hello')
          end
        ensure
          accepted.close if accepted
          server.close if server
        end
      end
    end

    describe(IoReactor::IoLoop) do
      let(:clock) { double('clock', now: 100.0) }
      let(:selector) { double('selector') }
      let(:unblocker) { IoReactor::Unblocker.new }
      let(:scheduler) { IoReactor::Scheduler.new(clock: clock) }
      let(:io_loop) do
        IoReactor::IoLoop.new(unblocker, scheduler,
                             clock: clock, selector: selector, tick_resolution: 1, drain_timeout: 3)
      end

      before { @thread_name = ::Thread.current.name }
      after do
        io_loop.close_sockets
        ::Thread.current.name = @thread_name
      end

      it 'uses a fixed timeout while draining with an overdue timer' do
        timer = scheduler.schedule_timer(-1)
        socket = double('socket', connected?: false, connecting?: false,
                                  writable?: true, closed?: false, drain: nil, close: nil)
        io_loop.add_socket(socket)
        now = 100.0
        allow(selector).to receive(:select) do |_, _, _, timeout|
          expect(timeout).to eq(1)
          now += timeout
          allow(clock).to receive(:now).and_return(now)
          nil
        end

        expect { io_loop.drain_sockets }.to raise_error(Ione::Io::ReactorError, /drain timeout/)
        expect(selector).to have_received(:select).exactly(3).times
        expect(timer).not_to be_completed
      end

      it 'selects only until the nearest connect deadline' do
        [100.25, nil, 102.0].each do |deadline|
          socket = double('connection', connected?: false, connecting?: true,
                                        closed?: false, deadline: deadline, connect: nil, close: nil)
          io_loop.add_socket(socket)
        end
        scheduler.schedule_timer(0.5)

        expect(selector).to receive(:select).with(anything, anything, nil, 0.25)
        io_loop.tick
      end

      it 'selects without a deadline for an infinite timeout' do
        socket = double('connection', connected?: false, connecting?: true,
                                      closed?: false, deadline: nil, connect: nil, close: nil)
        io_loop.add_socket(socket)

        expect(selector).to receive(:select).with(anything, anything, nil, nil)
        io_loop.tick
      end

      it 'honours timers while a connection has an infinite timeout' do
        socket = double('connection', connected?: false, connecting?: true,
                                      closed?: false, deadline: nil, connect: nil, close: nil)
        io_loop.add_socket(socket)
        scheduler.schedule_timer(0.25)

        expect(selector).to receive(:select).with(anything, anything, nil, 0.25)
        io_loop.tick
      end

      it 'lets an earlier timer bound select while connecting' do
        socket = double('connection', connected?: false, connecting?: true,
                                      closed?: false, deadline: 105.0, connect: nil, close: nil)
        io_loop.add_socket(socket)
        scheduler.schedule_timer(0.1)

        expect(selector).to receive(:select) do |_, _, _, timeout|
          expect(timeout).to be_within(0.0001).of(0.1)
          nil
        end
        io_loop.tick
      end

      def add_connection(io)
        connection = Ione::Io::BaseConnection.new('127.0.0.1', 9042, unblocker)
        connection.instance_variable_set(:@io, io)
        connection.instance_variable_set(:@state, Ione::Io::BaseConnection::CONNECTED_STATE)
        io_loop.add_socket(connection)
        connection
      end

      [:connect, :read, :flush].each do |operation|
        [::IOError, ::Errno::EBADF].each do |error_class|
          it "isolates #{error_class} during #{operation} and continues reading healthy connections" do
            reader, writer = ::IO.pipe
            bad = add_connection(reader.dup)
            healthy = add_connection(reader)
            if operation == :connect
              bad.instance_variable_set(:@state, Ione::Io::BaseConnection::CONNECTING_STATE)
            elsif operation == :flush
              allow(bad).to receive(:writable?).and_return(true)
            end
            allow(bad).to receive(operation).and_raise(error_class, 'closed stream')
            selected_readers = operation == :read ? [bad, healthy] : [healthy]
            selected_writers = operation == :flush ? [bad] : nil
            allow(selector).to receive(:select).and_return([selected_readers, selected_writers, nil])
            received = nil
            healthy.on_data {|data| received = data}
            writer.write('hello')

            expect { io_loop.tick }.not_to raise_error

            expect(bad).to be_closed
            expect(healthy).not_to be_closed
            expect(received).to eq('hello')
          ensure
            writer.close if writer
          end
        end
      end

      it 'propagates dispatch errors unrelated to closed sockets' do
        reader, writer = ::IO.pipe
        connection = add_connection(reader)
        allow(connection).to receive(:read).and_raise(ArgumentError, 'invalid handler')
        allow(selector).to receive(:select).and_return([[connection], nil, nil])

        expect { io_loop.tick }.to raise_error(ArgumentError, 'invalid handler')
      ensure
        writer.close if writer
      end

      [::IOError, ::Errno::EBADF, ::TypeError].each do |error_class|
        it "evicts an invalid socket after #{error_class} and retains healthy sockets" do
          reader, writer = ::IO.pipe
          dead_io = reader.dup
          dead = add_connection(dead_io)
          healthy = add_connection(reader)
          if error_class == ::IOError
            dead_io.close
          elsif error_class == ::Errno::EBADF
            # Close the fd through another wrapper: closed? still returns false.
            ::IO.for_fd(dead_io.fileno).close
            expect(dead_io).not_to be_closed
          else
            dead_io.close
            dead.instance_variable_set(:@io, nil)
          end
          expect { ::IO.select([dead], nil, nil, 0) }.to raise_error(error_class)
          allow(selector).to receive(:select) do |*args|
            ::IO.select(*args)
          end

          io_loop.tick

          expect(dead).to be_closed
          expect(healthy).not_to be_closed
          received = nil
          healthy.on_data {|data| received = data}
          writer.write('hello')
          io_loop.tick
          expect(received).to eq('hello')
        ensure
          writer.close if writer
          begin
            dead_io.close if dead_io && !dead_io.closed?
          rescue ::Errno::EBADF
            nil
          end
        end
      end

      it 'propagates select errors unrelated to dead sockets' do
        expect(selector).to receive(:select).and_raise(::TypeError, 'bad selector argument')
        expect { io_loop.tick }.to raise_error(::TypeError, 'bad selector argument')
      end
    end

    describe(IoReactor::Connection) do
      let(:clock) { double('clock', now: 100.0) }
      let(:socket) { double('socket', close: nil) }
      let(:socket_impl) do
        impl = double('socket_impl')
        allow(impl).to receive(:getaddrinfo).and_return([[nil, 9042, nil, '127.0.0.1', ::Socket::AF_INET, ::Socket::SOCK_STREAM]])
        allow(impl).to receive(:sockaddr_in).and_return('SOCKADDR')
        allow(impl).to receive(:new).and_return(socket)
        impl
      end
      let(:connection) do
        IoReactor::Connection.new('127.0.0.1', 9042, 0.25, double('unblocker', unblock: nil), clock, socket_impl)
      end

      it 'fails at the connect deadline without waiting for another polling tick' do
        allow(socket).to receive(:connect_nonblock).and_raise(Errno::EINPROGRESS)
        future = connection.connect
        allow(clock).to receive(:now).and_return(100.25)

        connection.connect
        expect { future.value }.to raise_error(Ione::Io::ConnectionTimeoutError)
        expect(connection).to be_closed
      end

      [nil, Errno::EISCONN].each do |result|
        it "prefers a completed connect (#{result || 'success'}) over the deadline" do
          allow(socket).to receive(:connect_nonblock).and_raise(Errno::EINPROGRESS)
          future = connection.connect
          if result
            allow(socket).to receive(:connect_nonblock).and_raise(result)
          else
            allow(socket).to receive(:connect_nonblock).and_return(0)
          end
          allow(clock).to receive(:now).and_return(100.25)

          connection.connect

          expect(future.value).to eq(connection)
          expect(connection).to be_connected
        end
      end

      it 'fails only its own connection when the first connect attempt raises IOError' do
        allow(socket).to receive(:connect_nonblock).and_raise(IOError, 'closed stream')
        future = nil

        expect { future = connection.connect }.not_to raise_error

        expect { future.value }.to raise_error(Ione::Io::ConnectionError, 'closed stream')
        expect(connection).to be_closed
      end
    end

    describe(IoReactor::SslConnection) do
      it 'accepts a handshake that completes at the deadline and preserves the completed future' do
        clock = double('clock', now: 100.0)
        raw_socket = double('raw socket', closed?: false, close: nil)
        ssl_socket = double('SSL socket', close: nil)
        socket_impl = double('SSL socket implementation', new: ssl_socket)
        connection = IoReactor::SslConnection.new('127.0.0.1', 9042, raw_socket, double('unblocker', unblock: nil), nil, 100.25, clock)
        connection.instance_variable_set(:@socket_impl, socket_impl)
        allow(ssl_socket).to receive(:connect_nonblock).and_raise(::IO::EAGAINWaitReadable)
        future = connection.connect
        allow(clock).to receive(:now).and_return(100.25)
        allow(ssl_socket).to receive(:connect_nonblock).and_return(ssl_socket)

        connection.connect

        expect(future.value).to eq(connection)
        expect(connection).to be_connected
        expect(connection.connect).to equal(future)
        expect(connection).not_to be_closed
      end

      it 'fails the handshake without raising when the raw socket has disappeared' do
        connection = IoReactor::SslConnection.new('127.0.0.1', 9042, nil, double('unblocker', unblock: nil), nil,
                                                  ::Time.now + 1, ::Time)
        future = connection.connect

        expect(future).to be_failed
        expect { future.value }.to raise_error(Ione::Io::ConnectionError)
        expect(connection).to be_closed
        expect(connection.close).to eq(false)
      end

      it 'closes the raw socket when closed before the handshake starts' do
        reader, writer = ::IO.pipe
        connection = IoReactor::SslConnection.new('127.0.0.1', 9042, reader, double('unblocker', unblock: nil), nil,
                                                  ::Time.now + 1, ::Time)
        expect(connection.close).to eq(true)
        expect(reader).to be_closed
      ensure
        reader.close if reader && !reader.closed?
        writer.close if writer
      end
    end
  end
end
