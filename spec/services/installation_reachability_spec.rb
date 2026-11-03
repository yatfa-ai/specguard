# frozen_string_literal: true

require "rails_helper"

# The two branches of `InstallationReachability` that `spec/requests/account_github_installations_spec.rb`
# cannot reach: its `forget` always empties the cache first, so a clean answer that does not know a
# row the person now holds, and a clean answer that has outlived `KEEP_FOR`, are never held there.
RSpec.describe InstallationReachability do
  include ActiveSupport::Testing::TimeHelpers

  # Test env is :null_store, which would make every call a first call.
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:user) { Struct.new(:id).new(4242) }
  let(:installation) { Struct.new(:installation_id) }
  let(:t0) { Time.zone.local(2026, 11, 3, 12, 0, 0) }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    travel_to(t0)
  end

  after { travel_back }

  def outcome(id, status)
    InstallationRepositories::Outcome.new(account: "acct-#{id}", status: status, count: 0, installation_id: id)
  end

  def sources(*outcomes, error: nil)
    InstallationRepositories::Sources.new(repos: [], truncated: false, error: error, installed: true,
                                          outcomes: outcomes)
  end

  def unreachable_ids(*ids)
    described_class.unreachable_ids(user, installations: ids.map { |id| installation.new(id) }, user_token: "t")
  end

  describe ".unreachable_ids" do
    # @intent: { entity: "InstallationReachability", action: "answer for an installation the cached clean walk never saw", behavior: "within FRESH_FOR a clean cached reading that lacks a row the person now holds is not trusted: the walk is made again and the new row's 404 is named", layer: "unit" }
    it "walks again within the hour when the person holds an installation the cached clean walk never saw" do
      allow(InstallationRepositories).to receive(:sources).and_return(sources(outcome(5001, :read)))
      expect(unreachable_ids(5001)).to eq(Set[])

      travel_to(t0 + 10.minutes)
      allow(InstallationRepositories).to receive(:sources)
        .and_return(sources(outcome(5001, :read), outcome(6002, :unreadable)))

      expect(unreachable_ids(5001, 6002)).to eq(Set[6002])
      expect(InstallationRepositories).to have_received(:sources).twice
    end

    # @intent: { entity: "InstallationReachability", action: "keep a clean answer across failed re-walks", behavior: "a clean answer younger than KEEP_FOR is still rendered after a later walk fails, and one older than KEEP_FOR is dropped even though every failed attempt rewrites the cache entry's own expiry", layer: "unit" }
    it "renders a clean answer a failed re-walk kept up to KEEP_FOR and not beyond" do
      allow(InstallationRepositories).to receive(:sources).and_return(sources(outcome(6002, :unreadable)))
      expect(unreachable_ids(6002)).to eq(Set[6002])

      allow(InstallationRepositories).to receive(:sources).and_return(sources(error: :boom))

      travel_to(t0 + 23.hours)
      expect(unreachable_ids(6002)).to eq(Set[6002])

      travel_to(t0 + 25.hours)
      expect(unreachable_ids(6002)).to eq(Set[])
    end

    # @intent: { entity: "InstallationReachability", action: "make no claim from an outcome that names no installation", behavior: "a walk containing an outcome with no installation_id makes no claim, so nothing is named unreachable", layer: "unit" }
    it "makes no claim when an outcome names no installation" do
      allow(InstallationRepositories).to receive(:sources)
        .and_return(sources(outcome(nil, :unreadable), outcome(6002, :unreadable)))

      expect(unreachable_ids(6002)).to eq(Set[])
    end
  end
end
