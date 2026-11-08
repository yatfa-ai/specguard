# frozen_string_literal: true

# The retirement contract of a credential row, pinned ONCE for each of the key models that include
# `CredentialRetirement` (`ApiKey`, `UserApiKey`, `AgentApiKey`):
#
#   it_behaves_like "a retirable credential", build: -> { repository.api_keys.create! }
#
# One group rather than one hand-written copy per class, for the reason the module exists: the
# mechanism is shared, so a shape the contract tolerates for one key kind is a shape it tolerates
# for all of them, and a fix to it is pinned everywhere at once.
#
# What it pins: the `live`/`revoked` scopes partition the table; `revoke!` retires and keeps the
# row; FIRST REVOCATION WINS (a replayed `revoke!` never moves `revoked_at`, which is what keeps
# `revoked_at` from landing after `last_refused_at`); `revoked_and_still_presented?` is true only
# for a revoked row with a stamped refusal; and `touch_last_refused!` stamps `last_refused_at`.
# What it deliberately does not: how a token authenticates, or anything about a single class's
# own columns — those stay in the class's spec.
#
# Options:
#   build: required. A lambda taking no arguments and returning a NEW, persisted, live key of the
#          class under test, each call a distinct row. Run via `instance_exec`, so
#          `described_class` and the host group's `let`s and helpers are in scope. It must build a
#          fresh row per call: the examples revoke what they build.
#
# The host group must `include ActiveSupport::Testing::TimeHelpers` — the first-revocation examples
# move the clock to put the replay strictly after the refusal.
RSpec.shared_examples "a retirable credential" do |options|
  build = options.fetch(:build)

  describe "retirement" do
    let(:key) { instance_exec(&build) }

    # @intent: { entity: "CredentialRetirement", action: "partition live and revoked", behavior: "the live and revoked scopes split the table exactly, with no row in both and no row in neither, and neither side is hidden by a default scope", layer: "unit" }
    it "partitions the table into live and revoked rows" do
      live_key = key
      revoked_key = instance_exec(&build).tap(&:revoke!)

      expect(described_class.count).to eq(2)
      expect(described_class.live).to contain_exactly(live_key)
      expect(described_class.revoked).to contain_exactly(revoked_key)
    end

    # @intent: { entity: "CredentialRetirement", action: "retire a key", behavior: "revoke! stamps revoked_at, keeps the row and returns the key, so a retirement is never a deletion", layer: "unit" }
    it "retires without deleting, and returns the key" do
      expect(key).not_to be_revoked
      expect(key.revoked_at).to be_nil

      expect { expect(key.revoke!).to eq(key) }.not_to change(described_class, :count)

      expect(key.reload.revoked_at).to be_present
      expect(key).to be_revoked
    end

    # First revocation wins: a replayed revoke reaches the row (the destroy actions look it up
    # without `live`) and must not re-stamp — the FIRST stamp is the offboarding date.
    # @intent: { entity: "CredentialRetirement", action: "keep the first revocation stamp", behavior: "a replayed revoke! is a no-op: revoked_at keeps its first value and the row is returned unchanged", layer: "unit" }
    it "never re-stamps revoked_at on a replayed revoke!" do
      first_day = Time.utc(2026, 10, 1, 9, 0, 0)

      travel_to(first_day) { key.revoke! }
      stamped_at = key.reload.revoked_at
      travel_to(first_day + 2.days) { expect(key.revoke!).to eq(key) }

      expect(stamped_at).to eq(first_day)
      expect(key.reload.revoked_at).to eq(stamped_at)
    end

    # The consequence the no-re-stamp rule exists for: the refusal stamp postdates the revocation,
    # and a replay after a refusal must not invert that.
    # @intent: { entity: "CredentialRetirement", action: "keep revocation before refusal", behavior: "a replayed revoke! after a refused presentation leaves revoked_at unchanged and at or before last_refused_at", layer: "unit" }
    it "keeps revoked_at at or before last_refused_at when revoke! is replayed after a refusal" do
      first_day = Time.utc(2026, 10, 1, 9, 0, 0)

      travel_to(first_day) { key.revoke! }
      stamped_at = key.reload.revoked_at
      travel_to(first_day + 1.day) { key.touch_last_refused! }
      travel_to(first_day + 2.days) { key.revoke! }

      expect(key.reload.revoked_at).to eq(stamped_at)
      expect(key.revoked_at).to be <= key.last_refused_at
    end

    # The truth table of the predicate: only a revoked row that has also been refused reads as
    # still presented. A live row stamped with a refusal (which the failure path structurally
    # cannot produce) must not read as retired, and a revoked row nobody presented again is not a
    # finding — nothing is synthesized for it.
    # @intent: { entity: "CredentialRetirement", action: "report a still-presented revoked token", behavior: "revoked_and_still_presented? is true only for a row that is both revoked and refusal-stamped, and false for a live row, a revoked-never-refused row and a live row carrying a refusal stamp", layer: "unit" }
    it "reads as still presented only when revoked and refusal-stamped" do
      live = key
      expect(live).not_to be_revoked_and_still_presented

      # A refusal stamp on a LIVE row: pinned so the answer does not depend on how the column got
      # its value.
      live.touch_last_refused!
      expect(live).not_to be_revoked
      expect(live).not_to be_revoked_and_still_presented

      revoked = instance_exec(&build).tap(&:revoke!)
      expect(revoked).to be_revoked
      expect(revoked).not_to be_revoked_and_still_presented

      revoked.touch_last_refused!
      expect(revoked).to be_revoked_and_still_presented
    end

    # @intent: { entity: "CredentialRetirement", action: "stamp a refusal", behavior: "touch_last_refused! writes last_refused_at to the row, nil before it and the current time after it", layer: "unit" }
    it "stamps last_refused_at when a refusal is recorded" do
      expect(key.reload.last_refused_at).to be_nil

      travel_to(Time.utc(2026, 10, 1, 9, 0, 0)) { key.touch_last_refused! }

      expect(key.reload.last_refused_at).to eq(Time.utc(2026, 10, 1, 9, 0, 0))
    end
  end
end
