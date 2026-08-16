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
  # does not track that". The block is unconditional and its empty state is a real state.
  describe "a repository with no rotated key" do
    it "serves the block with a negative verdict rather than omitting it" do
      health = credential_health

      expect(health).to eq("rotated_and_unused" => false, "keys" => [])
    end

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

    it "reports the state and names which key, so the remedy is actionable" do
      health = credential_health

      # A bare boolean would tell an agent something is wrong and leave it unable to say which
      # secret store to update.
      expect(health["rotated_and_unused"]).to be(true)
      expect(health["keys"].map { |key| key["name"] }).to eq(["CI — main"])
    end

    it "dates the rotation and serves the stamp it stranded, rather than hiding it" do
      row = credential_health["keys"].first

      expect(row["rotated_at"]).to eq(stranded.reload.rotated_at.iso8601)
      # The use is preserved (SPGD-352) and served — what changed is that it is no longer the only
      # thing on the row, so it can no longer be read as a live reachability signal.
      expect(row["last_used_at"]).to eq(stranded.reload.last_used_at.iso8601)
      expect(row["last_used_at"]).to be < row["rotated_at"]
    end

    it "serves null for a key rotated before it ever authenticated" do
      stranded.destroy!
      never_used = repository.api_keys.create!(name: "Fresh")
      never_used.regenerate!

      row = credential_health["keys"].first

      expect(row["name"]).to eq("Fresh")
      expect(row["last_used_at"]).to be_nil
      expect(row["rotated_at"]).to be_present
    end

    it "discloses no token material for the key it names" do
      row = credential_health["keys"].first

      # The caller already holds a key here, so naming the others discloses nothing new. A hint or
      # a digest fragment would be a different claim entirely.
      expect(row.keys).to match_array(%w[name rotated_at last_used_at])
      expect(response.body).not_to include(stranded.reload.token_digest)
      expect(response.body).not_to include(stranded.token_hint)
    end
  end

  # ── The requesting key ──────────────────────────────────────────────────────────────────────
  describe "the api_key block" do
    it "serves the requesting key's own rotation date" do
      api_key.regenerate!

      # Real and discriminating: it moves when the key is rotated and is null when it never was.
      expect(get_repository.dig("api_key", "rotated_at")).to eq(api_key.reload.rotated_at.iso8601)
    end

    it "serves null for a key that has never been rotated" do
      expect(get_repository.dig("api_key", "rotated_at")).to be_nil
    end

    it "points at the block that answers what it structurally cannot" do
      body = get_repository

      # The convention `acceptance_reported_by` already follows on this block: name the key that
      # answers the question, rather than leaving a client to discover the distinction by being
      # misled by it once.
      expect(body.dig("api_key", "rotation_reported_by")).to eq("credential_health")
      expect(body).to have_key("credential_health")
    end

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
