# frozen_string_literal: true

require "rails_helper"

# The `credential_health` block on `GET /api/v1/repository` — the agent-readable half of the
# "Connection" stat's rotation branch, and the one 401-shaped failure this endpoint can report.
#
# Its own file on the endpoint's per-feature convention (`repository_delivery_health_spec.rb`,
# `repository_unstable_tests_spec.rb`, …).
#
# == Why the block is repository-scoped and the `api_key` block is not enough
#
# `Api::BaseController#authenticate_api_key!` stamps `last_used_at` on the way IN, so by the time
# any response is built the requesting key has authenticated BY DEFINITION. "Rotated and not used
# since" is therefore false for the requester on every response this endpoint can ever serve — a
# field for it on `api_key` would be a constant, and these examples pin that it is not served as
# one. The state is real and it belongs to a SIBLING key: another pipeline's token, rotated, with
# the replacement still sitting in someone's clipboard. A client can learn about it precisely
# because reaching this endpoint at all proves its own key works.
#
# ROTATIONS GO THROUGH `ApiKey#regenerate!`, never through a hand-set column: the whole defect is
# an ORDERING one between the stamp and the rotation, and a hand-built `rotated_at` would skip the
# digest swap that makes the state real — leaving these examples asserting against a row the
# production path cannot produce.
RSpec.describe "GET /api/v1/repository — credential_health", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create!(name: "Agent") }

  def get_repository
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def credential_health = get_repository["credential_health"]

  # ── The positive finding ────────────────────────────────────────────────────────────────────
  #
  # "No key is stranded" is an ANSWER, and one an agent cannot otherwise tell apart from "SpecGuard
  # does not track that". The block is unconditional and its empty state is a real state. The same
  # rule now covers SPGD-804's keys: `revoked_key_presented` and `presented_revoked_keys` are
  # served on every response, negative included — a negative finding here is the answer "no revoked
  # token is being presented", not an omission.
  describe "a repository with no rotated key" do
    # @intent: { entity: "credential_health", action: "serve the empty state", behavior: "a repository with no rotated or presented-revoked key gets the full block with both verdicts negative and both lists empty rather than an omitted block", layer: "request" }
    it "serves the block with a negative verdict rather than omitting it" do
      health = credential_health

      expect(health).to eq(
        "rotated_and_unused" => false,
        "keys" => [],
        "revoked_key_presented" => false,
        "presented_revoked_keys" => []
      )
    end

    # @intent: { entity: "credential_health", action: "clear on first use", behavior: "one use of the replacement after a rotation clears the stranded verdict, with no window to expire and no threshold to cross", layer: "request" }
    it "keeps saying so after a rotation whose replacement has been used" do
      stale = repository.api_keys.create!(name: "CI")
      stale.regenerate!
      stale.touch_last_used!

      # One use and the key is no longer stranded — the same recovery rule the UI follows, with no
      # window to expire and no threshold to cross.
      expect(credential_health["rotated_and_unused"]).to be(false)
      expect(credential_health["keys"]).to be_empty
    end
  end

  describe "a repository holding a key nothing has used since its rotation" do
    let!(:stranded) do
      repository.api_keys.create!(name: "CI — main").tap do |key|
        # The use is placed two hours back rather than stamped at `Time.current`: the rotation that
        # follows is a real `regenerate!`, and without the separation both events land in the same
        # second and `iso8601` renders them identical — which would hide the very ordering these
        # examples are about. The stamp itself is the one `touch_last_used!` writes.
        key.touch_last_used!
        key.update_columns(last_used_at: 2.hours.ago)
        key.regenerate!
      end
    end

    # @intent: { entity: "credential_health", action: "name the stranded key", behavior: "the verdict comes with the stranded key name, so the remedy can name which secret store to update", layer: "request" }
    it "reports the state and names which key, so the remedy is actionable" do
      health = credential_health

      # A bare boolean would tell an agent something is wrong and leave it unable to say which
      # secret store to update.
      expect(health["rotated_and_unused"]).to be(true)
      expect(health["keys"].map { |key| key["name"] }).to eq(["CI — main"])
    end

    # @intent: { entity: "credential_health", action: "date the rotation", behavior: "the row serves the rotation date and the stranding last_used_at, the use preserved and ordered before the rotation", layer: "request" }
    it "dates the rotation and serves the stamp it stranded, rather than hiding it" do
      row = credential_health["keys"].first

      expect(row["rotated_at"]).to eq(stranded.reload.rotated_at.iso8601)
      # The use is preserved (SPGD-352) and served — what changed is that it is no longer the only
      # thing on the row, so it can no longer be read as a live reachability signal.
      expect(row["last_used_at"]).to eq(stranded.reload.last_used_at.iso8601)
      expect(row["last_used_at"]).to be < row["rotated_at"]
    end

    # @intent: { entity: "credential_health", action: "null a never-used key", behavior: "a key rotated before it ever authenticated serves a null last_used_at beside its rotation date", layer: "request" }
    it "serves null for a key rotated before it ever authenticated" do
      stranded.destroy!
      never_used = repository.api_keys.create!(name: "Fresh")
      never_used.regenerate!

      row = credential_health["keys"].first

      expect(row["name"]).to eq("Fresh")
      expect(row["last_used_at"]).to be_nil
      expect(row["rotated_at"]).to be_present
    end

    # @intent: { entity: "credential_health", action: "withhold token material", behavior: "the named row carries only name, rotated_at and last_used_at, and no digest or hint appears anywhere in the response body", layer: "request" }
    it "discloses no token material for the key it names" do
      row = credential_health["keys"].first

      # The caller already holds a key here, so naming the others discloses nothing new. A hint or
      # a digest fragment would be a different claim entirely.
      expect(row.keys).to match_array(%w[name rotated_at last_used_at])
      expect(response.body).not_to include(stranded.reload.token_digest)
      expect(response.body).not_to include(stranded.token_hint)
    end
  end

  # ── The revoked-presentation finding (SPGD-804) ─────────────────────────────────────────────
  #
  # Rotation is the 401 the platform reports because it owns the row and stamped the retirement;
  # revocation is now the same shape of fact. A revoked key is RETAINED (`ApiKey#revoke!`), and a
  # refused presentation of its dead token stamps `last_refused_at` on it — so this block can
  # report the one thing an agent polling with a working key could otherwise never learn: that a
  # sibling pipeline is still presenting a token that cannot work.
  #
  # Every fixture here walks the REAL path: revoke through `revoke!`, present the dead token at
  # this endpoint so the failure path stamps it, then read the block with the live key. A
  # hand-written `last_refused_at` would leave these examples asserting against a state no
  # production code path can produce — the same rule the rotation examples state for `regenerate!`.
  describe "a revoked key still being presented" do
    let!(:dead_key) { repository.api_keys.create!(name: "Old CI") }
    let!(:dead_token) { dead_key.raw_token }

    before do
      dead_key.revoke!
      # The presentation itself, through the real path: the dead token arrives, is refused, and
      # stamps the row.
      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{dead_token}" }
      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "credential_health", action: "report the presented revocation", behavior: "a revoked token presented and refused turns revoked_key_presented true and names the key with both stamps", layer: "request" }
    it "reports the revoked key with its revocation and last refusal" do
      health = credential_health

      expect(health["revoked_key_presented"]).to be(true)
      row = health["presented_revoked_keys"].first
      expect(row["name"]).to eq("Old CI")
      expect(row["revoked_at"]).to eq(dead_key.reload.revoked_at.iso8601)
      expect(row["last_refused_at"]).to eq(dead_key.reload.last_refused_at.iso8601)
    end

    # The honesty bound, served as data: a revoked key that was never presented again is not a
    # finding, and nothing may be synthesized for it. The block closes the REVOKED case of the
    # 401s — a token that was never a key for this repository stays unattributable everywhere.
    # @intent: { entity: "credential_health", action: "not invent a presentation", behavior: "a revoked but never-presented key adds nothing to the presented list — the finding requires an observed refused attempt", layer: "request" }
    it "adds nothing for a key revoked and never presented again" do
      repository.api_keys.create!(name: "Quiet").tap(&:revoke!)

      health = credential_health

      # `dead_key` WAS presented (the `before` block), so the verdict stays positive — but the
      # never-presented key must not join the list, by name.
      expect(health["revoked_key_presented"]).to be(true)
      expect(health["presented_revoked_keys"].map { |row| row["name"] }).to eq(["Old CI"])
    end

    # The scoping the ticket pins: a key that was rotated AND THEN revoked must not be reported as
    # merely stranded. The revocation is the newer fact; reporting the rotation would understate
    # the state a client has to act on.
    # @intent: { entity: "credential_health", action: "rank revocation over rotation", behavior: "a key rotated then revoked and still presented appears under presented_revoked_keys and never under the stranded keys list", layer: "request" }
    it "reports a rotated-then-revoked key as revoked, not as stranded" do
      both = repository.api_keys.create!(name: "Both").tap do |key|
        key.touch_last_used!
        key.regenerate!
        key.revoke!
      end
      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{both.raw_token}" }
      expect(response).to have_http_status(:unauthorized)

      health = credential_health

      expect(health["presented_revoked_keys"].map { |row| row["name"] })
        .to contain_exactly("Old CI", "Both")
      expect(health["rotated_and_unused"]).to be(false)
      expect(health["keys"]).to be_empty
    end

    # @intent: { entity: "credential_health", action: "withhold revoked token material", behavior: "a presented_revoked_keys row carries only name, revoked_at and last_refused_at, and no digest or hint appears anywhere in the response body", layer: "request" }
    it "discloses no token material for the revoked key it names" do
      row = credential_health["presented_revoked_keys"].first

      expect(row.keys).to match_array(%w[name revoked_at last_refused_at])
      expect(response.body).not_to include(dead_key.reload.token_digest)
      expect(response.body).not_to include(dead_key.token_hint)
    end
  end

  # ── The requesting key ──────────────────────────────────────────────────────────────────────
  describe "the api_key block" do
    # @intent: { entity: "api_key", action: "serve the rotation date", behavior: "the api_key block serves the requesting key own rotated_at, real after a regenerate and null before one", layer: "request" }
    it "serves the requesting key's own rotation date" do
      api_key.regenerate!

      # Real and discriminating: it moves when the key is rotated and is null when it never was.
      expect(get_repository.dig("api_key", "rotated_at")).to eq(api_key.reload.rotated_at.iso8601)
    end

    # @intent: { entity: "api_key", action: "null an unrotated key", behavior: "an unrotated requesting key serves a null rotated_at rather than any default date", layer: "request" }
    it "serves null for a key that has never been rotated" do
      expect(get_repository.dig("api_key", "rotated_at")).to be_nil
    end

    # @intent: { entity: "api_key", action: "point at the verdict block", behavior: "the api_key block names credential_health via rotation_reported_by as the holder of the repository-grain verdict", layer: "request" }
    it "points at the block that answers what it structurally cannot" do
      body = get_repository

      # The convention `acceptance_reported_by` already follows on this block: name the key that
      # answers the question, rather than leaving a client to discover the distinction by being
      # misled by it once.
      expect(body.dig("api_key", "rotation_reported_by")).to eq("credential_health")
      expect(body).to have_key("credential_health")
    end

    # @intent: { entity: "api_key", action: "omit the impossible verdict", behavior: "the requester can never be rotated-and-unused because authenticating stamps it, so no such field is served on the api_key block", layer: "request" }
    it "serves no per-key rotated-and-unused verdict, which could only ever be false here" do
      api_key.regenerate!

      # Rotated a moment ago — and then USED, by this very request, because authenticating is what
      # stamps the key. This is the whole reason the verdict lives at repository grain: a field for
      # it here would read `false` on every response the endpoint can serve, on a key that was
      # rotated between the two lines above.
      body = get_repository

      expect(api_key.reload).not_to be_rotated_and_unused
      expect(body["api_key"].keys).not_to include("rotated_and_unused")
      expect(body.dig("credential_health", "rotated_and_unused")).to be(false)
    end
  end

  # @intent: { entity: "credential_health", action: "scope to the caller", behavior: "another tenant stranded key neither flips the verdict nor leaks its name into this repository response", layer: "request" }
  it "scopes the verdict to the caller's own repository" do
    other = create_repository(user: create_user(github_uid: "3003", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    other.api_keys.create!(name: "Theirs").tap { |key| key.touch_last_used! }.regenerate!

    # Another tenant's stranded key is not this repository's problem, and its NAME is not this
    # caller's business.
    expect(credential_health["rotated_and_unused"]).to be(false)
    expect(response.body).not_to include("Theirs")
  end
end
