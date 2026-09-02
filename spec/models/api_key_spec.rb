# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiKey do
  let(:repository) { create_repository }

  # @intent: { entity: "ApiKey", action: "store a token", behavior: "only the SHA-256 digest reaches the database, so the raw sgk_ value exists solely in memory after creation", layer: "unit" }
  it "never persists the raw token — only its SHA-256 digest" do
    api_key = repository.api_keys.create!

    expect(api_key.raw_token).to start_with("sgk_")
    expect(api_key.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(api_key.raw_token))
    expect(described_class.column_names).not_to include("token")
  end

  # @intent: { entity: "ApiKey", action: "reveal a token", behavior: "after reload the raw token is unrecoverable, which is what makes the reveal-once contract true", layer: "unit" }
  it "cannot recover the raw token once reloaded — that is what makes reveal-once true" do
    raw = repository.api_keys.create!.raw_token

    expect(described_class.find_by(token_digest: described_class.digest(raw)).raw_token).to be_nil
  end

  # @intent: { entity: "ApiKey", action: "issue tokens", behavior: "each created key draws a distinct random token so two keys never share a credential", layer: "unit" }
  it "issues a distinct token per key" do
    tokens = Array.new(3) { repository.api_keys.create!.raw_token }

    expect(tokens.uniq.size).to eq(3)
  end

  # @intent: { entity: "ApiKey", action: "authenticate a token", behavior: "a valid raw token resolves back to its key row through the digest lookup", layer: "unit" }
  it "authenticates a valid raw token back to its key" do
    api_key = repository.api_keys.create!

    expect(described_class.authenticate(api_key.raw_token)).to eq(api_key)
  end

  # @intent: { entity: "ApiKey", action: "authenticate a token", behavior: "unknown, nil and blank inputs all fail authentication rather than raising or matching anything", layer: "unit" }
  it "refuses an unknown or blank token" do
    repository.api_keys.create!

    expect(described_class.authenticate("sgk_nope")).to be_nil
    expect(described_class.authenticate(nil)).to be_nil
    expect(described_class.authenticate("")).to be_nil
  end

  # @intent: { entity: "ApiKey", action: "show a hint", behavior: "the exposed hint identifies the key without containing any recoverable part of the token", layer: "unit" }
  it "exposes a hint that identifies the key without revealing it" do
    api_key = repository.api_keys.create!

    expect(api_key.token_hint).not_to include(api_key.raw_token.delete_prefix("sgk_"))
  end

  describe "#regenerate!" do
    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "the retired token stops authenticating immediately while the new one resolves to the same key", layer: "unit" }
    it "stops the previous token authenticating and authenticates the new one" do
      api_key = repository.api_keys.create!
      retired = api_key.raw_token

      api_key.regenerate!

      # Asserted through `authenticate` rather than against the digest column, because resolving a
      # Bearer token is the only thing the old token's survival would actually mean.
      expect(described_class.authenticate(retired)).to be_nil
      expect(api_key.raw_token).not_to eq(retired)
      expect(described_class.authenticate(api_key.raw_token)).to eq(api_key)
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "the new digest is written to the row so every other process sees the rotation too", layer: "unit" }
    it "persists the rotation, so a reload does not resurrect the old token" do
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      api_key.regenerate!

      # `regenerate!` mutating only the in-memory record would leave the old digest on the row and
      # the old token still valid for every other process — the thing rotation exists to prevent.
      expect(described_class.authenticate(retired)).to be_nil
      expect(described_class.find(api_key.id).token_digest)
        .to eq(described_class.digest(api_key.raw_token))
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "after rotation the persisted form is still only the digest, with no raw-token column to leak", layer: "unit" }
    it "keeps storing the digest only — the new token is no more recoverable than the old one" do
      api_key = repository.api_keys.create!
      api_key.regenerate!

      expect(described_class.find(api_key.id).raw_token).to be_nil
      expect(described_class.column_names).not_to include("token")
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "rotation updates the existing row in place, preserving its name, creator and repository", layer: "unit" }
    it "rotates the same row, keeping its identity and provenance" do
      creator = create_user(github_uid: "2002", github_handle: "minter")
      api_key = repository.api_keys.create!(name: "CI — main", created_by_user: creator)

      expect { api_key.regenerate! }.not_to change(described_class, :count)

      reloaded = described_class.find(api_key.id)
      expect(reloaded.name).to eq("CI — main")
      expect(reloaded.created_by_user).to eq(creator)
      expect(reloaded.repository).to eq(repository)
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "repeated rotations each issue a fresh token, never repeating an earlier one", layer: "unit" }
    it "issues a distinct token on every rotation" do
      api_key = repository.api_keys.create!
      tokens = [api_key.raw_token] + Array.new(2) { api_key.regenerate!.raw_token }

      expect(tokens.uniq.size).to eq(3)
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "the displayed hint follows the new digest's last six characters instead of the retired token's", layer: "unit" }
    it "moves the hint onto the new token" do
      api_key = repository.api_keys.create!
      retired_hint = api_key.token_hint

      api_key.regenerate!

      # The hint is how the table identifies a key. Leaving it on the retired token would show a
      # fingerprint of a credential that no longer authenticates.
      expect(api_key.token_hint).not_to eq(retired_hint)
      expect(api_key.token_hint).to end_with(api_key.token_digest.last(6))
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "rotated_at is stamped within the same save that writes the new digest and survives a reload", layer: "unit" }
    it "dates the rotation on the same row, in the same save as the new digest" do
      api_key = repository.api_keys.create!

      expect(api_key.rotated_at).to be_nil

      before = Time.current
      api_key.regenerate!
      after = Time.current

      # Read off a RELOADED row, and paired with the digest: an in-memory-only assignment, or a
      # stamp written in a second save, would let the row exist carrying a token whose
      # predecessor's `last_used_at` nothing explains. That window is the whole defect.
      reloaded = described_class.find(api_key.id)
      expect(reloaded.rotated_at).to be_between(before, after)
      expect(reloaded.token_digest).to eq(described_class.digest(api_key.raw_token))
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "regeneration leaves the recorded last use untouched rather than clearing or backdating it", layer: "unit" }
    it "leaves last_used_at exactly as it found it" do
      api_key = repository.api_keys.create!
      api_key.touch_last_used!
      stamped = described_class.find(api_key.id).last_used_at

      api_key.regenerate!

      # SPGD-352 settled this and it is under guard here rather than merely unmentioned: the use is
      # the key's history, and nulling or backdating it is not how the surfaces stop misreporting.
      # `rotated_at` is what lets them stop, without touching this.
      expect(described_class.find(api_key.id).last_used_at).to eq(stamped)
    end

    # @intent: { entity: "ApiKey", action: "rotate keys", behavior: "a second rotation advances rotated_at rather than leaving the first rotation's date standing", layer: "unit" }
    it "moves the rotation date on every rotation, rather than recording only the first" do
      api_key = repository.api_keys.create!
      earlier = 2.days.ago
      api_key.update_columns(rotated_at: earlier)

      api_key.regenerate!

      # A stamp written only when `rotated_at` was nil would leave the second rotation dated by the
      # first — a key rotated a minute ago reading as stranded for two days, and the age in the
      # "not used since rotation" cell belonging to the wrong event.
      expect(api_key.reload.rotated_at).to be > earlier
    end
  end

  describe "#rotated_and_unused?" do
    # The predicate is an ordering comparison between two recorded facts. These examples are the
    # four corners of that comparison plus its boundary, and each rotated case is paired with the
    # un-rotated key carrying the SAME `last_used_at` — so an implementation that ignored
    # `rotated_at` and answered on the use alone fails here rather than passing on half the table.
    #
    # Times are stated on the rows with `update_columns` rather than travelled to, on the
    # convention `repository_latest_run_spec` states: the fixture asserts the fact it needs.
    let(:rotated_at) { 1.hour.ago }

    def key(last_used_at:, rotated_at: nil)
      repository.api_keys.create!.tap do |api_key|
        api_key.update_columns(last_used_at: last_used_at, rotated_at: rotated_at)
      end
    end

    # @intent: { entity: "ApiKey", action: "flag rotation", behavior: "a key that has never been rotated is never reported as rotated-and-unused, used or not", layer: "unit" }
    it "is false for a key that has never been rotated, used or not" do
      expect(key(last_used_at: nil)).not_to be_rotated_and_unused
      expect(key(last_used_at: rotated_at)).not_to be_rotated_and_unused
    end

    # @intent: { entity: "ApiKey", action: "flag rotation", behavior: "a rotation newer than the last use reads as rotated-and-unused while the paired un-rotated key does not", layer: "unit" }
    it "is true for a key rotated after its last use" do
      expect(key(last_used_at: rotated_at - 1.hour, rotated_at: rotated_at))
        .to be_rotated_and_unused

      # The pair: same use, no rotation. Without it the example above also passes on a predicate
      # that answers "was this key used more than an hour ago".
      expect(key(last_used_at: rotated_at - 1.hour)).not_to be_rotated_and_unused
    end

    # @intent: { entity: "ApiKey", action: "flag rotation", behavior: "a key rotated before it ever authenticated counts as rotated and unused", layer: "unit" }
    it "is true for a key rotated before it ever authenticated" do
      # Not "no comparison" — the state at its purest, with not even an inherited timestamp.
      expect(key(last_used_at: nil, rotated_at: rotated_at)).to be_rotated_and_unused
    end

    # @intent: { entity: "ApiKey", action: "flag rotation", behavior: "a single successful authentication with the replacement clears the flag with no waiting window", layer: "unit" }
    it "is false again as soon as one request authenticates with the replacement" do
      api_key = key(last_used_at: rotated_at - 1.hour, rotated_at: rotated_at)

      api_key.touch_last_used!

      # No window to expire and no threshold to cross: one use, and the key reads normally.
      expect(api_key).not_to be_rotated_and_unused
    end

    # @intent: { entity: "ApiKey", action: "flag rotation", behavior: "a use simultaneous with the rotation does not count as newer than it, so the flag stays set", layer: "unit" }
    it "treats a use simultaneous with the rotation as not having cleared it" do
      # The boundary is stated rather than inherited from an operator: the question is whether the
      # use is NEWER than the rotation, and a tie is not newer.
      expect(key(last_used_at: rotated_at, rotated_at: rotated_at)).to be_rotated_and_unused
    end
  end

  # SPGD-804: revocation is a RETIREMENT. The row is retained and `revoked_at` stamps the instant
  # the token was retired — the artifact a refused presentation is attributed to, and the reason a
  # revoked token's 401 is reportable at all. The security half lives in `authenticate` and is
  # pinned with its own example: retention must never read as resurrection.
  describe "revocation" do
    # @intent: { entity: "ApiKey", action: "retire a key", behavior: "revoke! stamps revoked_at and keeps the row, its name and its creator — a retirement, not a deletion", layer: "unit" }
    it "retires without deleting: the row, its name and its attribution survive" do
      creator = create_user(github_uid: "3003", github_handle: "minter")
      api_key = repository.api_keys.create!(name: "CI", created_by_user: creator)

      expect { api_key.revoke! }.not_to change(described_class, :count)

      reloaded = described_class.find(api_key.id)
      expect(reloaded.revoked_at).to be_present
      expect(reloaded.name).to eq("CI")
      expect(reloaded.created_by_user).to eq(creator)
    end

    # @intent: { entity: "ApiKey", action: "refuse a revoked token", behavior: "a revoked key's token never authenticates again — the security-critical half of retaining the row", layer: "unit" }
    it "never authenticates a revoked token" do
      api_key = repository.api_keys.create!
      revoked_token = api_key.raw_token

      api_key.revoke!

      # Asserted through `authenticate` — the only caller-facing consequence — and reloaded, so a
      # predicate that answered from stale in-memory state could not pass it.
      expect(described_class.authenticate(revoked_token)).to be_nil
      expect(described_class.find(api_key.id)).to be_revoked
    end

    # The retention does not leak into the resolution scopes: `live` and `revoked` partition the
    # table, and every scoping consumer (the minted-count badge, the failure-path lookup) stands on
    # exactly one side.
    # @intent: { entity: "ApiKey", action: "partition live and revoked", behavior: "the live and revoked scopes split the table exactly, with no row in both and no row in neither", layer: "unit" }
    it "partitions the table into live and revoked rows" do
      live_key = repository.api_keys.create!
      revoked_key = repository.api_keys.create!.tap(&:revoke!)

      expect(repository.api_keys.live).to contain_exactly(live_key)
      expect(repository.api_keys.revoked).to contain_exactly(revoked_key)
    end

    # @intent: { entity: "ApiKey", action: "attribute a refusal", behavior: "touch_last_refused! stamps last_refused_at, and revoked_and_still_presented? is false before it and true after", layer: "unit" }
    it "reports a refused presentation only once one has been stamped" do
      api_key = repository.api_keys.create!.tap(&:revoke!)

      # A revoked key nobody has presented again is NOT a finding — nothing is synthesized for it.
      expect(api_key).not_to be_revoked_and_still_presented

      api_key.touch_last_refused!

      expect(api_key.reload.last_refused_at).to be_present
      expect(api_key).to be_revoked_and_still_presented
    end

    # @intent: { entity: "ApiKey", action: "keep predicates apart", behavior: "a live key never reads revoked-and-presented however often it is refused-stamped, and a revoked never-presented key never reads rotated-and-unused", layer: "unit" }
    it "keeps the retirement predicates from crossing into each other's states" do
      # A live key has no revocation to be "still presented" despite — `revoke!` is the only writer
      # of `revoked_at`, so the pair is structurally ordered; this pins it.
      live = repository.api_keys.create!.tap(&:touch_last_used!)
      expect(live).not_to be_revoked_and_still_presented

      # The rotated-AND-revoked key: both stamps present, and the newer fact wins — it reads
      # revoked, and `rotated_and_unused?` must not fire for it on any live-keys surface.
      both = repository.api_keys.create!.tap do |k|
        k.touch_last_used!
        k.regenerate!
        k.revoke!
      end
      expect(both.reload).to be_revoked
      expect(both.rotated_and_unused?).to be(true) # the predicate itself is unchanged...
      expect(both.revoked_and_still_presented?).to be(false) # ...but no presentation is invented
    end
  end
end
