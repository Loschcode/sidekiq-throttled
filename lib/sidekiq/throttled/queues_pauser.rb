# frozen_string_literal: true

require "set"
require "singleton"
require "concurrent/timer_task"

require "sidekiq/throttled/patches/queue"
require "sidekiq/throttled/communicator"
require "sidekiq/throttled/queue_name"

module Sidekiq
  module Throttled
    # Singleton class used to pause queues from being processed.
    # For the sake of efficiency it uses {Communicator} behind the scene
    # to notify all processes about throttle_paused/resumed queues.
    #
    # @private
    class QueuesPauser
      include Singleton

      # Redis key of Set with throttle_paused queues.
      #
      # @return [String]
      THROTTLE_PAUSED_QUEUES = "throttled:X:throttle_paused_queues"
      private_constant :THROTTLE_PAUSED_QUEUES

      # {Communicator} message used to notify that queue needs to be throttle_paused.
      #
      # @return [String]
      PAUSE_MESSAGE = "pause"
      private_constant :PAUSE_MESSAGE

      # {Communicator} message used to notify that queue needs to be resumed.
      #
      # @return [String]
      RESUME_MESSAGE = "resume"
      private_constant :RESUME_MESSAGE

      # Initializes singleton instance.
      def initialize
        @throttle_paused_queues = Set.new
        @communicator  = Communicator.instance
        @mutex         = Mutex.new
      end

      # Configures Sidekiq server to keep actual list of throttle_paused queues.
      #
      # @private
      # @return [void]
      def setup!
        Patches::Queue.apply!

        Sidekiq.configure_server do |config|
          config.on(:startup) { start_watcher }
          config.on(:quiet) { stop_watcher }

          @communicator.receive(PAUSE_MESSAGE, &method(:add))
          @communicator.receive(RESUME_MESSAGE, &method(:delete))
          @communicator.ready { sync! }
        end
      end

      # Returns queues list with throttle_paused queues being stripped out.
      #
      # @private
      # @return [Array<String>]
      def filter(queues)
        @mutex.synchronize { queues - @throttle_paused_queues.to_a }
      rescue => e
        Sidekiq.logger.error { "[#{self.class}] Failed filter queues: #{e}" }
        queues
      end

      # Returns list of throttle_paused queues.
      #
      # @return [Array<String>]
      def throttle_paused_queues
        Sidekiq.redis { |conn| conn.smembers(THROTTLE_PAUSED_QUEUES).to_a }
      end

      # Pauses given `queue`.
      #
      # @param [#to_s] queue
      # @return [void]
      def throttle_pause!(queue)
        queue = QueueName.normalize queue.to_s

        Sidekiq.redis do |conn|
          conn.sadd(THROTTLE_PAUSED_QUEUES, queue)
          @communicator.transmit(conn, PAUSE_MESSAGE, queue)
        end
      end

      # Checks if given `queue` is throttle_paused.
      #
      # @param queue [#to_s]
      # @return [Boolean]
      def throttle_paused?(queue)
        queue = QueueName.normalize queue.to_s
        Sidekiq.redis { |conn| conn.sismember(THROTTLE_PAUSED_QUEUES, queue) }
      end

      # Resumes given `queue`.
      #
      # @param [#to_s] queue
      # @return [void]
      def throttle_resume!(queue)
        queue = QueueName.normalize queue.to_s

        Sidekiq.redis do |conn|
          conn.srem(THROTTLE_PAUSED_QUEUES, queue)
          @communicator.transmit(conn, RESUME_MESSAGE, queue)
        end
      end

      private

      def add(queue)
        @mutex.synchronize do
          @throttle_paused_queues << QueueName.expand(queue)
        end
      end

      def delete(queue)
        @mutex.synchronize do
          @throttle_paused_queues.delete QueueName.expand(queue)
        end
      end

      def sync!
        @mutex.synchronize do
          @throttle_paused_queues.replace(throttle_paused_queues.map { |q| QueueName.expand q })
        end
      end

      def start_watcher
        @mutex.synchronize do
          @watcher ||= Concurrent::TimerTask.execute({
            :run_now            => true,
            :execution_interval => 60
          }) { sync! }
        end
      end

      def stop_watcher
        @mutex.synchronize do
          defined?(@watcher) && @watcher&.shutdown
        end
      end
    end
  end
end
