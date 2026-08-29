# frozen_string_literal: true

require "rails_helper"

# The `near_duplicates` block on `GET /api/v1/repository` — the machine surface for
# `NearDuplicateClusters`, the suite-wide duplicate census, served behind the opt-in
# `?near_duplicates=` ask so a client that never names it pays not one query for it.
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
RSpec.describe "GET /api/v1/repository — near_duplicates", type: :request do
  include_context "with lexical embeddings"

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
  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
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

  def unannotated(file_path:, line_number:, name:, id:, duration: 0.5)
    { id: id, spec_file_path: file_path, file_path: file_path, line_number: line_number,
      name: name, duration: duration, outcome: "passed", status: "unannotated", intent: nil }
  end

  # THE HEADLINE FIXTURE. One near-duplicate pair — two identities, 0.89 apart — where one member
  # is a THREE-EXAMPLE TABLE-DRIVEN LOOP: three rows with the same name, three distinct ids,
  # resolving onto ONE identity. That is SPGD-369's own headline property (exact duplicates
  # collapse onto one row, so the census must count EXAMPLES through the join, not identity rows)
  # and this file's job is to prove it survives serialization.
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

    # @intent: { entity: "near_duplicates", action: "pin the key set", behavior: "the block serves only machine fields at every level - floor, basis, run id, counts and rows - and no prose label such as a duration or coverage sentence appears anywhere in the JSON", layer: "request" }
    it "serves exactly the keys this contract pins, and never the object's prose" do
      served = block(query: ask)

      expect(served.keys)
        .to contain_exactly("similarity_floor", "similarity_basis", "weighed_run_id",
                            "cluster_count", "truncated", "saturated_identity_count",
                            "unresolved_count", "recorded_count", "identity_count",
                            "clustered_identity_count", "clustered_timed_count",
                            "clustered_example_count", "clusters")
      expect(served["clusters"].sole.keys)
        .to contain_exactly("signal_source", "member_count", "example_count", "total_seconds",
                            "timed_count", "similarity_range", "unobserved_members", "members")
      expect(served["clusters"].sole["members"].first.keys)
        .to contain_exactly("text", "file_path", "line_number", "example_count", "total_seconds")
      # `duration_label`, `coverage_label` and `identity_coverage_label` are each one call away on
      # the object and none is served: human sentences a machine client cannot act on.
      expect(served.to_json).not_to match(/\d\.\d+s|not reported|of \d/)
      expect(served["weighed_run_id"]).to eq(test_run.id)
    end

    # ⭐ THE DISCLOSURE RIDES THE COUNT, sourced from the object rather than restated — and pinned
    # against the CONSTANTS, never literals, on the discipline SPGD-717 established next door: a
    # literal here is a stale claim waiting to happen, and when the threshold is re-derived for the
    # shipped provider the endpoint must report the new figure without being touched.
    # @intent: { entity: "near_duplicates", action: "disclose the similarity floor", behavior: "similarity_floor and similarity_basis ride the payload sourced from the object own constants, so a re-derived threshold is reported without the endpoint being touched", layer: "request" }
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

    # @intent: { entity: "near_duplicates", action: "disclose truncation", behavior: "one more cluster than the ranking limit is served as a capped list with the true cluster_count and truncated true, so the page cannot pass itself off as the census", layer: "request" }
    it "discloses a truncated ranking rather than passing the page off as the census" do
      many = separate_repository("acme/many-pairs")
      # Two more near-duplicate pairs than the ranking's limit, so the cluster list is capped while
      # the count is not — the state a page-counting serializer hides. Each pair's vocabulary is
      # DISJOINT from every other pair's, because the provider is lexical: eleven pairs that
      # shared their words would merge into ONE eleven-member cluster and pin nothing about the
      # cap. Each pair is six synthetic tokens built off its own index — five shared, one appended
      # by the partner — which MEASURES within-pair at 0.878–0.941 (above the floor) and
      # cross-pair at ≤ 0.33 under `LexicalEmbeddingProvider`, so eleven real pairs cluster
      # separately rather than collapsing into one.
      (NearDuplicateClusters::LIMIT + 1).times do |index|
        words = %W[z#{index}qx v#{index}wb t#{index}kn r#{index}pm s#{index}dg u#{index}hj]
        ingest(many,
               [unannotated(file_path: "spec/models/pair_#{index}_spec.rb", line_number: 3,
                            name: words.take(5).join(" "), duration: 0.1,
                            id: "./spec/models/pair_#{index}_spec.rb[1:1]"),
                unannotated(file_path: "spec/models/pair_#{index}_spec.rb", line_number: 9,
                            name: words.join(" "), duration: 0.1,
                            id: "./spec/models/pair_#{index}_spec.rb[2:1]")],
               commit_sha: format("pairfeed%06x", index))
      end
      served = block(key: many.api_keys.create!, query: ask)

      expect(served["clusters"].length).to eq(NearDuplicateClusters::LIMIT)
      expect(served["cluster_count"]).to eq(NearDuplicateClusters::LIMIT + 1)
      expect(served["truncated"]).to be(true)
      expect(served["clustered_identity_count"]).to eq(2 * (NearDuplicateClusters::LIMIT + 1))
    end

    # THE THREE SILENCES STAY DISTINGUISHABLE AT THE WIRE. This is the never-ingested one: no run
    # to weigh against, which is a fact about the repository's history — `weighed_run_id` is null
    # and the population figures are zero, and the block serves rather than raises because `nil`
    # is the object's own documented `UNRUN` path.
    # @intent: { entity: "near_duplicates", action: "distinguish two silences", behavior: "a never-ingested repository serves null weighed_run_id with zero populations while an all-unique suite reaches the same empty list with a live population behind it", layer: "request" }
    it "serves the block for a repository that never ingested, distinguishably from an all-unique suite" do
      bare = separate_repository("acme/never-ingested")
      served = block(key: bare.api_keys.create!, query: ask)

      expect(served).to include("weighed_run_id" => nil, "cluster_count" => 0,
                                "recorded_count" => 0, "identity_count" => 0,
                                "clusters" => [])
      # And a suite whose every test is unique reaches the same empty list with a POPULATION
      # behind it — the discriminator the two silences need and a bare `[]` would spend.
      unique = separate_repository("acme/all-unique")
      ingest(unique, [unannotated(file_path: "spec/models/only_spec.rb", line_number: 3,
                                  name: shipping, duration: 0.1,
                                  id: "./spec/models/only_spec.rb[1:1]")])
      served = block(key: unique.api_keys.create!, query: ask)

      expect(served).to include("cluster_count" => 0, "recorded_count" => 1,
                                "identity_count" => 1, "clusters" => [])
    end
  end

  # THE COST CLAIM, as a query-count criterion rather than a nicety: the census is the one read on
  # this endpoint measured in seconds, and the opt-in ask is the entire design that confines it.
  describe "a client that does not ask" do
    # @intent: { entity: "near_duplicates", action: "charge only the ask", behavior: "without the parameter the key is present but null and not one query touches spec_identities, while the same capture with the ask is non-empty", layer: "request" }
    it "pays nothing — not one query — while the key stays present and null" do
      # Warm every cache the no-ask request shares with the asking one, so the comparison below
      # measures the census and not a first-touch column load.
      get_repository(query: ask)

      served = get_repository

      expect(served).to have_key("near_duplicates")
      expect(served["near_duplicates"]).to be_nil
      # ZERO queries against the census's own tables, and the census itself is what proves the
      # guard is doing work rather than a fixture that could never ask: the same capture with the
      # ask is non-empty.
      expect(queries_against("spec_identities") { get_repository }).to be_empty
      expect(queries_against("spec_identities") { get_repository(query: ask) }).to be_present
      expect(count_queries { get_repository })
        .to be < count_queries { get_repository(query: ask) }
    end
  end

  # The shapes a query string can legally parse into that are NOT a String, pinned once for every
  # surface in `spec/support/shared_examples/malformed_near_duplicates_param.rb`. The hazard is
  # the sibling flag's at this endpoint's measured cost: every shape is TRUTHY, so an unguarded
  # guard would run the whole census on a query string nobody meant to send.
  describe "a near-duplicates parameter that is not a string" do
    def expect_near_duplicates_param_treated_as_no_ask(query)
      expect(block(query: query)).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed near-duplicates parameter as no ask"

    # THE positive path, beside the group: this parameter's "malformed" answer and its "absent"
    # answer are the same `null`, so nothing inside the shared group can tell a working guard from
    # an endpoint that ignores the parameter entirely.
    # @intent: { entity: "near_duplicates", action: "honour a string parameter", behavior: "a string-valued parameter runs the census and returns cluster_count one, the positive control beside the shared malformed-parameter group", layer: "request" }
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
