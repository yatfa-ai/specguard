# frozen_string_literal: true

require "rails_helper"

# The `near_duplicates` block on `GET /api/v1/repository` — the machine surface for
# `NearDuplicateClusters`, the suite-wide duplicate census. Since SPGD-1474 the census is computed
# once per write that moves its inputs — `Ingest::IdentityResolutionJob` requests the refresh once
# identities are settled, `RunsController#destroy` requests one when a deleted run moved the
# weighed run, and `Ingest::NearDuplicateCensusJob` computes and stores it — and this endpoint serves
# the STORED artifact: the minutes-scale computation that used to run live behind the ask is off
# the request path entirely (the agent bridge's thirty-second deadline could never hold it), and
# the opt-in `?near_duplicates=` ask stays as the wire contract.
#
# ITS OWN FILE, on the precedent `repository_unannotated_examples_spec.rb` states: every example
# here needs identities whose texts read ALIKE, which no other spec on this endpoint wants, and
# needs them under a query parameter no other block reads — while every block in
# `repository_latest_run_spec.rb` is a fact about one run served on every request.
#
# ⭐ THE PROVIDER IS LEXICAL HERE, for the same reason `near_duplicate_clusters_spec.rb` gives: the
# suite-wide stub (`DeterministicEmbeddingGenerator`) makes two different strings near-orthogonal
# however alike they read, so every clustering assertion in this file would pass or fail for
# reasons that have nothing to do with the threshold. `include_context "with lexical embeddings"`
# installs the lexical stand-in, and the texts below are the model spec's own calibrated pair —
# `Checkout rejects an expired card` / `... outright` at cosine 0.89, inside the band that must
# resolve to TWO identities while still clustering. The floor itself is UNCALIBRATED for the
# shipped VoyageProvider and this file pins LOGIC, not the floor's correctness — exactly the
# discipline the model spec's own header establishes.
#
# ⭐ THE CENSUS COMPUTE RUNS INLINE IN THE FIXTURE, and no longer on the wire. The SPGD-922
# failure-evidence collector (`NearDuplicateFailureEvidence`) is therefore GONE from this file:
# it existed to capture the plan of the pair read SERVED BY THE REQUEST, and no request serves
# that read any more — a stored-census ask costs one row read and cannot flake on HNSW. The pair
# read now runs where the compute runs — the inline census call below and
# `near_duplicate_clusters_spec.rb`, the model spec the collector's incidents were about all
# along.
RSpec.describe "GET /api/v1/repository — near_duplicates", type: :request do
  include_context "with lexical embeddings"
  include ActiveSupport::Testing::TimeHelpers

  # The model spec's calibrated near-duplicate pair (0.89) and an unrelated text (near-orthogonal).
  let(:expired) { "Checkout rejects an expired card" }
  let(:outright) { "Checkout rejects an expired card outright" }
  let(:shipping) { "Shipping calculates a delivery estimate" }

  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def block(**) = get_repository(**)["near_duplicates"]

  let(:ask) { { near_duplicates: "true" } }

  # Rows and identities both come off `Ingest::Payload`, never hand-written — the rule every
  # sibling on this endpoint states, and load-bearing here twice over: the identity rows are what
  # the census clusters over, so a fixture that had built them by hand would be pinning vectors
  # this file typed rather than the ingest path's resolution.
  def record_and_resolve(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }.merge(attrs.deep_stringify_keys)
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    run = Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
    # The resolver is a JOB in production — `202` and out of band. Run it inline here, on the
    # precedent `repository_slowest_tests_spec.rb` states: every state this block turns on must be
    # one the real pipeline produces, and the identities are the census's whole substrate.
    Ingest::IdentityResolver.resolve(run)
    run
  end

  # The full production shape: the resolution job's own last act is to REQUEST the census refresh
  # (`NearDuplicateCensus.request_refresh!`), and `Ingest::NearDuplicateCensusJob` honours it. Run
  # both halves inline here — the request through the model seam it really goes through, the
  # compute through the job that really runs it — so every served block below is one the real
  # pipeline would have stored.
  def ingest(repo, specs, **attrs)
    run = record_and_resolve(repo, specs, **attrs)
    NearDuplicateCensus.request_refresh!(repo.id)
    Ingest::NearDuplicateCensusJob.perform_now(repo.id)
    run
  end

  # The mid-recompute state, and the reason the freshness examples exist: the marker is RAISED
  # (the resolution job ran and requested the refresh) but the census job has not honoured it yet.
  # A request arriving here serves the PREVIOUS stored census with its stamp — never a live
  # computation, never the new data half-mixed in.
  def ingest_awaiting_census(repo, specs, **attrs)
    run = record_and_resolve(repo, specs, **attrs)
    NearDuplicateCensus.request_refresh!(repo.id)
    run
  end

  def unannotated(file_path:, line_number:, name:, id:, duration: 0.5)
    { id: id, spec_file_path: file_path, file_path: file_path, line_number: line_number,
      name: name, duration: duration, outcome: "passed", status: "unannotated", intent: nil }
  end

  # THE HEADLINE FIXTURE. One near-duplicate pair — two identities, 0.89 apart — where one member
  # is a THREE-EXAMPLE TABLE-DRIVEN LOOP: three rows with the same name, three distinct ids,
  # resolving onto ONE identity. That is SPGD-369's own headline property (exact duplicates
  # collapse onto one row, so the census must count EXAMPLES through the join, not identity rows)
  # and this file's job is to prove it survives serialization — and, since SPGD-1474, storage and
  # a wire serve that reads the stored bytes back.
  let!(:test_run) do
    ingest(repository,
           [unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                        name: expired, id: "./spec/models/checkout_spec.rb[1:1]", duration: 0.2),
            unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 4,
                        name: expired, id: "./spec/models/checkout_spec.rb[1:2]", duration: 0.2),
            unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 5,
                        name: expired, id: "./spec/models/checkout_spec.rb[1:3]", duration: 0.2),
            unannotated(file_path: "spec/models/checkout_spec.rb", line_number: 9,
                        name: outright, id: "./spec/models/checkout_spec.rb[2:1]", duration: 0.4),
            unannotated(file_path: "spec/services/shipping_spec.rb", line_number: 12,
                        name: shipping, id: "./spec/services/shipping_spec.rb[1:1]",
                        duration: 1.0)])
  end

  describe "a repository whose near duplicates were asked about" do
    # @intent: { entity: "near_duplicates", action: "serve a cluster", behavior: "the one cluster serves two members but four examples through the table-driven loop shared identity, with summed wall clock and per-member example counts intact at the wire", layer: "request" }
    it "serves the cluster with its member count, example count and summed wall clock" do
      served = block(query: ask)

      expect(served["cluster_count"]).to eq(1)
      cluster = served["clusters"].sole
      # The pair is TWO members and FOUR examples — one member is the three-example loop, and the
      # figure a naive serializer counting identity rows would flatten is exactly this one.
      expect(cluster["member_count"]).to eq(2)
      expect(cluster["example_count"]).to eq(4)
      expect(cluster["total_seconds"]).to eq(1.0)
      expect(cluster["timed_count"]).to eq(4)
      expect(cluster["signal_source"]).to eq("name")
      # The three examples the loop contributes, served through the endpoint rather than collapsed.
      expired_member = cluster["members"].find { it["text"] == expired }
      expect(expired_member["example_count"]).to eq(3)
      expect(expired_member["total_seconds"]).to be_within(0.0001).of(0.6)
      expect(cluster["similarity_range"]).to eq([0.89, 0.89])
    end

    # @intent: { entity: "near_duplicates", action: "pin the key set", behavior: "the block serves only machine fields at every level - floor and basis first as the disclosure contract states, the stored figures in the written order, the two stamps appended last - and no prose label such as a duration or coverage sentence appears anywhere in the JSON", layer: "request" }
    it "serves exactly the keys this contract pins, and never the object's prose" do
      served = block(query: ask)

      # ORDER, not just membership: the payload column is `json` precisely so the written order
      # survives storage — `similarity_floor` and `similarity_basis` sit FIRST, ahead of every
      # figure they qualify, and the two stamps merge at the end. A jsonb column would have
      # normalized all of this away, which is exactly why it is not one; this pin is what keeps
      # the column choice honest.
      expect(served.keys)
        .to eq(["similarity_floor", "similarity_basis", "cluster_count", "truncated",
                "saturated_identity_count", "unresolved_count", "recorded_count",
                "identity_count", "clustered_identity_count", "clustered_timed_count",
                "clustered_example_count", "clusters", "weighed_run_id", "computed_at"])
      expect(served["clusters"].sole.keys)
        .to eq(["signal_source", "member_count", "example_count", "total_seconds",
                "timed_count", "similarity_range", "unobserved_members", "members"])
      expect(served["clusters"].sole["members"].first.keys)
        .to eq(["text", "file_path", "line_number", "example_count", "total_seconds"])
      # `duration_label`, `coverage_label` and `identity_coverage_label` are each one call away on
      # the object and none is served: human sentences a machine client cannot act on.
      expect(served.to_json).not_to match(/\d\.\d+s|not reported|of \d/)
      expect(served["weighed_run_id"]).to eq(test_run.id)
    end

    # THE STAMP IS THE FRESHNESS CONTRACT AT THE WIRE. `weighed_run_id` names the run every weight
    # figure was measured in — the one the stored artifact was computed against — and
    # `computed_at` dates the artifact, so a consumer can tell a fresh census from a stale one
    # instead of trusting either. Both come off the STORED ROW, not a per-request computation.
    # @intent: { entity: "near_duplicates", action: "stamp the stored census", behavior: "the served block states computed_at as iso8601 and weighed_run_id from the stored row, so a served census is always dated and never unstamped", layer: "request" }
    it "serves the stored census with its freshness stamp" do
      served = block(query: ask)
      stored = NearDuplicateCensus.find_by!(repository_id: repository.id)

      expect(stored.payload).to be_present
      expect(served["computed_at"]).to eq(stored.computed_at.iso8601)
      expect(Time.zone.parse(served["computed_at"])).to be_present
      expect(served["weighed_run_id"]).to eq(stored.weighed_run_id).and eq(test_run.id)
    end

    # THE STORED ARTIFACT IS WHAT SERVES — the same bytes on every read until the next write that
    # moves the census's inputs (an ingest, or a run deletion) recomputes them, and exactly what
    # the stored row holds. This is the serving half of the stored-equals-live property: between
    # those writes the endpoint cannot drift from the artifact.
    # @intent: { entity: "near_duplicates", action: "serve the stored bytes", behavior: "two reads with nothing ingested between them return the identical block, equal to the stored payload with its stamps merged", layer: "request" }
    it "serves the stored artifact verbatim, byte-identical between reads" do
      first = block(query: ask)

      expect(block(query: ask)).to eq(first)
      expect(first).to eq(NearDuplicateCensus.stored_block_for(repository))
    end

    # ⭐ THE DISCLOSURE RIDES THE COUNT, frozen into the stored payload from the object's own
    # constants — and pinned against the CONSTANTS, never literals, on the discipline SPGD-717
    # established next door: a literal here is a stale claim waiting to happen, and when the
    # threshold is re-derived for the shipped provider the NEXT INGEST stores the new figure and
    # the endpoint reports it without being touched.
    # @intent: { entity: "near_duplicates", action: "disclose the similarity floor", behavior: "similarity_floor and similarity_basis ride the stored payload sourced from the object own constants, so a re-derived threshold is reported at the next ingest without the endpoint being touched", layer: "request" }
    it "cannot serve a cluster count without the statement of what the similarity means" do
      served = block(query: ask)

      expect(served["similarity_floor"]).to eq(NearDuplicateClusters::SIMILARITY)
      expect(served["similarity_basis"]).to eq(NearDuplicateClusters::SIMILARITY_BASIS)
    end

    # @intent: { entity: "near_duplicates", action: "report populations", behavior: "recorded, identity, clustered and timed counts plus truncated false let an empty ranking be read as a finding about a known population rather than a silence", layer: "request" }
    it "reports the population figures that make an empty ranking a finding rather than a silence" do
      served = block(query: ask)

      expect(served["recorded_count"]).to eq(5)
      expect(served["unresolved_count"]).to eq(0)
      expect(served["identity_count"]).to eq(3)
      expect(served["clustered_identity_count"]).to eq(2)
      expect(served["clustered_example_count"]).to eq(4)
      expect(served["clustered_timed_count"]).to eq(4)
      expect(served["truncated"]).to be(false)
      expect(served["saturated_identity_count"]).to eq(0)
    end

    # THE FRESHNESS WINDOW, at the wire. A second ingest lands and the stored census is stale, but
    # its recompute has not run yet (the resolution job raised the marker; the census job has not
    # honoured it). The request serves the PREVIOUS stored census with ITS OWN stamp — never a
    # live computation over the newer data, never a half-mixed answer. Only the recompute moves
    # the block.
    # @intent: { entity: "near_duplicates", action: "serve the previous census mid-recompute", behavior: "a request between a completed ingest and the finished recompute serves the previous stored census with its own computed_at and weighed_run_id, and only the recompute moves the block", layer: "request" }
    it "serves the previous stored census, with its stamp, while a recompute is pending" do
      before = block(query: ask)
      expect(before["cluster_count"]).to eq(1)

      # A SECOND, DISJOINT near-duplicate pair, on a NEW run — enough to add a cluster the
      # recomputed census will hold that the stored one does not. (The first pair's texts again
      # would join the EXISTING cluster and change nothing the count can see.) The vocabulary is
      # disjoint from cluster 1's, because the provider is lexical: a pair that shared its words
      # with the checkout pair would merge into one five-member cluster and pin nothing.
      ingest_awaiting_census(repository,
                             [unannotated(file_path: "spec/models/inventory_spec.rb", line_number: 3,
                                          name: "Inventory decrements a stocked item",
                                          id: "./spec/models/inventory_spec.rb[1:1]", duration: 2.0),
                              unannotated(file_path: "spec/models/inventory_spec.rb", line_number: 9,
                                          name: "Inventory decrements a stocked item outright",
                                          id: "./spec/models/inventory_spec.rb[2:1]", duration: 3.0)],
                             commit_sha: "feedfacecafe0002")

      during = block(query: ask)
      expect(during).to eq(before)
      expect(during["computed_at"]).to eq(before["computed_at"])
      expect(during["weighed_run_id"]).to eq(test_run.id)

      # And only the recompute moves it — to the second run as the weighed run, stamped with when
      # THAT artifact was taken. The clock is advanced for the recompute so the second stamp is
      # strictly later than the first at iso8601's one-second grain: two computes in the same
      # spec-second would date differently only in sub-second digits the block does not carry.
      travel_to(1.minute.from_now) do
        Ingest::NearDuplicateCensusJob.perform_now(repository.id)
      end

      after = block(query: ask)
      expect(after["cluster_count"]).to eq(2)
      expect(after["weighed_run_id"]).not_to eq(test_run.id)
      expect(Time.zone.parse(after["computed_at"]))
        .to be > Time.zone.parse(before["computed_at"])
    end

    # THE COST, pinned as a query-count criterion rather than a nicety: the computation is off the
    # request path entirely, so the ask reads one stored row and never touches the clustering's
    # own tables. This is the assertion SPGD-1474 inverted — the ask used to be the only query
    # against `spec_identities` on this endpoint; now it is the one read that has none.
    # @intent: { entity: "near_duplicates", action: "serve stored without recomputing", behavior: "an asking request reads the census row and issues zero queries against spec_identities, because the computation runs at ingest and never on the request path", layer: "request" }
    it "reads the stored census and never re-runs it — not one query against the clustering's tables" do
      get_repository(query: ask) # warm every cache the two requests below share

      expect(queries_against("spec_identities") { get_repository(query: ask) }).to be_empty
      expect(queries_against("near_duplicate_censuses") { get_repository(query: ask) }).to be_present
    end
  end

  # THE COST CLAIM, as a query-count criterion rather than a nicety: the opt-in ask is the wire
  # contract, and the no-ask path opens no block and reads no census row.
  describe "a client that does not ask" do
    # @intent: { entity: "near_duplicates", action: "charge only the ask", behavior: "without the parameter the key is present but null and not one query runs, while the same request with the ask costs more", layer: "request" }
    it "pays nothing — not one query — while the key stays present and null" do
      # Warm every cache the no-ask request shares with the asking one, so the comparison below
      # measures the block and not a first-touch column load.
      get_repository(query: ask)

      served = get_repository

      expect(served).to have_key("near_duplicates")
      expect(served["near_duplicates"]).to be_nil
      # ZERO queries against the census's own tables on either path — the no-ask path reads
      # nothing and the ask reads the stored row — and the ask is still the more expensive
      # request, by exactly the block it opens.
      expect(queries_against("spec_identities") { get_repository }).to be_empty
      expect(queries_against("spec_identities") { get_repository(query: ask) }).to be_empty
      expect(count_queries { get_repository })
        .to be < count_queries { get_repository(query: ask) }
    end
  end

  # A repository with NO STORED CENSUS YET — never ingested, or read after this table shipped and
  # before its backfill landed. The ask is served `null`: not a live computation, not zeros. Zeros
  # would render "not computed yet" as "computed, and nothing reads alike", which is exactly the
  # *Vacuous Green* failure a stamped stored artifact exists to prevent — a repository whose every
  # test reads differently is a DIFFERENT state, stored and stamped, pinned below.
  describe "a repository whose census has never been computed" do
    # @intent: { entity: "near_duplicates", action: "serve null before the first compute", behavior: "an ask on a repository with no stored census serves null — never a live computation and never zeros — while the first computation stores the honest empty ranking as a stamped row", layer: "request" }
    it "serves null on the ask until the first computation stores the artifact" do
      bare = separate_repository("acme/never-ingested")

      expect(block(key: bare.api_keys.create!, query: ask)).to be_nil

      # The first computation — which for a never-ingested repository happens when one eventually
      # ingests, and which the deploy-time backfill runs for every repository with data — stores
      # the all-zero census as a real, stamped artifact: the never-ingested silence, served with a
      # date on it rather than collapsed into the ask's null.
      NearDuplicateCensus.request_refresh!(bare.id)
      Ingest::NearDuplicateCensusJob.perform_now(bare.id)

      served = block(key: bare.api_keys.create!, query: ask)
      expect(served).to include("weighed_run_id" => nil, "cluster_count" => 0,
                                "recorded_count" => 0, "identity_count" => 0,
                                "clusters" => [])
      expect(served["computed_at"]).to be_present
    end

    # THE THREE SILENCES STAY DISTINGUISHABLE AT THE WIRE. "Nothing ingested" and "nothing
    # embedded" are stored, stamped censuses with zero populations — real computations over real
    # (empty) inputs — while "nothing reads alike" carries a live population behind the same empty
    # list. A stored `null` above is the only state that says "no census exists", and these two
    # rows are what say it must never be read as.
    # @intent: { entity: "near_duplicates", action: "distinguish two silences", behavior: "a computed never-ingested census serves zero populations with a stamp while an all-unique suite reaches the same empty list with a live population behind it", layer: "request" }
    it "keeps a computed nothing-ingested census distinguishable from an all-unique suite" do
      unique = separate_repository("acme/all-unique")
      ingest(unique, [unannotated(file_path: "spec/models/only_spec.rb", line_number: 3,
                                  name: shipping, duration: 0.1,
                                  id: "./spec/models/only_spec.rb[1:1]")])
      served = block(key: unique.api_keys.create!, query: ask)

      expect(served).to include("cluster_count" => 0, "recorded_count" => 1,
                                "identity_count" => 1, "clusters" => [])
      expect(served["computed_at"]).to be_present
    end
  end

  # The shapes a query string can legally parse into that are NOT a String, pinned once for every
  # surface in `spec/support/shared_examples/malformed_near_duplicates_param.rb`. The hazard is
  # the silent extra answer: every shape is TRUTHY, so an unguarded guard would open the block on
  # a query string nobody meant to send. The block is a stored-row read since SPGD-1474 rather
  # than the minutes-scale census it guarded at birth — the guard stays, because the answer to a
  # shape the client did not mean to send is the same no-answer it has always been.
  describe "a near-duplicates parameter that is not a string" do
    def expect_near_duplicates_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed near-duplicates parameter as no ask"

    # THE positive path, beside the group: this parameter's "malformed" answer and its "absent"
    # answer are the same `null`, so nothing inside the shared group can tell a working guard from
    # an endpoint that ignores the parameter entirely.
    # @intent: { entity: "near_duplicates", action: "honour a string parameter", behavior: "a string-valued parameter serves the stored census and returns cluster_count one, the positive control beside the shared malformed-parameter group", layer: "request" }
    it "honours a near_duplicates that IS a string" do
      expect(block(query: ask)["cluster_count"]).to eq(1)
    end

    # @intent: { entity: "near_duplicates", action: "treat empty as no ask", behavior: "an empty near_duplicates value is treated as no ask and the block stays null with a 200 response", layer: "request" }
    it "treats an empty near_duplicates as no ask" do
      expect(block(query: { near_duplicates: "" })).to be_nil
    end
  end

  def separate_repository(full_name)
    uid = (@separate_uid = (@separate_uid || 1001) + 1).to_s

    create_repository(user: create_user(github_uid: uid, github_handle: "octo-#{uid}"),
                      github_full_name: full_name)
  end
end
