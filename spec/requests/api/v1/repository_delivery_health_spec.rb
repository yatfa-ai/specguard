# frozen_string_literal: true

require "rails_helper"

# The `delivery_health` block on `GET /api/v1/repository` — the agent-readable half of the
# "Rejected deliveries" panel `repositories#show` has rendered since SPGD-563, and the answer to the
# one question every other key on this endpoint silently assumes: is what CI is sending still being
# ACCEPTED.
#
# Its own file on the endpoint's per-feature convention (`repository_unstable_tests_spec.rb`,
# `repository_latest_run_spec.rb`, …). `spec/requests/api/v1/ingest_rejection_spec.rb` covers the
# WRITE path — what a refused delivery leaves behind — and this file covers the read.
#
# THE ROWS ARE WRITTEN BY `Ingest::RejectionRecorder`, never inserted by hand: that class applies
# both retention bounds and derives `total_reasons_count`, so a hand-built row could disclose a
# truncation the production writer would never produce, or fail to disclose one it always would.
# `occurred_at` is a parameter of that writer rather than something re-stamped afterwards, which is
# what lets these examples place a refusal on either side of an accepted run.
RSpec.describe "GET /api/v1/repository — delivery_health", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query,
                              headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def delivery_health(**) = get_repository(**)["delivery_health"]

  # One refused delivery, through the production writer. `reasons` defaults to a single envelope
  # error because that is what the commonest refusal — a body missing `commit_sha` — produces.
  def refuse(at:, reasons: ["Commit SHA is required"], user_agent: "specguard-rspec/0.3.1")
    Ingest::RejectionRecorder.record(repository, reasons, user_agent: user_agent, occurred_at: at)
  end

  def accept(at:, commit_sha: "feedfacecafebabe")
    create_test_run(repository: repository, commit_sha: commit_sha, created_at: at)
  end

  # ── The positive finding ──────────────────────────────────────────────────────────────────────
  #
  # "Nothing was refused" is an ANSWER, and it is one an agent cannot otherwise distinguish from
  # "SpecGuard does not track that". The block is therefore unconditional, and its empty state is
  # a real state rather than an absent key.
  describe "a repository whose deliveries are all being accepted" do
    before { accept(at: 1.hour.ago) }

    it "serves the block with a negative verdict rather than omitting it" do
      health = delivery_health

      expect(health).to be_present
      expect(health["refusing"]).to be(false)
      expect(health["last_rejection_at"]).to be_nil
      expect(health["rejections"]).to eq([])
    end

    it "discloses both bounds even with nothing to bound" do
      expect(delivery_health["rejections_window"]).to eq(
        "limit" => IngestRejection::PANEL_LIMIT,
        "bounded" => false,
        "retention_rows" => IngestRejection::REPOSITORY_RETENTION_ROWS,
        "any_reasons_truncated" => false
      )
    end
  end

  # ── The verdict ───────────────────────────────────────────────────────────────────────────────
  #
  # `RejectedIngests#refusing?` is an ORDERING between two recorded facts — the newest refusal
  # against the newest ACCEPTED run — rather than a window in hours. These three examples are that
  # rule at the API surface.
  describe "the refusing verdict" do
    it "is true when the newest refusal is newer than the newest accepted run" do
      accept(at: 3.days.ago)
      refuse(at: 1.hour.ago)

      expect(delivery_health["refusing"]).to be(true)
    end

    it "is false when the repository was refused and has ingested cleanly since" do
      refuse(at: 3.days.ago)
      accept(at: 1.hour.ago)

      expect(delivery_health["refusing"]).to be(false)
    end

    # `nil` on the accepted side is not "no comparison to make" — it is the most refusing state
    # there is, and it is the state the whole feature exists for: a repository whose every delivery
    # has been thrown away since the day it was connected.
    it "is true when nothing has EVER been accepted" do
      refuse(at: 1.hour.ago)

      expect(repository.test_runs).to be_empty
      expect(delivery_health["refusing"]).to be(true)
    end

    it "reports the newest refusal's timestamp beside the verdict" do
      refuse(at: 3.hours.ago)
      newest = refuse(at: 1.hour.ago)

      expect(delivery_health["last_rejection_at"]).to eq(newest.occurred_at.iso8601)
    end
  end

  # ── ⭐ THE REGRESSION THIS FEATURE IS ONE MISTAKE AWAY FROM ───────────────────────────────────
  #
  # `Api::V1::RepositoriesController#latest_test_run` is RE-ANCHORED by `?commit_sha=`, deliberately,
  # so every run-grain block describes the named run coherently. Handing that memo to
  # `RejectedIngests` would compare the newest refusal against an arbitrary PINNED OLDER run — so a
  # client bookmarking an old commit on a perfectly healthy repository would be told its pipeline is
  # being refused. That is the same class of falsehood this block exists to remove, reintroduced by
  # the fix, and it is why the accepted side reads `current_repository.latest_test_run` instead.
  describe "a client pinning an older run with ?commit_sha=" do
    # A refusal that sits BETWEEN the two accepted runs: newer than the pinned one, older than the
    # newest. This ordering is the whole trap — with any other, both anchors agree by accident and
    # the example proves nothing.
    before do
      accept(at: 3.days.ago, commit_sha: "0" * 40)
      refuse(at: 2.days.ago)
      accept(at: 1.hour.ago, commit_sha: "f" * 40)
    end

    it "still reports the repository as healthy, because delivery health is not anchored" do
      body = get_repository(query: { commit_sha: "0" * 40 })

      # The re-anchor really happened — without this the example could pass on a sha that matched
      # nothing and fell back to the newest run.
      expect(body["run_anchor"]["source"]).to eq("requested")
      expect(body["run_anchor"]["commit_sha"]).to eq("0" * 40)

      expect(body["delivery_health"]["refusing"]).to be(false)
    end

    it "gives the same verdict pinned as unpinned — the block is a fact about the stream" do
      pinned = delivery_health(query: { commit_sha: "0" * 40 })

      expect(pinned).to eq(delivery_health)
    end
  end

  # ── The rows ──────────────────────────────────────────────────────────────────────────────────
  describe "the listed refusals" do
    it "lists them newest first" do
      refuse(at: 3.hours.ago, reasons: ["oldest"])
      refuse(at: 1.hour.ago, reasons: ["newest"])

      expect(delivery_health["rejections"].map { |row| row["reasons"] })
        .to eq([["newest"], ["oldest"]])
    end

    it "serves the endpoint's own words, identical to what the client was handed in its 400" do
      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      refusal_response = response.parsed_body

      expect(refusal_response["details"]).to be_present
      expect(delivery_health["rejections"].first["reasons"]).to eq(refusal_response["details"])
    end

    it "reports the client that delivered it" do
      refuse(at: 1.hour.ago, user_agent: "specguard-rspec/0.3.1")

      expect(delivery_health["rejections"].first["reported_client"]).to eq("specguard-rspec/0.3.1")
    end

    # A version nobody reported must not be invented, least of all on the block whose subject is a
    # diagnosis BY client version.
    it "reports a null client rather than a placeholder when the request sent no User-Agent" do
      refuse(at: 1.hour.ago, user_agent: nil)

      expect(delivery_health["rejections"].first["reported_client"]).to be_nil
    end

    it "stamps when each refusal happened" do
      rejection = refuse(at: 1.hour.ago)

      expect(delivery_health["rejections"].first["occurred_at"]).to eq(rejection.occurred_at.iso8601)
    end

    it "bounds the list at the panel limit and says so" do
      (IngestRejection::PANEL_LIMIT + 1).times { |i| refuse(at: i.hours.ago) }

      health = delivery_health

      expect(health["rejections"].size).to eq(IngestRejection::PANEL_LIMIT)
      expect(health["rejections_window"]["bounded"]).to be(true)
    end

    # The boundary the example above cannot reach, and the one the old predicate got wrong: it read
    # `rows.size >= PANEL_LIMIT`, so a repository refused EXACTLY ten times — its complete lifetime
    # history, sitting well inside `REPOSITORY_RETENTION_ROWS` — served `bounded: true` and told an
    # agent it had not been shown everything. It had. `bounded` is a fact about the population, so
    # the two examples differ by ONE refusal and disagree.
    it "reports an unbounded window when a full page is the whole history" do
      IngestRejection::PANEL_LIMIT.times { |i| refuse(at: i.hours.ago) }

      health = delivery_health

      expect(health["rejections"].size).to eq(IngestRejection::PANEL_LIMIT)
      expect(health["rejections_window"]["bounded"]).to be(false)
    end
  end

  # ── The two truncation bounds are independent ─────────────────────────────────────────────────
  #
  # `rejections_window.bounded` counts DELIVERIES; `reasons_truncated` counts REASONS inside one. A
  # list nowhere near its window bound can still be hiding almost everything — one refusal of a
  # 20,000-example suite is a single row, and that is the case this table was designed for.
  describe "a refusal whose reason list exceeded the per-row bound" do
    let(:reason_count) { IngestRejection::RETAINED_REASONS_PER_ROW + 30 }

    before { refuse(at: 1.hour.ago, reasons: Array.new(reason_count) { |i| "spec #{i} is invalid" }) }

    it "serves the retained reasons and counts what it dropped" do
      row = delivery_health["rejections"].first

      expect(row["reasons"].size).to eq(IngestRejection::RETAINED_REASONS_PER_ROW)
      expect(row["omitted_reasons_count"]).to eq(30)
      expect(row["reasons_truncated"]).to be(true)
    end

    it "raises the window's disclosure flag while the DELIVERY bound is nowhere near reached" do
      health = delivery_health

      expect(health["rejections_window"]["any_reasons_truncated"]).to be(true)
      expect(health["rejections_window"]["bounded"]).to be(false)
    end

    it "reports no omission on a row that kept everything" do
      refuse(at: 30.minutes.ago, reasons: ["Commit SHA is required"])

      row = delivery_health["rejections"].first

      expect(row["omitted_reasons_count"]).to eq(0)
      expect(row["reasons_truncated"]).to be(false)
    end
  end

  # ── The signal this block corrects ────────────────────────────────────────────────────────────
  #
  # `authenticate_api_key!` stamps `api_keys.last_used_at` on the way IN, so a delivery that is then
  # refused for its payload moves it exactly as far as one that ingested cleanly. Left alone, it is
  # the freshest figure in the body and it affirmatively contradicts the staleness of every other
  # one. It keeps answering the only question it can answer, and now names the key that answers the
  # other.
  describe "api_key.last_used_at, which is not a health signal" do
    it "points at the block that carries the acceptance verdict" do
      expect(get_repository["api_key"]["acceptance_reported_by"]).to eq("delivery_health")
    end

    it "still moves for a delivery that was refused — which is exactly why it needs the pointer" do
      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      body = get_repository

      expect(body["api_key"]["last_used_at"]).to be_present
      expect(body["delivery_health"]["refusing"]).to be(true)
    end
  end
end
