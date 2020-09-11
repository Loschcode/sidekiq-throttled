# frozen_string_literal: true

RSpec.describe Sidekiq::Throttled::QueuesPauser do
  subject(:pauser) { described_class.instance }

  let(:communicator) { Sidekiq::Throttled::Communicator.instance }

  describe "#setup!" do
    before { allow(Sidekiq).to receive(:server?).and_return true }

    let(:throttle_paused_queues) { pauser.instance_variable_get :@throttle_paused_queues }

    it "adds throttle_paused queue to the throttle_paused list" do
      throttle_paused_queues.replace %w[queue:xxx queue:yyy]

      expect(communicator).to receive(:receive).twice do |event, &block|
        block.call "zzz" if "pause" == event
      end

      pauser.setup!

      expect(throttle_paused_queues).to eq Set.new(%w[queue:xxx queue:yyy queue:zzz])
    end

    it "removes resumed queue from throttle_paused list" do
      throttle_paused_queues.replace %w[queue:xxx queue:yyy]

      expect(communicator).to receive(:receive).twice do |event, &block|
        block.call "yyy" if "resume" == event
      end

      pauser.setup!

      expect(throttle_paused_queues).to eq Set.new(%w[queue:xxx])
    end

    it "resets throttle_paused queues each time communicator becomes ready" do
      throttle_paused_queues << "garbage"

      expect(communicator).to receive(:ready) do |&block|
        expect(pauser)
          .to receive(:throttle_paused_queues)
          .and_return(%w[foo bar])

        block.call
        expect(throttle_paused_queues).to eq Set.new(%w[queue:foo queue:bar])
      end

      pauser.setup!
    end
  end

  describe "#filter" do
    it "returns list without throttle_paused queues" do
      queues = %w[queue:xxx queue:yyy queue:zzz]
      throttle_paused = Set.new %w[queue:yyy queue:zzz]

      pauser.instance_variable_set(:@throttle_paused_queues, throttle_paused)
      expect(pauser.filter(queues)).to eq %w[queue:xxx]
    end
  end

  describe "#throttle_paused_queues" do
    it "returns list of throttle_paused quques" do
      %w[foo bar].each { |q| pauser.throttle_pause! q }
      expect(pauser.throttle_paused_queues).to match_array %w[foo bar]
    end

    it "fetches list from redis" do
      Sidekiq.redis do |conn|
        expect(conn)
          .to receive(:smembers).with("throttled:X:throttle_paused_queues")
          .and_call_original

        pauser.throttle_paused_queues
      end
    end
  end

  describe "#throttle_pause!" do
    it "normalizes given queue name" do
      expect(Sidekiq::Throttled::QueueName)
        .to receive(:normalize).with("foo:bar")
        .and_call_original

      pauser.throttle_pause! "foo:bar"
    end

    it "pushes normalized queue name to the throttle_paused queues list" do
      Sidekiq.redis do |conn|
        expect(conn)
          .to receive(:sadd).with("throttled:X:throttle_paused_queues", "xxx")
          .and_call_original

        pauser.throttle_pause! "foo:bar:queue:xxx"
      end
    end

    it "sends notification over communicator" do
      Sidekiq.redis do |conn|
        expect(communicator)
          .to receive(:transmit).with(conn, "pause", "xxx")
          .and_call_original

        pauser.throttle_pause! "foo:bar:queue:xxx"
      end
    end
  end

  describe "#throttle_paused?" do
    before { pauser.throttle_pause! "xxx" }

    it "normalizes given queue name" do
      expect(Sidekiq::Throttled::QueueName)
        .to receive(:normalize).with("xxx")
        .and_call_original

      pauser.throttle_paused? "xxx"
    end

    context "when queue is throttle_paused" do
      subject { pauser.throttle_paused? "xxx" }

      it { is_expected.to be true }
    end

    context "when queue is not throttle_paused" do
      subject { pauser.throttle_paused? "yyy" }

      it { is_expected.to be false }
    end
  end

  describe "#throttle_resume!" do
    it "normalizes given queue name" do
      expect(Sidekiq::Throttled::QueueName)
        .to receive(:normalize).with("foo:bar")
        .and_call_original

      pauser.throttle_resume! "foo:bar"
    end

    it "pushes normalized queue name to the throttle_paused queues list" do
      Sidekiq.redis do |conn|
        expect(conn)
          .to receive(:srem).with("throttled:X:throttle_paused_queues", "xxx")
          .and_call_original

        pauser.throttle_resume! "foo:bar:queue:xxx"
      end
    end

    it "sends notification over communicator" do
      Sidekiq.redis do |conn|
        expect(communicator)
          .to receive(:transmit).with(conn, "resume", "xxx")
          .and_call_original

        pauser.throttle_resume! "foo:bar:queue:xxx"
      end
    end
  end

  describe "#sync!" do
    it "is called once communicator is ready" do
      allow(Sidekiq).to receive(:server?).and_return(true)
      pauser.setup!
      expect(pauser).to receive(:sync!).and_call_original.at_least(:once)
      communicator.instance_variable_get(:@callbacks).run("ready")
    end
  end
end
