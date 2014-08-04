# encoding: utf-8

module Cql
  class Cluster
    class Client
      include MonitorMixin

      def initialize(logger, cluster_registry, io_reactor, connector, load_balancing_policy, reconnection_policy, retry_policy)
        @logger                      = logger
        @registry                    = cluster_registry
        @reactor                     = io_reactor
        @connector                   = connector
        @load_balancing_policy       = load_balancing_policy
        @reconnection_policy         = reconnection_policy
        @retry_policy                = retry_policy
        @connecting_hosts            = ::Set.new
        @connections                 = ::Hash.new
        @prepared_statements         = ::Hash.new
        @preparing_statements        = ::Hash.new
        @keyspace                    = nil
        @state                       = :idle

        mon_initialize
      end

      def connect
        synchronize do
          return CLIENT_CLOSED     if @state == :closed || @state == :closing
          return @connected_future if @state == :connecting || @state == :connected

          @state = :connecting

          @connected_future = begin
            @registry.add_listener(self)

            futures = @registry.hosts.map do |host|
              @connecting_hosts << host
              f = connect_to_host_maybe_retry(host, @load_balancing_policy.distance(host))
              f.recover do |error|
                Cql::Client::FailedConnection.new(error, host)
              end
            end

            Future.all(*futures).map do |connections|
              connections.flatten!
              raise NO_HOSTS if connections.empty?

              unless connections.any?(&:connected?)
                errors = {}
                connections.each {|c| errors[c.host] = c.error}
                raise NoHostsAvailable.new(errors)
              end

              self
            end
          end
          @connected_future.on_complete(&method(:connected))
          @connected_future
        end
      end

      def close
        synchronize do
          return CLIENT_NOT_CONNECTED if @state == :idle
          return @closed_future if @state == :closed || @state == :closing

          state, @state = @state, :closing

          @closed_future = begin
            @registry.remove_listener(self)

            if state == :connecting
              f = @connected_future.recover.flat_map { close_connections }
            else
              f = close_connections
            end

            f.map(self)
          end
          @closed_future.on_complete(&method(:closed))
          @closed_future
        end
      end

      # These methods shall be called from inside reactor thread only
      def host_found(host)
        nil
      end

      def host_lost(host)
        nil
      end

      def host_up(host)
        synchronize do
          return Future.resolved if @connecting_hosts.include?(host)

          @connecting_hosts << host

          connect_to_host_maybe_retry(host, @load_balancing_policy.distance(host)).map(nil)
        end
      end

      def host_down(host)
        futures = synchronize do
          return Future.resolved if @connecting_hosts.delete?(host) || !@connections.has_key?(host)

          @prepared_statements.delete(host)
          @preparing_statements.delete(host)

          @connections.delete(host).snapshot.map {|c| c.close}
        end

        Future.all(*futures).map(nil)
      end

      def query(statement, options)
        request = Protocol::QueryRequest.new(statement.cql, statement.params, nil, options.consistency, options.serial_consistency, options.page_size, nil, options.trace?)
        timeout = options.timeout
        future  = Ione::CompletableFuture.new

        keyspace = @keyspace
        plan     = @load_balancing_policy.plan(keyspace, statement, options)

        send_request_by_plan(future, keyspace, statement, options, request, plan, timeout)

        future
      end

      def prepare(cql, options)
        request = Protocol::PrepareRequest.new(cql, options.trace?)
        timeout = options.timeout
        future  = Ione::CompletableFuture.new

        keyspace  = @keyspace
        statement = VOID_STATEMENT
        plan      = @load_balancing_policy.plan(keyspace, statement, options)

        send_request_by_plan(future, keyspace, statement, options, request, plan, timeout)

        future
      end

      def execute(statement, options, paging_state = nil)
        timeout         = options.timeout
        result_metadata = statement.result_metadata
        request         = Protocol::ExecuteRequest.new(nil, statement.params_metadata, statement.params, result_metadata.nil?, options.consistency, options.serial_consistency, options.page_size, paging_state, options.trace?)
        future          = Ione::CompletableFuture.new

        keyspace = @keyspace
        plan     = @load_balancing_policy.plan(keyspace, statement, options)

        execute_by_plan(future, keyspace, statement, options, request, plan, timeout)

        future
      end

      def batch(statement, options)
        timeout  = options.timeout
        keyspace = @keyspace
        plan     = @load_balancing_policy.plan(keyspace, statement, options)
        future   = Ione::CompletableFuture.new

        batch_by_plan(future, keyspace, statement, options, plan, timeout)

        future
      end

      private

      NO_CONNECTIONS = Future.resolved([])
      BATCH_TYPES    = {
        :logged   => Protocol::BatchRequest::LOGGED_TYPE,
        :unlogged => Protocol::BatchRequest::UNLOGGED_TYPE,
        :counter  => Protocol::BatchRequest::COUNTER_TYPE,
      }.freeze
      CLIENT_CLOSED        = Future.failed(ClientError.new('Cannot connect a closed client'))
      CLIENT_NOT_CONNECTED = Future.failed(ClientError.new('Cannot close a not connected client'))

      UNAVAILABLE_ERROR_CODE   = 0x1000
      WRITE_TIMEOUT_ERROR_CODE = 0x1100
      READ_TIMEOUT_ERROR_CODE  = 0x1200

      def connected(f)
        if f.resolved?
          synchronize do
            @state = :connected
          end

          @logger.info('Cluster connection complete')
        else
          synchronize do
            @state = :defunct
          end

          f.on_failure do |e|
            @logger.error('Failed connecting to cluster: %s' % e.message)
          end

          close
        end
      end

      def closed(f)
        synchronize do
          @state = :closed

          if f.resolved?
            @logger.info('Cluster disconnect complete')
          else
            f.on_failure do |e|
              @logger.error('Cluster disconnect failed: %s' % e.message)
            end
          end
        end
      end

      def close_connections
        futures = synchronize { @connections.values }.flat_map {|m| m.snapshot.map {|c| c.close}}
        Future.all(*futures).map(self)
      end

      def connect_to_host_maybe_retry(host, distance)
        f = connect_to_host(host, distance)

        f.on_failure do |e|
          connect_to_host_with_retry(host, @reconnection_policy.schedule) if e.is_a?(Io::ConnectionError)
        end

        f
      end

      def connect_to_host_with_retry(host, schedule)
        interval = schedule.next

        @logger.debug('Reconnecting in %2.1f seconds' % interval)

        f = @reactor.schedule_timer(interval)
        f.flat_map do
          if synchronize { @connecting_hosts.include?(host) }
            connect_to_host(host, @load_balancing_policy.distance(host)).fallback do |e|
              if e.is_a?(Io::ConnectionError)
                connect_to_host_with_retry(host, schedule)
              else
                Future.failed(e)
              end
            end
          else
            NO_CONNECTIONS
          end
        end
      rescue ::StopIteration
        synchronize { @connecting_hosts.delete(host) }
        NO_CONNECTIONS
      end

      def connect_to_host(host, distance)
        @connector.connect(host, distance).map do |connections|
          manager = nil

          synchronize do
            @connecting_hosts.delete(host)

            unless connections.empty?
              @prepared_statements[host] = {}
              @preparing_statements[host] = {}
              manager = @connections[host] ||= Cql::Client::ConnectionManager.new
            end
          end

          manager && manager.add_connections(connections)

          connections
        end
      end

      def execute_by_plan(future, keyspace, statement, options, request, plan, timeout, errors = nil, hosts = [])
        hosts << host = plan.next
        connection = synchronize { @connections.fetch(host) }.random_connection

        if keyspace && connection.keyspace != keyspace
          switch = switch_keyspace(connection, keyspace, timeout)
          switch.on_complete do |s|
            if s.resolved?
              prepare_and_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
            else
              s.on_failure do |e|
                future.fail(e)
              end
            end
          end
        else
          prepare_and_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        future.fail(NoHostsAvailable.new(errors || {}))
      end

      def prepare_and_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
        cql = statement.cql
        id  = synchronize { @prepared_statements[host][cql] }

        if id
          request.id = id
          do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
        else
          prepare = prepare_statement(host, connection, cql, timeout)
          prepare.on_complete do |_|
            if prepare.resolved?
              request.id = prepare.value
              do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
            else
              prepare.on_failure do |e|
                future.fail(e)
              end
            end
          end
        end
      end

      def batch_by_plan(future, keyspace, statement, options, plan, timeout, errors = nil, hosts = [])
        hosts << host = plan.next
        connection = synchronize { @connections.fetch(host) }.random_connection

        if keyspace && connection.keyspace != keyspace
          switch = switch_keyspace(connection, keyspace, timeout)
          switch.on_complete do |s|
            if s.resolved?
              batch_and_send_request_by_plan(host, connection, future, keyspace, statement, options, plan, timeout, errors, hosts)
            else
              s.on_failure do |e|
                future.fail(e)
              end
            end
          end
        else
          batch_and_send_request_by_plan(host, connection, future, keyspace, statement, options, plan, timeout, errors, hosts)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        future.fail(NoHostsAvailable.new(errors || {}))
      end

      def batch_and_send_request_by_plan(host, connection, future, keyspace, statement, options, plan, timeout, errors, hosts)
        request    = Protocol::BatchRequest.new(BATCH_TYPES[statement.type], options.consistency, options.trace?)
        unprepared = Hash.new {|hash, cql| hash[cql] = []}

        statement.statements.each do |statement|
          cql = statement.cql

          if statement.is_a?(Statements::Bound)
            id = synchronize { @prepared_statements[host][cql] }

            if id
              request.add_prepared(id, statement.params_metadata, statement.params)
            else
              unprepared[cql] << statement
            end
          else
            request.add_query(cql, statement.params)
          end
        end

        if unprepared.empty?
          do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
        else
          to_prepare = unprepared.to_a
          futures    = to_prepare.map do |cql, _|
            prepare_statement(host, connection, cql, timeout)
          end

          Future.all(*futures).on_complete do |f|
            if f.resolved?
              prepared_ids = f.value
              to_prepare.each_with_index do |(_, statements), i|
                statements.each do |statement|
                  request.add_prepared(prepared_ids[i], statement.params_metadata, statement.params)
                end
              end

              do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
            else
              f.on_failure do |e|
                future.fail(e)
              end
            end
          end
        end
      end

      def send_request_by_plan(future, keyspace, statement, options, request, plan, timeout, errors = nil, hosts = [])
        hosts << host = plan.next
        connection = synchronize { @connections.fetch(host) }.random_connection

        if keyspace && connection.keyspace != keyspace
          switch = switch_keyspace(connection, keyspace, timeout)
          switch.on_complete do |s|
            if s.resolved?
              do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
            else
              s.on_failure do |e|
                future.fail(e)
              end
            end
          end
        else
          do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        future.fail(NoHostsAvailable.new(errors || {}))
      end

      def do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts, retries = 0)
        request.retries = retries

        f = connection.send_request(request, timeout)
        f.on_complete do |f|
          if f.resolved?
            r = f.value
            case r
            when Protocol::DetailedErrorResponse
              details  = r.details
              decision = case r.code
              when UNAVAILABLE_ERROR_CODE
                @retry_policy.unavailable(statement, details[:cl], details[:required], details[:alive], retries)
              when WRITE_TIMEOUT_ERROR_CODE
                @retry_policy.write_timeout(statement, details[:cl], details[:write_type], details[:blockfor], details[:received], retries)
              when READ_TIMEOUT_ERROR_CODE
                @retry_policy.read_timeout(statement, details[:cl], details[:blockfor], details[:received], details[:data_present], retries)
              else
                future.fail(QueryError.new(r.code, r.message, statement.cql, r.details))
                break
              end

              case decision
              when Retry::Decisions::Retry
                request.consistency = decision.consistency
                do_send_request_by_plan(host, connection, future, keyspace, statement, options, request, plan, timeout, errors, hosts, retries + 1)
              when Retry::Decisions::Ignore
                execution_info = create_execution_info(keyspace, statement, options, request, r, hosts)

                future.resolve(Results::Void.new(execution_info))
              when Retry::Decisions::Reraise
                future.fail(QueryError.new(r.code, r.message, statement.cql, r.details))
              else
                future.fail(QueryError.new(r.code, r.message, statement.cql, r.details))
              end
            when Protocol::ErrorResponse
              future.fail(QueryError.new(r.code, r.message, statement.cql, nil))
            when Protocol::SetKeyspaceResultResponse
              @keyspace = r.keyspace
              execution_info = create_execution_info(keyspace, statement, options, request, r, hosts)

              future.resolve(Results::Void.new(execution_info))
            when Protocol::PreparedResultResponse
              cql = request.cql
              synchronize do
                @prepared_statements[host][cql] = r.id
                @preparing_statements[host].delete(cql)
              end

              execution_info = create_execution_info(keyspace, statement, options, request, r, hosts)

              future.resolve(Statements::Prepared.new(cql, r.metadata, r.result_metadata, execution_info))
            when Protocol::RawRowsResultResponse
              execution_info  = create_execution_info(keyspace, statement, options, request, r, hosts)
              result_metadata = statement.result_metadata

              r.materialize(result_metadata)
              future.resolve(Results::Paged.new(result_metadata, r.rows, r.paging_state, execution_info))
            when Protocol::RowsResultResponse
              execution_info = create_execution_info(keyspace, statement, options, request, r, hosts)

              future.resolve(Results::Paged.new(r.metadata, r.rows, r.paging_state, execution_info))
            else
              execution_info = create_execution_info(keyspace, statement, options, request, r, hosts)

              future.resolve(Results::Void.new(execution_info))
            end
          else
            f.on_failure do |e|
              errors ||= {}
              errors[host] = e
              case request
              when Protocol::QueryRequest, Protocol::PrepareRequest
                send_request_by_plan(future, keyspace, statement, options, request, plan, timeout, errors, hosts)
              when Protocol::ExecuteRequest
                execute_by_plan(future, keyspace, statement, options, request, plan, timeout, errors, hosts)
              when Protocol::BatchRequest
                batch_by_plan(future, keyspace, statement, options, plan, timeout, errors, hosts)
              else
                future.fail(e)
              end
            end
          end
        end
      end

      def switch_keyspace(connection, keyspace, timeout)
        pending_keyspace = connection[:pending_keyspace]
        pending_switch   = connection[:pending_switch]

        return pending_switch || Future.resolved if pending_keyspace == keyspace

        f = connection.send_request(Protocol::QueryRequest.new("USE #{keyspace}", nil, nil, :one), timeout).map do |r|
          case r
          when Protocol::SetKeyspaceResultResponse
            @keyspace = r.keyspace
            nil
          when Protocol::DetailedErrorResponse
            raise QueryError.new(r.code, r.message, cql, r.details)
          when Protocol::ErrorResponse
            raise QueryError.new(r.code, r.message, cql, nil)
          else
            raise "unexpected response #{r.inspect}"
          end
        end

        connection[:pending_keyspace] = keyspace
        connection[:pending_switch]   = f

        f.on_complete do |f|
          connection[:pending_switch]   = nil
          connection[:pending_keyspace] = nil
        end

        f
      end

      def prepare_statement(host, connection, cql, timeout)
        synchronize do
          pending = @preparing_statements[host]

          return pending[cql] if pending.has_key?(cql)
        end

        request = Protocol::PrepareRequest.new(cql, false)

        f = connection.send_request(request, timeout).map do |r|
          case r
          when Protocol::PreparedResultResponse
            id = r.id
            synchronize do
              @prepared_statements[host][cql] = id
              @preparing_statements[host].delete(cql)
            end
            id
          when Protocol::DetailedErrorResponse
            raise QueryError.new(r.code, r.message, cql, r.details)
          when Protocol::ErrorResponse
            raise QueryError.new(r.code, r.message, cql, nil)
          else
            raise "unexpected response #{r.inspect}"
          end
        end

        synchronize do
          @preparing_statements[host][cql] = f
        end

        f
      end

      def create_execution_info(keyspace, statement, options, request, response, hosts)
        trace_id = response.trace_id
        trace    = trace_id ? Execution::Trace.new(trace_id, self) : nil
        info     = Execution::Info.new(keyspace, statement, options, hosts, request.consistency, request.retries, trace)
      end
    end
  end
end
