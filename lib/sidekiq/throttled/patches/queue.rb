# frozen_string_literal: true

module Sidekiq
  module Throttled
    module Patches
      module Queue
        def throttle_paused?
          QueuesPauser.instance.throttle_paused? name
        end

        def self.apply!
          require "sidekiq/api"
          ::Sidekiq::Queue.send(:prepend, self)
        end
      end
    end
  end
end
