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

module Cassandra
  module Reconnection
    module Policies
      describe(Exponential) do
        describe('#schedule') do
          it 'grows exponentially up to the ceiling' do
            schedule = Exponential.new(0.5, 10, 2).schedule
            expect(Array.new(7) { schedule.next }).to eq([0.5, 1.0, 2.0, 4.0, 8.0, 10, 10])
          end

          it 'has no jitter by default' do
            intervals = Array.new(20) { Exponential.new(1, 60, 2).schedule.next }
            expect(intervals.uniq).to eq([1])
          end

          context('with jitter') do
            let(:policy) { Exponential.new(1, 60, 2, jitter: 0.25) }

            it 'randomises each interval within the requested fraction' do
              first = Array.new(50) { policy.schedule.next }
              expect(first).to all(be_between(0.75, 1.25))
              expect(first.uniq.size).to be > 1

              schedule = policy.schedule
              schedule.next
              expect(schedule.next).to be_between(1.5, 2.5)
            end

            it 'never exceeds the ceiling' do
              schedule  = policy.schedule
              intervals = Array.new(20) { schedule.next }
              expect(intervals).to all(be <= 60)
              expect(intervals.last(5)).to all(be_between(45, 60))
            end

            it 'uses the given source of randomness' do
              random = double('random', rand: 1.0)
              schedule = Exponential.new(1, 60, 2, jitter: 0.25, random: random).schedule
              expect(schedule.next).to eq(1.25)
            end

            it 'spreads draws uniformly across the bounded window at the ceiling' do
              random = double('random')
              allow(random).to receive(:rand).and_return(0.0, 0.25, 0.5, 0.75)
              schedule = Exponential.new(60, 60, 2, jitter: 0.25, random: random).schedule

              expect(Array.new(4) { schedule.next }).to eq([45, 48.75, 52.5, 56.25])
            end

            it 'bounds the window before drawing when approaching the ceiling' do
              random = double('random', rand: 0.5)
              schedule = Exponential.new(50, 60, 2, jitter: 0.25, random: random).schedule

              expect(schedule.next).to eq(48.75)
            end

            it 'rejects a jitter outside 0...1' do
              expect { Exponential.new(1, 60, 2, jitter: 1) }.to raise_error(::ArgumentError)
              expect { Exponential.new(1, 60, 2, jitter: -0.1) }.to raise_error(::ArgumentError)
            end

            it 'rejects invalid jitter values with ArgumentError' do
              [nil, Object.new, 'invalid', Float::NAN].each do |jitter|
                expect { Exponential.new(1, 60, 2, jitter: jitter) }.to raise_error(::ArgumentError)
              end
            end
          end
        end
      end
    end
  end
end
