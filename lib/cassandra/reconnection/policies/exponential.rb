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
  module Reconnection
    module Policies
      # A reconnection policy that returns a constant exponentially growing
      # reconnection interval up to a given maximum, optionally randomised by
      # a jitter fraction so that many clients do not reconnect in lockstep.
      class Exponential < Policy
        # @private
        class Schedule
          def initialize(start, max, exponent, jitter, random)
            @interval = start
            @max      = max
            @exponent = exponent
            @jitter   = jitter
            @random   = random
          end

          def next
            interval = @interval
            backoff if @interval < @max
            randomize(interval)
          end

          private

          def backoff
            new_interval = @interval * @exponent

            @interval = if new_interval >= @max
                          @max
                        else
                          new_interval
                        end
          end

          # Spreads the interval by up to +/- jitter, never above the maximum.
          def randomize(interval)
            return interval if @jitter.zero?

            lower = interval * (1 - @jitter)
            upper = [interval * (1 + @jitter), @max].min
            lower + (upper - lower) * @random.rand
          end
        end

        # @param start    [Numeric] beginning interval
        # @param max      [Numeric] maximum reconnection interval; never
        #   exceeded, even with jitter
        # @param exponent [Numeric] (2) interval exponent to use
        # @param jitter   [Numeric] (0) fraction in `0...1` by which each
        #   interval is randomised, e.g. `0.25` for +/- 25%
        # @param random   [#rand] (Random) source of randomness for
        #   jitter
        #
        # @raise [ArgumentError] if jitter is not in `0...1`
        #
        # @example Using this policy
        #   policy   = Cassandra::Reconnection::Policies::Exponential.new(0.5, 10, 2)
        #   schedule = policy.schedule
        #   schedule.next # 0.5
        #   schedule.next # 1.0
        #   schedule.next # 2.0
        #   schedule.next # 4.0
        #   schedule.next # 8.0
        #   schedule.next # 10.0
        #   schedule.next # 10.0
        #   schedule.next # 10.0
        #
        # @example With jitter, so that a fleet does not reconnect in lockstep
        #   policy   = Cassandra::Reconnection::Policies::Exponential.new(1, 60, 2, jitter: 0.25)
        #   schedule = policy.schedule
        #   schedule.next # somewhere in 0.75..1.25
        #   schedule.next # somewhere in 1.5..2.5
        #   # ...
        #   schedule.next # somewhere in 45..60
        def initialize(start, max, exponent = 2, jitter: 0, random: ::Random)
          begin
            jitter = Float(jitter)
          rescue ::TypeError, ::ArgumentError
            raise ::ArgumentError, "jitter must be in 0...1, #{jitter.inspect} given"
          end
          unless jitter >= 0 && jitter < 1
            raise ::ArgumentError, "jitter must be in 0...1, #{jitter.inspect} given"
          end

          @start    = start
          @max      = max
          @exponent = exponent
          @jitter   = jitter
          @random   = random
        end

        # @return [Cassandra::Reconnection::Schedule] an exponential
        #   reconnection schedule
        def schedule
          Schedule.new(@start, @max, @exponent, @jitter, @random)
        end
      end
    end
  end
end
