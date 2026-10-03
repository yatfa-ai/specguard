# frozen_string_literal: true

require "rails_helper"

# The `near` block on the repository overview — `GET /api/v1/repositories/:id?near=<behavior
# phrase>` — the first surface that answers "what exists near this behavior phrase?" for a
# repository, and roadmap SPGD-1102's key work item 1 of 4.
#
# Before it, no surface could serve that question: the only similarity read was the stored
# near-duplicates census (`?near_duplicates=`), which answers "which pairs are redundant with each
# other" — a question about PAIRS — never "what is near X". The probe embeds the caller's phrase
# once through the shipped provider and shipped cache, ranks the repository's `SpecIdentity` rows
# through the single tenant-filtered ANN seam (`SpecIdentity.with_hnsw_planner_setup`, the one
# SPGD-958 built), and returns the top-10 with per-hit similarity, signal source, last-known path
# and the weight the response's own run measured.
#
# ⭐ THE READ RANKS AND DISCLOSES, AND SINCE SLICE 2 (SPGD-1548) IT HOLDS THE CENSUS'S OWN FLOOR:
# `NearDuplicateClusters::SIMILARITY` (0.85), read and never restated, applied as a Ruby
# post-filter on RAW distance. It is never `SpecIdentity::MATCH_SIMILARITY` (0.95) and the block
# never answers "is this behavior already tested?" (the owner-rejected `/check-intent` posture):
# the floor filters a ranked read and discloses itself, it issues no verdict. MCP reach is
# slice 3's; contract docs slice 4's. `NearProbe`'s class comment owns the argument.
#
# ITS OWN FILE, on the precedent `repository_near_duplicates_spec.rb` states: every example here
# needs identities whose texts bear a stated relation to a probe phrase the client supplies, which
# no other block on this endpoint wants, and needs a query parameter no other block reads.
#
# ⭐ THE PROVIDER IS LEXICAL HERE, for the same reason the census spec gives: the suite-wide stub
# makes two different strings near-orthogonal however alike they read. Under the lexical stand-in
# the probe's own text IS a stored identity's text, so the ranking has a deterministic head (the
# exact match at similarity 1.0) without this file pinning any vector it typed. The census spec's calibrated
# trio gives a deterministic ladder: the exact match at 1.0, the one-word-apart pair at 0.89 (above
# the 0.85 floor) and an unrelated text at ~0.04 (below it).
#
# ⭐ THE SEAM IS ASSERTED AS A MECHANISM, NOT AN OUTCOME, per SPGD-375's own lesson as
# `Ingest::IdentityResolver`'s spec records it: a recall assertion at test-suite table sizes is
# vacuous (the planner does not choose the HNSW index at all there), while what cannot be
# accidentally right is whether `SET LOCAL hnsw.iterative_scan` was issued on the connection for
# THIS statement. The statement's shape — distance ordering merged with the `id` tiebreak, a
# LIMIT, and NO threshold — is pinned beside it: the floor is a Ruby post-filter, and a threshold
# on the statement would change its measured shape and import `MATCH_DISTANCE` by accident.
RSpec.describe "GET /api/v1/repositories/:id — near", type: :request do
  include_context "with lexical embeddings"

  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: person, github_full_name: "acme/billing-service") }
  let(:user_api_key) { create_user_api_key(user: person) }

  # The model spec's calibrated near-duplicate pair (0.89) and an unrelated text
  # (near-orthogonal) — the census spec's own trio, reused so both files speak about the same
  # texts. The probe is the exact stored text: the deterministic head of the ranking.
  let(:expired) { "Checkout rejects an expired card" }
  let(:outright) { "Checkout rejects an expired card outright" }
  let(:shipping) { "Shipping calculates a delivery estimate" }
  let(:probe) { expired }

  let(:user_api_key_header) { { "Authorization" => "Bearer #{user_api_key.raw_token}" } }

  def get_repository(id: repository.id, token: user_api_key.raw_token, query: {})
    get "/api/v1/repositories/#{id}", params: query,
                                       headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def block(**) = get_repository(**)["near"]

  let(:ask) { { near: probe } }

  # Identities and observations both come off `Ingest::Payload`, never hand-written — the rule
  # every sibling on this endpoint states, and load-bearing here because the identity rows are
  # what the probe ranks: a hand-built fixture would pin vectors this file typed rather than the
  # ingest path's resolution. The resolver is a JOB in production — run inline here, on the
  # precedent `repository_near_duplicates_spec.rb` states.
  def record_and_resolve(repo, specs, commit_sha: "feedfacecafe0001", branch: "main")
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    run = Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
    Ingest::IdentityResolver.resolve(run)
    run
  end

  def unannotated(file_path:, line_number:, name:, id:, duration: 0.5)
    { id: id, spec_file_path: file_path, file_path: file_path, line_number: line_number,
      name: name, duration: duration, outcome: "passed", status: "unannotated", intent: nil }
  end

  # THE HEADLINE FIXTURE. One identity born of a THREE-example table-driven loop (exact
  # duplicates collapse onto one row — that is the point of asserting its weight below as
  # example_count 3) and one unrelated identity. 0.25 sums exactly in binary floating point, so
  # the wall-clock assertion below can be `eq` rather than `be_within`.
  let!(:test_run) do
    record_and_resolve(repository,
                       [unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                                    name: expired, id: "./spec/models/checkout_spec.rb[1:1]",
                                    duration: 0.25),
                        unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 4,
                                    name: expired, id: "./spec/models/checkout_spec.rb[1:2]",
                                    duration: 0.25),
                        unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 5,
                                    name: expired, id: "./spec/models/checkout_spec.rb[1:3]",
                                    duration: 0.25),
                        unannotated(file_path: "spec/services/shipping_spec.rb", line_number: 12,
                                    name: shipping, id: "./spec/services/shipping_spec.rb[2:1]",
                                    duration: 0.5)])
  end

  describe "an asking client" do
    # THE LADDER: exact match (1.0) then the calibrated one-word-apart neighbour (0.89), both above
    # the floor; the unrelated identity (~0.04) is below it and is NOT ranked. Slice 1 ranked it.
    # @intent: { entity: "near", action: "rank the repository's identities", behavior: "a probe matching a stored text answers the deterministic head with every disclosed figure carried per hit and the disclosures above them, ranking only identities at or above the floor", layer: "request" }
    it "ranks nearest first, discloses what every figure means, and drops what is below the floor" do
      neighbour_run = record_and_resolve(
        repository,
        [unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 30,
                     name: outright, id: "./spec/models/checkout_spec.rb[5:1]")],
        commit_sha: "feedfacecafe0010"
      )

      served = block(query: ask)

      expect(served["status"]).to eq("ok")
      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["similarity_basis"]).to eq(NearProbe::SIMILARITY_BASIS)
      # Under the lexical provider there is no fingerprint and no published model — the nils are
      # the disclosure, not a gap; the cache group below pins the populated spellings.
      expect(served["provider_fingerprint"]).to be_nil
      expect(served["provider_model"]).to be_nil
      expect(served["cache_served"]).to be(false)
      expect(served["weighed_run_id"]).to eq(neighbour_run.id)

      expect(served["ranked"].pluck("text")).to eq([expired, outright])
      expect(served["ranked"].pluck("similarity")).to eq([1.0, 0.89])
      # The unrelated identity is held by the denominator, not by the ranking.
      expect(served["identity_count"]).to eq(3)
      expect(served).not_to have_key("best_below_floor_similarity")
      head = served["ranked"].first
      expect(head).to include(
        "signal_source" => "name",
        "file_path" => "spec/models/checkout_spec.rb",
        "similarity" => 1.0,
        # The three-example loop collapsed onto ONE identity: the weight is the loop's, counted
        # in the run that observed it. The weighed run is the NEWEST one (the neighbour's), which
        # never saw the loop — so the head reads unobserved here; the anchor group pins weights.
        "example_count" => 0
      )
      expect(head).to have_key("text_digest")
      expect(head).to have_key("line_number")
      expect(head["id"]).to eq(repository.spec_identities.find_by(text: expired).id)
    end

    # THE WEIGHT HEADLINE, on the base fixture alone (the loop's own run is the newest).
    # @intent: { entity: "near", action: "weigh the head hit", behavior: "a collapsed three-example loop identity carries the loop's example count and wall clock measured in the response's own run", layer: "request" }
    it "weighs the collapsed loop identity in the response's run" do
      head = block(query: ask)["ranked"].first

      expect(head).to include("example_count" => 3, "total_seconds" => 0.75, "timed_count" => 3,
                              "similarity" => 1.0)
    end

    # The cap is the census's own neighbour cap, read from `NearDuplicateClusters::NEIGHBOURS`
    # rather than restated — so this assertion pins the READ, not a number this file typed: the
    # day the census's cap moves, the probe's moves with it and this example stays green.
    # @intent: { entity: "near", action: "cap the ranking", behavior: "a repository with more identities than the census neighbour cap answers at most that many ranked hits", layer: "request" }
    it "caps the ranking at the census's neighbour count" do
      texts = Array.new(NearDuplicateClusters::NEIGHBOURS + 2) do |index|
        "Behavior probe fixture #{index} verifies the invoice total for order #{index}"
      end
      record_and_resolve(repository,
                         texts.each_with_index.map do |text, index|
                           unannotated(file_path: "spec/models/growth_spec.rb",
                                       line_number: index + 20, name: text,
                                       id: "./spec/models/growth_spec.rb[3:#{index + 1}]")
                         end,
                         commit_sha: "feedfacecafe0009")

      # The growth texts sit near each other (0.88–0.92) and far from `expired`, so the ask
      # probes one of THEM: every top-10 hit is above the floor and the cap is what binds.
      served = block(query: { near: texts.first })

      expect(served["ranked"].size).to eq(NearDuplicateClusters::NEIGHBOURS)
    end

    # THE SEAM, asserted as a mechanism and not an outcome — the reasoning is
    # `Ingest::IdentityResolver`'s own example's, restated at this read: recall numbers are
    # vacuous at test-suite sizes, while the directive's presence and the statement's shape
    # cannot be accidentally right. The threshold's ABSENCE is pinned because it is this slice's
    # defining property: a threshold here would be a floor decision, and no floor was decided.
    # @intent: { entity: "near", action: "issue the ANN under the seam", behavior: "the ranking statement runs inside the seam transaction with the recall directive issued ahead of it, ordered by distance then id, capped, and carrying no distance threshold", layer: "request" }
    it "issues one unthresholded ANN statement under the seam's recall directive" do
      statements = executed_sql { get_repository(query: ask) }

      set = statements.grep(/\ASET LOCAL hnsw\.iterative_scan/i).sole
      expect(set).to match(/relaxed_order/i)
      # AMENDED DELIBERATELY (SPGD-1548), the same documented pattern as the cost example below:
      # slice 2's `identity_count` is a SECOND statement against `spec_identities`, so the loose
      # table match no longer isolates the ANN under `.sole`. The matcher tightens to the ANN's
      # own shape — an `ORDER BY` on the `<=>` distance operator. The ANN statement itself is
      # unchanged: still unthresholded, still byte-for-byte slice 1's.
      ann = statements.grep(/FROM "spec_identities".*ORDER BY.*<=>/m).sole
      # The SET is on the same connection, ahead of the statement it scopes — a directive issued
      # anywhere else would pass the line above and mean nothing.
      expect(statements.index(ann)).to be > statements.index(set)
      # `#nearest`'s shape, widened: distance ordering merged with the `id` determinism tiebreak
      # (which forces the Incremental Sort), the cap applied — and NO threshold anywhere. The
      # operator check is spelled to exclude the distance operator itself: `<=>` contains `<=`,
      # so the assertion matches the space-or-digit spelling a threshold would have to use.
      expect(ann).to match(/ORDER BY.*<=>.*,\s*"spec_identities"\."id" ASC\s*LIMIT/m)
      expect(ann).not_to match(/<=\s*[\d$]/)
    end

    # THE COST, pinned as a statement delta rather than a bare total: the response body already
    # reads several tables unconditionally, so what this block adds is exactly FOUR statements —
    # the seam's `SET LOCAL` directive, the ANN read, the weight read and (SPGD-1548) the
    # `identity_count` denominator. AMENDED DELIBERATELY from slice 1's three: the count statement
    # replaced slice 1's derive-zero-when-empty shortcut because the denominator now rides every
    # ok answer. Pinned as a delta over the same request without the ask, on the census spec's
    # warming discipline.
    # @intent: { entity: "near", action: "bound the ask's cost", behavior: "an asking request costs exactly four more statements than the same request without the ask — the seam directive, the ANN and the count against spec_identities, and one against spec_observations", layer: "request" }
    it "costs exactly four statements beyond the body's own — directive, ANN, weight, count" do
      get_repository(query: ask) # warm every cache the two requests below share

      baseline = executed_sql { get_repository }
      asked = executed_sql { get_repository(query: ask) }

      expect(asked.size - baseline.size).to eq(4)
      expect(asked.grep(/FROM "spec_identities"/).size - baseline.grep(/FROM "spec_identities"/).size)
        .to eq(2)
      expect(asked.grep(/COUNT\(\*\) FROM "spec_identities"/).size).to eq(1)
      expect(asked.grep(/FROM "spec_observations"/).size - baseline.grep(/FROM "spec_observations"/).size)
        .to eq(1)
    end
  end

  describe "the shipped embedding cache" do
    # A provider that behaves like production's does about identity — `configured?`, a
    # `fingerprint` the cache can be keyed on, a published `model` — while staying lexical,
    # in-process and free. `calls` is the embed counter: the cache's whole claim is that a
    # repeated probe buys nothing, and this is the instrument that watches it not be bought.
    let(:fingerprint_provider) do
      Class.new do
        class << self
          def calls = @calls ||= 0

          def call(text)
            @calls = calls + 1
            LexicalEmbeddingProvider.call(text)
          end

          def configured? = true

          def fingerprint = "test:near-probe"

          def model = "lexical-test-model"
        end
      end
    end

    # @intent: { entity: "near", action: "serve a repeated probe from the cache", behavior: "a novel probe is embedded exactly once and a second identical probe is served from the cache with the disclosure flipped and no second embed", layer: "request" }
    it "embeds a novel probe once and serves the repeat from the cache" do
      EmbeddingGenerator.provider = fingerprint_provider
      calls_before = fingerprint_provider.calls

      first = block(query: ask)

      expect(first["status"]).to eq("ok")
      expect(first["cache_served"]).to be(false)
      expect(first["provider_fingerprint"]).to eq("test:near-probe")
      expect(first["provider_model"]).to eq("lexical-test-model")
      expect(fingerprint_provider.calls - calls_before).to eq(1)

      second = block(query: ask)

      expect(second["cache_served"]).to be(true)
      expect(fingerprint_provider.calls - calls_before).to eq(1)
    end

    # @intent: { entity: "near", action: "bound the cache traffic", behavior: "a cache miss costs one read and one store against the cache table and a hit costs the read alone", layer: "request" }
    it "costs one cache read on a hit and read-plus-store on a miss" do
      EmbeddingGenerator.provider = fingerprint_provider

      block(query: { near: shipping }) # embeds shipping once and stores it, warming the hit below
      hit = queries_against("embedding_cache_entries") { block(query: { near: shipping }) }
      miss = queries_against("embedding_cache_entries") { block(query: { near: expired }) }

      expect(hit.size).to eq(1)
      expect(miss.size).to eq(2)
    end
  end

  describe "the three silences" do
    # A provider that reports unconfigured and would fail loudly if it were ever asked — the
    # ask must stop at the configuration check, not reach the provider.
    let(:unconfigured_provider) do
      Class.new do
        class << self
          def configured? = false

          def call(_text) = raise "the unconfigured provider must never be asked"
        end
      end
    end

    # @intent: { entity: "near", action: "disclose an unconfigured provider", behavior: "an ask under an unconfigured provider answers its own disclosed shape without embedding or ranking, and the same ask under a working provider answers ok", layer: "request" }
    it "discloses an unconfigured provider as its own answer, never as an empty ranking" do
      EmbeddingGenerator.provider = unconfigured_provider

      served = block(query: ask)

      expect(served["status"]).to eq("provider_unconfigured")
      expect(served["ranked"]).to be_nil
      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["similarity_basis"]).to eq(NearProbe::SIMILARITY_BASIS)
      expect(queries_against("spec_identities") { block(query: ask) }).to be_empty

      # THE COMPANION, inside the same example: the silence is the SHAPE's, not the suite stub's.
      # Under a working provider the identical ask answers ok — the two states are distinct
      # answers, and a client can tell them apart.
      EmbeddingGenerator.provider = LexicalEmbeddingProvider
      expect(block(query: ask)["status"]).to eq("ok")
    end

    # A provider that reports configured and then refuses: the one live failure this read can
    # produce, disclosed with the provider's own reason rather than swallowed into a list.
    let(:failing_provider) do
      Class.new do
        class << self
          def configured? = true

          def call(_text) = raise EmbeddingGenerator::Error, "HTTP 429 quota exhausted"
        end
      end
    end

    # @intent: { entity: "near", action: "disclose an embedding failure", behavior: "an ask whose probe fails to embed answers its own disclosed shape with the provider reason carried and no ranking attempted", layer: "request" }
    it "discloses an embedding failure as its own answer, with the provider's reason carried" do
      EmbeddingGenerator.provider = failing_provider

      served = block(query: ask)

      expect(served["status"]).to eq("embedding_failed")
      expect(served["error"]).to eq("HTTP 429 quota exhausted")
      expect(served["ranked"]).to be_nil
      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["similarity_basis"]).to eq(NearProbe::SIMILARITY_BASIS)
      expect(queries_against("spec_identities") { block(query: ask) }).to be_empty
    end

    # A repository that has never ingested: the search RUNS and finds nothing to rank. The
    # identity count is the finding — `ranked: []` alone would be indistinguishable from every
    # other empty, and the count states what was searched.
    # @intent: { entity: "near", action: "answer a repository with no identities", behavior: "an ask against a repository that never ingested answers an empty ranking that states the zero identity count as a finding", layer: "request" }
    it "answers an empty ranking that states the count it searched" do
      empty_repository = create_repository(user: person, github_full_name: "acme/never-ingested")
      empty_key = create_user_api_key(user: person, name: "Empty repo reader")

      served = get_repository(id: empty_repository.id, token: empty_key.raw_token,
                              query: { near: "anything at all" })["near"]

      expect(served["status"]).to eq("ok")
      expect(served["ranked"]).to eq([])
      expect(served["identity_count"]).to eq(0)
      expect(served["weighed_run_id"]).to be_nil
      expect(served).not_to have_key("best_below_floor_similarity")
      expect(served["signal_sources"]).to eq("intent" => 0, "name" => 0)
      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
    end

    # THE COMPANION that makes the two empties distinct: identities exist, none reaches the floor.
    # `ranked: []` is the same on the wire; the denominator and the nearest figure are the
    # difference, and the figure is the one the unranked hit would have displayed.
    # @intent: { entity: "near", action: "answer nothing near", behavior: "an ask whose every top-ten hit is below the floor answers an empty ranking with a positive identity count and the nearest below-floor similarity, distinguishable from a repository with no identities", layer: "request" }
    it "answers nothing-near as a finding: empty ranking, positive denominator, the nearest figure" do
      served = block(query: { near: "Invoices are emailed to the account owner monthly" })

      expect(served["status"]).to eq("ok")
      expect(served["ranked"]).to eq([])
      expect(served["identity_count"]).to eq(2)
      expect(served["identity_count"]).to be > 0
      expect(served["best_below_floor_similarity"]).to be_a(Float).and be < NearDuplicateClusters::SIMILARITY
      expect(served["signal_sources"]).to eq("intent" => 0, "name" => 0)
      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["similarity_basis"]).to eq(NearProbe::SIMILARITY_BASIS)
    end

    # Membership is RAW distance, not the displayed figure: two hits straddle the floor by 0.001
    # of distance each — both DISPLAY exactly 0.85 after the two-decimal rounding, and only the
    # one within the floor is ranked. The ANN is stubbed to serve them because no lexical text
    # lands that close to the boundary by construction.
    # @intent: { entity: "near", action: "compare the floor on raw distance", behavior: "a hit whose rounded similarity displays as exactly the floor is ranked when its raw distance is within the floor and excluded when its raw distance is beyond it", layer: "request" }
    it "compares the floor on raw distance, so rounding never flips membership" do
      raw = lambda do |distance|
        hit = Struct.new(:neighbor_distance).new(distance)
        NearProbe.new(repository, probe, nil).send(:similarity_of, hit)
      end
      # Both sides of the boundary DISPLAY the floor...
      inside = NearDuplicateClusters::DISTANCE - 0.001
      beyond = NearDuplicateClusters::DISTANCE + 0.001
      expect(raw.call(inside)).to eq(NearDuplicateClusters::SIMILARITY)
      expect(raw.call(beyond)).to eq(NearDuplicateClusters::SIMILARITY)

      # ...and membership splits them: drive the real answer with the ANN stubbed to those two.
      hits = [inside, beyond].each_with_index.map do |distance, index|
        SpecIdentity.new(id: SecureRandom.uuid, text: "boundary #{index}", text_digest: "d#{index}",
                         signal_source: "name", file_path: "x_spec.rb", line_number: index + 1)
                    .tap { |identity| identity.define_singleton_method(:neighbor_distance) { distance } }
      end
      allow_any_instance_of(NearProbe).to receive(:ranked_hits).and_return(hits)

      served = block(query: ask)

      expect(served["ranked"].pluck("text")).to eq(["boundary 0"])
      expect(served["ranked"].first["similarity"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["signal_sources"]).to eq("intent" => 0, "name" => 1)
    end

    # @intent: { entity: "near", action: "compose signal sources over the served page", behavior: "signal source composition counts the served page only, with every source present as a measured zero", layer: "request" }
    it "counts signal sources over the served page, zeros measured" do
      served = block(query: ask)

      expect(served["signal_sources"]).to eq("intent" => 0, "name" => 1)
      expect(served["signal_sources"].keys).to match_array(SpecIdentity::SOURCES)
    end
  end

  describe "the weights ride the response's run anchor" do
    # Two runs on the fixture repository: the first weighed the loop, the second did not. The
    # default ask weighs against the newest run — where the loop's identity is unobserved and
    # must read as unobserved (zeros, not a silent drop) — and naming the first run's sha
    # re-weights against it, on the same anchor every other run-grain block on this body obeys.
    let!(:first_run) do
      record_and_resolve(repository,
                         [unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                                      name: expired, id: "./spec/models/checkout_spec.rb[4:1]",
                                      duration: 0.25),
                          unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 4,
                                      name: expired, id: "./spec/models/checkout_spec.rb[4:2]",
                                      duration: 0.25),
                          unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 5,
                                      name: expired, id: "./spec/models/checkout_spec.rb[4:3]",
                                      duration: 0.25)],
                         commit_sha: "nearanchor0001")
    end

    let!(:second_run) do
      record_and_resolve(repository,
                         [unannotated(file_path: "spec/services/shipping_spec.rb",
                                      line_number: 30, name: shipping,
                                      id: "./spec/services/shipping_spec.rb[4:1]",
                                      duration: 0.75)],
                         commit_sha: "nearanchor0002")
    end

    # Each text probes ITSELF: the floor now drops what is far from the probe, so a hit is read
    # in the ask whose head it is.
    def hit_for(text, query: { near: text })
      block(query: query)["ranked"].find { |hit| hit["text"] == text }
    end

    # @intent: { entity: "near", action: "weigh hits in the newest run", behavior: "the default ask weighs each hit in the newest run, an identity that run never observed reading as unobserved zeros rather than dropping out", layer: "request" }
    it "weighs each hit in the newest run and reads an unobserved identity as zeros" do
      served = block(query: ask)

      expect(served["weighed_run_id"]).to eq(second_run.id)
      expect(hit_for(shipping)).to include(
        "example_count" => 1, "total_seconds" => 0.75, "timed_count" => 1
      )
      expect(hit_for(expired)).to include(
        "example_count" => 0, "total_seconds" => nil, "timed_count" => 0
      )
    end

    # @intent: { entity: "near", action: "re-weight against the anchored run", behavior: "a commit_sha ask weighs the probe against the run it names, the same anchor the rest of the response is read off", layer: "request" }
    it "re-weights against the run the commit_sha anchor names" do
      anchored = { commit_sha: "nearanchor0001", near: probe }
      served = block(query: anchored)

      expect(served["weighed_run_id"]).to eq(first_run.id)
      expect(hit_for(expired, query: anchored)).to include(
        "example_count" => 3, "total_seconds" => 0.75, "timed_count" => 3
      )
    end
  end

  describe "a client that does not ask" do
    # THE COST CLAIM, as a query-count criterion rather than a nicety: the opt-in ask is the wire
    # contract, and the no-ask path opens no block, reads no identity, and touches no cache row.
    # @intent: { entity: "near", action: "charge only the ask", behavior: "without the parameter the key is present but null and not one identity or cache query runs, while the same request with the ask costs more", layer: "request" }
    it "pays nothing — not one query — while the key stays present and null" do
      get_repository(query: ask) # warm every cache the no-ask request shares with the asking one

      served = get_repository

      expect(served).to have_key("near")
      expect(served["near"]).to be_nil
      expect(queries_against("spec_identities") { get_repository }).to be_empty
      expect(queries_against("embedding_cache_entries") { get_repository }).to be_empty
      expect(count_queries { get_repository })
        .to be < count_queries { get_repository(query: ask) }
    end
  end

  describe "a near parameter that is not a probe phrase" do
    # The shapes are listed ONCE, in `spec/support/shared_examples/malformed_near_param.rb`, and
    # the host below is the pairing the shared example's comment calls load-bearing: it asserts
    # the NO-ASK answer specifically — 200, key present and null, and not one identity or cache
    # statement — because a guard that swallowed every value would also answer 200 on all of
    # them. The positive path directly above is what separates the two.
    def expect_near_param_treated_as_no_ask(query)
      get_repository(query: query)

      expect(response).to have_http_status(:ok)
      served = response.parsed_body
      expect(served).to have_key("near")
      expect(served["near"]).to be_nil
      expect(queries_against("spec_identities") { get_repository(query: query) }).to be_empty
      expect(queries_against("embedding_cache_entries") { get_repository(query: query) })
        .to be_empty
    end

    it_behaves_like "a surface that treats a malformed near parameter as no ask"

    # The blank String is a shape only this parameter's family reaches — the flag siblings have
    # no blank/value distinction to draw — so it is pinned here rather than in the shared list:
    # a browser's unfilled form field is not an ask, on the same rule every value-carrying
    # free-text sibling states.
    # @intent: { entity: "RequestedNearParam", action: "treat a blank probe as no ask", behavior: "a blank near parameter answers 200 with the no-ask body and embeds nothing, matching an absent parameter", layer: "request" }
    it "answers the no-ask body when near is blank" do
      expect_near_param_treated_as_no_ask({ near: "" })
    end
  end
end
