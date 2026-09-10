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

module Cassandra
  class Cluster
    # An {Ione::Io::IoReactor} tuned for the way the driver uses it.
    #
    # It differs from the stock ione reactor in the following ways:
    #
    # * The TLS handshake is bounded by the connect timeout. The stock reactor
    #   only applies the timeout to the TCP connect, so a peer that accepts TCP
    #   but never answers the ClientHello hangs the connect forever.
    # * A TLS socket waiting for bytes from the server is selected for
    #   readability. The stock reactor selects every connecting socket for
    #   writability, and a connected TCP socket is always writable, so the
    #   reactor loop spins at 100% CPU for as long as the handshake is pending.
    # * Closing a TLS connection also closes the underlying TCP socket, instead
    #   of leaving the file descriptor open until garbage collection.
    # * The reactor sleeps in select until there is IO, a timer is due, or it is
    #   unblocked, instead of waking up every second regardless. Connect
    #   attempts still get a bounded select so their timeouts can be enforced.
    # * A socket whose file descriptor was closed underneath the reactor is
    #   evicted instead of being re-selected forever.
    # * The reactor thread is named so leaked reactors can be counted per
    #   process (see {THREAD_NAME}).
    #
    # @private
    class IoReactor < Ione::Io::IoReactor
      # Name given to the reactor thread; count threads with this name to detect
      # leaked reactors.
      THREAD_NAME = 'io_reactor'.freeze

      def initialize(options = {})
        super
        @scheduler = Scheduler.new(@options)
        @io_loop   = IoLoop.new(@unblocker, @scheduler, @options)
      end

      # Same contract as {Ione::Io::IoReactor#connect}, but the connect timeout
      # covers the TLS handshake as well as the TCP connect.
      def connect(host, port, options = nil, &block)
        if options.is_a?(::Numeric) || options.nil?
          timeout = options || 5
          ssl     = false
        else
          timeout = options[:timeout] || 5
          ssl     = options[:ssl]
        end

        deadline   = @clock.now + timeout
        connection = Ione::Io::Connection.new(host, port, timeout, @unblocker, @clock)
        f = connection.connect
        @io_loop.add_socket(connection)
        @unblocker.unblock if running?

        if ssl
          f = f.flat_map do
            ssl_context = ssl == true ? nil : ssl
            upgraded    = SslConnection.new(host,
                                            port,
                                            connection.to_io,
                                            @unblocker,
                                            ssl_context,
                                            deadline,
                                            @clock)
            ff = upgraded.connect
            @io_loop.remove_socket(connection)
            @io_loop.add_socket(upgraded)
            @unblocker.unblock
            ff
          end
        end

        f = f.map(&block) if block_given?
        f
      end

      # The reactor sleeps until its next timer is due, so a timer scheduled
      # while it is asleep has to wake it up.
      def schedule_timer(timeout)
        timer = super
        @unblocker.unblock if running?
        timer
      end

      # @private
      class Scheduler < Ione::Io::Scheduler
        def initialize(options = {})
          super
          @clock = options[:clock] || ::Time
        end

        # @return [Numeric, nil] seconds until the earliest pending timer is
        #   due (zero when overdue), or nil when there are no timers
        def next_timeout
          timer = @lock.synchronize { @timer_queue.peek }
          return nil unless timer

          remaining = timer.time - @clock.now
          remaining > 0 ? remaining : 0
        end
      end

      # @private
      class IoLoop < Ione::Io::IoLoopBody
        def initialize(unblocker, scheduler, options = {})
          super(unblocker, options)
          @scheduler       = scheduler
          @clock           = options[:clock] || ::Time
          @tick_resolution = options[:tick_resolution] || 1
          @drain_timeout   = options[:drain_timeout] || 5
        end

        # @param max_timeout [Numeric, nil] upper bound on how long to block in
        #   select, regardless of timers
        def tick(max_timeout = nil)
          name_thread

          readables  = []
          writables  = []
          connecting = []

          @sockets.each do |s|
            if s.connected?
              readables << s
            elsif s.connecting?
              connecting << s
              # A TLS handshake waiting on the server must be selected for
              # readability; selecting it for writability returns immediately
              # and spins the loop.
              if s.respond_to?(:handshake_wants_read?) && s.handshake_wants_read?
                readables << s
                next
              end
            end

            writables << s if s.connecting? || s.writable?
          end

          timeout = @scheduler.next_timeout
          # Connect and handshake timeouts are checked from #connect, which only
          # runs when the loop wakes up, so keep ticking while connecting.
          timeout = [timeout, @tick_resolution].compact.min unless connecting.empty?
          timeout = [timeout, max_timeout].compact.min if max_timeout

          begin
            r, w, _ = @selector.select(readables, writables, nil, timeout)
            connecting.each(&:connect)
            r && r.each {|s| s.read if s.connected?}
            w && w.each(&:flush)
          rescue ::IOError, ::Errno::EBADF => e
            evict_dead_sockets(e)
          end
        end

        def drain_sockets
          threshold = @clock.now + @drain_timeout
          until @clock.now >= threshold || @sockets.none?(&:writable?)
            @sockets.each(&:drain)
            tick(@tick_resolution)
            @lock.synchronize { @sockets = @sockets.reject(&:closed?) }
          end
          if @clock.now >= threshold
            raise Ione::Io::ReactorError,
                  format('Socket drain timeout after %p s', @drain_timeout)
          end
        end

        private

        def name_thread
          thread = ::Thread.current
          thread.name = THREAD_NAME if thread.name.nil?
        end

        # select raised because a file descriptor in the set is closed. Close
        # and drop the offending sockets so the loop cannot spin on them.
        def evict_dead_sockets(error)
          @sockets.each do |s|
            next if s.closed? || !s.is_a?(Ione::Io::BaseConnection)
            io = s.to_io
            next if io.nil? || !io.closed?
            begin
              s.close(error)
            rescue
              nil
            end
          end
          @lock.synchronize { @sockets = @sockets.reject(&:closed?) }
        end
      end

      # @private
      class SslConnection < Ione::Io::SslConnection
        def initialize(host, port, io, unblocker, ssl_context, deadline, clock)
          super(host, port, io, unblocker, ssl_context)
          @deadline   = deadline
          @clock      = clock
          @wants_read = false
        end

        # @return [Boolean] true while the handshake is waiting for bytes from
        #   the server
        def handshake_wants_read?
          @wants_read
        end

        def connect
          if @io.nil?
            @io = if @ssl_context
                    @socket_impl.new(@raw_io, @ssl_context)
                  else
                    @socket_impl.new(@raw_io)
                  end
            @io.sync_close = true if @io.respond_to?(:sync_close=)
          end
          @io.connect_nonblock
          @wants_read = false
          @state = CONNECTED_STATE
          @connected_promise.fulfill(self)
          @connected_promise.future
        rescue ::IO::WaitReadable
          @wants_read = true
          fail_if_past_deadline
          @connected_promise.future
        rescue ::IO::WaitWritable
          @wants_read = false
          fail_if_past_deadline
          @connected_promise.future
        rescue => e
          close(e)
          @connected_promise.future
        end

        def close(cause = nil)
          closed = super
          if closed
            # The SSL socket closes the raw socket when it exists (sync_close),
            # but a handshake that never started leaves only the raw socket.
            begin
              @raw_io.close unless @raw_io.closed?
            rescue ::SystemCallError, ::IOError
              nil
            end
          end
          closed
        end

        private

        def fail_if_past_deadline
          return if @clock.now < @deadline
          close(Ione::Io::ConnectionTimeoutError.new(
                  "Could not complete TLS handshake with #{@host}:#{@port} " \
                  'within the connect timeout'
          ))
        end
      end
    end
  end
end
