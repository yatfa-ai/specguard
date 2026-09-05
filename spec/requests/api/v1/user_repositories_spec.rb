# frozen_string_literal: true

require "rails_helper"

# SPGD-752 success criterion 2: a `sgu_` user key authenticates `GET /api/v1/repositories`, and the
# body lists exactly `Repository.accessible_by(user)`.
RSpec.describe "API v1 — GET /api/v1/repositories", type: :request do
  # The fixture the criterion names, and each third of it is load-bearing: OWNED and MEMBER are the
  # two halves of `accessible_by`'s union — a response built from either alone passes half the suite
  # — and INVISIBLE is the one that proves the list is not simply `Repository.all`.
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:stranger) { create_user(github_uid: "2002", github_handle: "hubot") }

  let!(:owned) { create_repository(user: person, github_full_name: "acme/billing-service") }
  let!(:shared) do
    create_repository(user: stranger, github_full_name: "acme/ledger").tap do |repository|
      create_membership(repository: repository, user: person)
    end
  end
  let!(:invisible) { create_repository(user: stranger, github_full_name: "acme/secret-payroll") }

  let(:user_api_key) { create_user_api_key(user: person) }

  # `params:` carries the narrowing asks (`?q=`, `?role=`, `?sort=stale`); the default is the
  # unparameterised request every earlier example pins.
  def get_repositories(token: user_api_key.raw_token, params: {})
    get "/api/v1/repositories", params: params, headers: { "Authorization" => "Bearer #{token}" }
  end

  # Built the way `spec/requests/repositories_spec.rb` builds one, and for the reason stated
  # there: the production path stamps `api_keys.last_used_at` on the way IN, so a refused delivery
  # records a use. Nothing on this surface reads that column — the block compares one refusal's
  # `occurred_at` against one run's `created_at`, and both sides are stated here — so the shortcut
  # is faithful rather than merely convenient.
  #
  # At THIS file's top level rather than inside one describe block, because two blocks reach for
  # it: `delivery_health` for the verdict examples, and `latest_run` for the never-ingested
  # contrast — a null `latest_run` beside a refusing `delivery_health` is the pair that tells "CI
  # stopped reporting" apart from "SpecGuard is throwing everything away". RSpec scopes a `def` to
  # its own example group; the note on `sharded_run` below says the same thing.
  def refuse(repository, at: Time.current)
    IngestRejection.create!(repository: repository, occurred_at: at,
                            details: ["commit_sha can't be blank"], total_reasons_count: 1)
  end

  # The canonical 4-shard composition the shard blocks across this codebase are written against —
  # `repository_latest_run_spec.rb` builds the same four numbers. 61.0 + 58.5 + 74.25 + 60.0 are a
  # 74.25s wall clock and 253.75s of machine time, and the 3.4x gap between the two figures is
  # the distinction `machine_seconds` exists to carry: a reader handed only the MAX understates
  # the suite's cost on exactly the runs a cost ranking exists to compare.
  #
  # Defined at THIS file's top level because two describe blocks below reach for it — the
  # `latest_run` block for the SUM-not-MAX example, and the query-budget example inside
  # `delivery_health` for a fixture whose shard aggregate has real rows to count — and RSpec
  # scopes a `def` to its own example group, which this file has already been bitten by once.
  #
  # `durations:` with nils is the untimed-seam case — a shard that reported no timing is an
  # ordinary state (`Ingest::Payload` accepts a nil duration explicitly) and the SUM over zero
  # reported timings is `null`, never a measured `0.0`.
  # `branch: "main"` rather than the column's nil default, so every comparison made against this
  # run compares REAL values — the parity example below iterates the list block's keys against the
  # detail route's, and a nil-branch fixture would let a key renamed on one side pass as
  # `nil == nil`, the exact drift that example exists to catch.
  #
  # `durations:` with nils is the untimed-seam case — a shard that reported no timing is an
  # ordinary state (`Ingest::Payload` accepts a nil duration explicitly) and the SUM over zero
  # reported timings is `null`, never a measured `0.0`.
  def sharded_run(repository, durations: [61.0, 58.5, 74.25, 60.0], commit_sha: "shards00000000")
    run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                       branch: "main",
                                       total_specs_count: 20_000, annotated_specs_count: 5_000,
                                       duration_seconds: durations.compact.max)
    durations.each_with_index do |seconds, index|
      run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5_000,
                                  annotated_specs_count: 1_250, duration_seconds: seconds)
    end
    run
  end

  # @intent: { entity: "repository list", action: "list accessible rows", behavior: "the body lists the owned and the shared repository by full name and nothing else the fixture holds", layer: "request" }
  it "lists the repository the person owns and the one shared with them" do
    get_repositories

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"].map { |row| row["full_name"] })
      .to eq(["acme/billing-service", "acme/ledger"])
  end

  # The half of the criterion that is about what is NOT there. Asserted against the whole serialized
  # body rather than against the name list alone, so a repository leaking through any other field —
  # an id, a `name` — is caught too.
  # @intent: { entity: "repository list", action: "withhold the invisible", behavior: "a repository the person can neither open nor learn exists appears nowhere in the serialized body - not by name and not by id", layer: "request" }
  it "does not disclose a repository the person can neither open nor learn exists" do
    get_repositories

    expect(Repository.exists?(invisible.id)).to be(true)
    expect(response.body).not_to include("secret-payroll")
    expect(response.parsed_body["repositories"].map { |row| row["id"] }).not_to include(invisible.id)
  end

  # Not a restatement of the example above. That one asserts the OUTPUT; this asserts the RULE the
  # output came from, which is what the ticket requires — administration lands on the same policy
  # object the dashboard uses rather than on a parallel implementation. A hand-written
  # `where(user_id:)` would pass the first example and fail this one the day a third access path is
  # added to `accessible_by`.
  # @intent: { entity: "repository list", action: "read the shared policy", behavior: "the served ids match Repository.accessible_by exactly, so the endpoint reads the shared policy object rather than a parallel copy of the rule", layer: "request" }
  it "serves exactly `Repository.accessible_by`, not a second copy of the rule" do
    get_repositories

    expect(response.parsed_body["repositories"].map { |row| row["id"] })
      .to match_array(Repository.accessible_by(person).pluck(:id))
  end

  # @intent: { entity: "repository list", action: "name the access path", behavior: "each row names owner or member, the access path it arrived by", layer: "request" }
  it "names which of the two access paths each row arrived by" do
    get_repositories

    roles = response.parsed_body["repositories"].to_h { |row| [row["full_name"], row["role"]] }

    expect(roles).to eq("acme/billing-service" => "owner", "acme/ledger" => "member")
  end

  # @intent: { entity: "repository list", action: "answer an empty account", behavior: "an account that can open nothing gets HTTP 200 with an empty list, not a 404", layer: "request" }
  it "answers an empty list — not a 404 — for somebody who can open nothing" do
    loner = create_user(github_uid: "3003", github_handle: "nobody")

    get_repositories(token: create_user_api_key(user: loner).raw_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"]).to eq([])
  end

  # @intent: { entity: "user api key", action: "stamp last use", behavior: "authenticating with the user key stamps last_used_at, nil before the request and present after it", layer: "request" }
  it "records when the key was last used" do
    expect(user_api_key.last_used_at).to be_nil

    get_repositories

    expect(user_api_key.reload.last_used_at).to be_present
  end

  # @intent: { entity: "user api key", action: "refuse an unknown token", behavior: "an unrecognized sgu token answers 401 with an unauthorized JSON error", layer: "request" }
  it "rejects an unknown user token with 401" do
    get_repositories(token: "sgu_definitely-not-a-key")

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("unauthorized")
  end

  # @intent: { entity: "user api key", action: "refuse a missing header", behavior: "a request with no Authorization header answers 401", layer: "request" }
  it "rejects a missing Authorization header with 401" do
    get "/api/v1/repositories"

    expect(response).to have_http_status(:unauthorized)
  end

  # SPGD-830. The machine half of the marker the browser's card grid has rendered since SPGD-820.
  # The verdict is an ORDERING between two recorded facts — the newest refusal against the newest
  # accepted run — so every example below states BOTH sides of it rather than asserting against a
  # window in hours.
  describe "delivery_health" do
    def health_for(full_name)
      response.parsed_body["repositories"].find { |row| row["full_name"] == full_name }["delivery_health"]
    end

    # AC1. Served on EVERY entry, owned and member-role alike — the point being that a client can
    # read the key without first establishing whether this repository has any history.
    # @intent: { entity: "delivery_health", action: "serve on every entry", behavior: "each listed repository carries the delivery_health block whatever its role and whatever its history", layer: "request" }
    it "serves the block on every entry, whatever the role and whatever the history" do
      get_repositories

      expect(response.parsed_body["repositories"].map { |row| row["delivery_health"] })
        .to all(match("refusing" => be_in([true, false]), "last_rejection_at" => be_nil.or(be_a(String))))
      expect(response.parsed_body["repositories"].map { |row| row.key?("delivery_health") }).to eq([true, true])
    end

    # AC2. The ordinary refusing case, and the timestamp is the refusal's own `occurred_at` in
    # iso8601 rather than "some recent time".
    # @intent: { entity: "delivery_health", action: "read a fresh refusal", behavior: "a rejection landing after the newest run reads refusing true with the refusal own occurred_at as the timestamp", layer: "request" }
    it "reads refusing with the refusal's own time when a rejection lands after the newest run" do
      create_test_run(repository: owned, created_at: 2.hours.ago)
      refuse(owned, at: 30.minutes.ago)

      get_repositories

      expect(health_for("acme/billing-service"))
        .to eq("refusing" => true, "last_rejection_at" => owned.ingest_rejections.first.occurred_at.iso8601)
    end

    # AC3. The key is PRESENT and says `false`. An absent key would read as "SpecGuard does not
    # track that", which is a different fact from "nothing was refused" — the sibling endpoint's own
    # stated rule, asserted here against `key?` so that omitting the block cannot pass as a nil.
    # @intent: { entity: "delivery_health", action: "read a clean stream", behavior: "nothing refused reads refusing false with a present-but-null timestamp, so the key is never omitted to say false", layer: "request" }
    it "reads not-refusing with a null timestamp, and never omits the key, when nothing was refused" do
      create_test_run(repository: owned, created_at: 2.hours.ago)

      get_repositories

      row = response.parsed_body["repositories"].find { |entry| entry["full_name"] == "acme/billing-service" }

      expect(row["delivery_health"].key?("last_rejection_at")).to be(true)
      expect(row["delivery_health"]).to eq("refusing" => false, "last_rejection_at" => nil)
    end

    # AC4. THE INVERTING NIL LIMB, and the case a hand-rolled `>` gets wrong: a repository refused
    # with no accepted run EVER is not "no comparison available", it is the most refusing state
    # there is. A `last_rejection_at > nil` would raise; a `nil`-guarded `&&` would read `false`.
    # @intent: { entity: "delivery_health", action: "read the nil limb", behavior: "a repository refused with no accepted run ever reads refusing true, the limb a hand-rolled comparison gets wrong", layer: "request" }
    it "reads refusing for a repository that has been refused and has never had a run accepted" do
      refuse(owned, at: 10.minutes.ago)

      expect(owned.test_runs).to be_empty

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
    end

    # AC5. The verdict and the timestamp are INDEPENDENT facts. A repository that hit a bad payload
    # and has ingested cleanly since reads healthy — with no window to expire — but the refusal it
    # survived is still reported, so a client can see that it happened.
    # @intent: { entity: "delivery_health", action: "separate verdict and timestamp", behavior: "an accepted run landing on top of a refusal reads healthy while still naming the refusal it survived", layer: "request" }
    it "reads not-refusing but still names the refusal when an accepted run lands on top of it" do
      refuse(owned, at: 3.hours.ago)
      create_test_run(repository: owned, created_at: 1.hour.ago)

      get_repositories

      expect(health_for("acme/billing-service"))
        .to eq("refusing" => false, "last_rejection_at" => owned.ingest_rejections.first.occurred_at.iso8601)
    end

    # AC6. FLAT IN N — the assertion this block exists to protect, since both reads are grouped
    # aggregates that would be invisible as an N+1 against a one-repository fixture. Same shape as
    # `spec/requests/api/v1/repository_latest_run_spec.rb`'s budget: the same count at one row as at
    # several. Every added repository carries a refusal and a SHARDED run, so the extra entries
    # exercise every read the entry serves rather than short-circuiting on absent history: the
    # refusal aggregate, the newest-run resolution, and the shard priming the `latest_run` block
    # was added to serve — the budget this example bounds is now the budget of the whole entry.
    # SPGD-941 widens the claim along its second axis, INSIDE this example rather than beside it
    # so one example keeps bounding the whole request: the narrowing asks ride the same request and
    # must add nothing to it — `?q=` and `?role=` are predicates on the relation already being
    # loaded, and `?sort=stale` sorts the loaded array against the runs map already resolved — so
    # a fully-asked request over the same four repositories costs the same again.
    # @intent: { entity: "delivery_health", action: "stay flat in N and under asks", behavior: "the request issues the same number of queries whether the account holds one repository or four, whether the three narrowing asks are absent or all present, each repository carrying a refusal and a sharded run", layer: "request" }
    it "issues the same number of queries for one repository as for several, asked or not" do
      solo = create_user(github_uid: "4004", github_handle: "solo")
      solo_key = create_user_api_key(user: solo)
      only = create_repository(user: solo, github_full_name: "acme/only")
      refuse(only)
      sharded_run(only)

      one = count_queries { get_repositories(token: solo_key.raw_token) }

      %w[acme/second acme/third acme/fourth].each do |name|
        repository = create_repository(user: solo, github_full_name: name)
        refuse(repository)
        sharded_run(repository)
      end

      several = count_queries { get_repositories(token: solo_key.raw_token) }

      expect(response.parsed_body["repositories"].size).to eq(4)
      # The block was SERVED, not merely survived: an implementation that quietly stopped building
      # the `latest_run` entry would hold the equality below while bounding nothing, because both
      # sides would have dropped the same reads.
      expect(response.parsed_body["repositories"].map { |row| row.dig("latest_run", "shards", "count") })
        .to all(eq(4))
      expect(several).to eq(one)

      # The fully-asked third read. All four repositories match the ask (`acme`, all owned by
      # solo), so the same N entries are served at the same count: the asks are present and doing
      # nothing to the query plan but reordering. The block assertions above are re-made on THIS
      # response, so a asked request that stopped serving an entry could not pass on the count
      # alone.
      asked = count_queries do
        get_repositories(token: solo_key.raw_token,
                         params: { q: "acme", role: "owned", sort: "stale" })
      end

      expect(response.parsed_body["repositories"].size).to eq(4)
      expect(response.parsed_body["repositories"].map { |row| row.dig("latest_run", "shards", "count") })
        .to all(eq(4))
      expect(asked).to eq(several)
    end

    # AC7. The early return, asserted as the ABSENCE OF THE READS rather than as a query total — a
    # total would still pass if one aggregate were traded for another. An account that can open
    # nothing pays for none of the three grouped reads an entry can trigger.
    # @intent: { entity: "delivery_health", action: "skip the empty account", behavior: "an account with no repositories issues no rejection read, no test_runs read and no test_run_shards read at all, the early returns asserted as absent reads", layer: "request" }
    it "takes no rejection or run aggregate at all for an account with no repositories" do
      loner = create_user(github_uid: "3003", github_handle: "nobody")
      token = create_user_api_key(user: loner).raw_token

      rejection_reads = nil
      shard_reads = nil
      run_reads = queries_against("test_runs") do
        shard_reads = queries_against("test_run_shards") do
          rejection_reads = queries_against("ingest_rejections") { get_repositories(token: token) }
        end
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"]).to eq([])
      expect(rejection_reads).to be_empty
      expect(run_reads).to be_empty
      expect(shard_reads).to be_empty
    end

    # AC8. THE RULE, not the output — the same distinction the `accessible_by` example above draws.
    # `RejectedIngests` forbids a second inline expression of the ordering rule because its two
    # `nil` limbs do not both fall out of a bare `>`, and a controller that re-spelled it would pass
    # every example above and diverge the day the rule changes on one side only.
    # @intent: { entity: "delivery_health", action: "delegate the verdict", behavior: "the verdict is reached through RejectedIngests.verdict rather than an inline re-spelling of the ordering rule", layer: "request" }
    it "reaches the verdict through `RejectedIngests.verdict` rather than re-spelling the comparison" do
      refuse(owned, at: 10.minutes.ago)

      expect(RejectedIngests).to receive(:verdict).at_least(:once).and_call_original

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
    end

    # AC9. The five fields that were here before are unchanged in NAME and in VALUE — the new block
    # is additive, and a client reading the old five is unaffected.
    # @intent: { entity: "repository list", action: "preserve the old fields", behavior: "the pre-existing id, full_name, name, registered_at and role fields are unchanged in name and value beside the new block", layer: "request" }
    it "leaves the five existing fields untouched" do
      refuse(owned)

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
      expect(response.parsed_body["repositories"].first)
        .to include("id" => owned.id, "full_name" => "acme/billing-service", "name" => owned.name,
                    "registered_at" => owned.created_at.iso8601, "role" => "owner")
    end
  end

  # SPGD-773. The run-level half of what the list was missing: an agent ranking its repositories by
  # recency of CI activity and by suite cost had to open each one, because the entry carried nothing
  # about any run. The block is `LatestRunSerializer`'s at LIST depth — the SAME serializer the two
  # overview routes serve in full — so the list entry and the detail page name every shared fact
  # identically by construction, and the examples below pin that construction rather than trust it.
  describe "latest_run" do
    def entry_for(full_name)
      response.parsed_body["repositories"].find { |row| row["full_name"] == full_name }
    end

    # The ordinary entry: a repository with one unsharded run. Asserted as an EXACT block rather
    # than a scattering of `include`s, so a key that changes name, type or value cannot slip
    # through beside the ones that were checked — and so `shards: null` is pinned as the
    # single-part answer rather than read off an assertion that never mentioned it.
    # @intent: { entity: "repository list latest_run", action: "serve the list depth", behavior: "an entry whose repository has a plain single-part run carries the run-level scalars exactly - ratio as the 0-1 fraction, duration raw, shards null", layer: "request" }
    it "serves the newest run's scalars on the entry, with shards null for a single-part run" do
      run = create_test_run(repository: owned, commit_sha: "feedfacedead", branch: "main",
                            total_specs_count: 40, annotated_specs_count: 10, duration_seconds: 42.5)

      get_repositories

      expect(entry_for("acme/billing-service")["latest_run"]).to eq(
        "ingested_at" => run.created_at.iso8601,
        "branch" => "main",
        "commit_sha" => "feedfacedead",
        "total_specs" => 40,
        "annotated_specs" => 10,
        # THE 0-1 FRACTION, not the 0-100 percentage `TestRun#annotated_ratio` renders for the
        # dashboard: 10 of 40 is 0.25 here, and a list that disagreed with the detail endpoint by
        # 100x would do so silently, in a JSON body, for every client that read both.
        "annotated_ratio" => 0.25,
        "suite_size_measured" => true,
        "duration_seconds" => 42.5,
        # Null, not an empty or zeroed block: this run was delivered in one piece, and there is no
        # composition to explain. The detail endpoint serves the same null for the same run.
        "shards" => nil
      )
    end

    # The additivity pin: the entry is the six fields it already served plus the new block, and
    # NOTHING ELSE. A list that grew a key quietly would be additive too — and unbounded.
    # @intent: { entity: "repository list", action: "pin the entry shape", behavior: "each entry carries exactly the seven fields - the six identity and delivery fields plus latest_run - so additions cannot land quietly", layer: "request" }
    it "serves exactly the seven entry fields, the new block last" do
      create_test_run(repository: owned, total_specs_count: 3)

      get_repositories

      expect(entry_for("acme/billing-service").keys)
        .to eq(%w[id full_name name registered_at role delivery_health latest_run])
    end

    # `null` — never a zeroed block — for a repository CI has never reported to, and the contrast
    # that makes the null worth serving: this repository's deliveries ARE being refused, and the
    # two blocks read together are what tell "CI stopped reporting" apart from "SpecGuard is
    # throwing everything away". A `total_specs: 0` block would assert the suite is EMPTY, which
    # is a different fact and not true of this repository — nothing was ever measured.
    # @intent: { entity: "repository list latest_run", action: "answer never-ingested", behavior: "an entry whose repository never accepted a run carries latest_run null - present key, null value, never a zeroed block - beside a delivery_health that can still read refusing", layer: "request" }
    it "serves null — not a zeroed block — for a repository CI has never reported to, refused or not" do
      refuse(shared, at: 10.minutes.ago)

      expect(shared.test_runs).to be_empty

      get_repositories

      row = entry_for("acme/ledger")

      expect(row.key?("latest_run")).to be(true)
      expect(row["latest_run"]).to be_nil
      expect(row["delivery_health"]).to include("refusing" => true)
    end

    # THE COST PAIR, on the canonical 4-shard composition: `duration_seconds` stays the wall clock
    # (the MAX, 74.25) and `machine_seconds` is the SUM across the shards (253.75). Serving the MAX
    # as the cost would understate this suite by 3.4x, and a client ranking repositories by suite
    # cost would rank this one wrong against every unsharded suite in the same list.
    # @intent: { entity: "repository list latest_run", action: "serve the shard cost", behavior: "a sharded run's entry nests shards with count, timed_count and the machine_seconds SUM across shards - 253.75 not the 74.25 wall clock - mirroring the detail endpoint's key names", layer: "request" }
    it "nests the shard scalars, with machine_seconds the SUM across shards rather than the MAX" do
      sharded_run(owned)

      get_repositories

      block = entry_for("acme/billing-service")["latest_run"]

      expect(block["shards"]).to eq("count" => 4, "timed_count" => 4, "machine_seconds" => 253.75)
      expect(block["duration_seconds"]).to eq(74.25)
    end

    # The nullability seam inside the nested block, preserved as the detail endpoint serves it: a
    # sharded run whose shards reported NO timing has real counts and a `null` machine time, never
    # `0.0` — "nobody reported" is not a measurement of zero seconds. `duration_seconds` is null on
    # the same run for the same reason.
    # @intent: { entity: "repository list latest_run", action: "preserve shard nullability", behavior: "a sharded run whose shards reported no timing serves real counts with a null machine_seconds and a null duration_seconds, never measured zeros", layer: "request" }
    it "keeps the not-reported seams null on a sharded run whose shards reported no timing" do
      sharded_run(owned, durations: [nil, nil, nil])

      get_repositories

      block = entry_for("acme/billing-service")["latest_run"]

      expect(block["shards"]).to eq("count" => 3, "timed_count" => 0, "machine_seconds" => nil)
      expect(block["duration_seconds"]).to be_nil
    end

    # THE DRIFT GUARD, and the example the whole `LatestRunSerializer` extraction exists to make
    # pass forever: every fact the list serves about a run is compared, key for key and value for
    # value, against the SAME run's block on the detail route — the same comparison
    # `user_repository_overview_spec.rb` draws between the two detail routes. The detail block is
    # the superset; the list block's nested `shards` is compared against the detail's `shards` one
    # key at a time for the same reason, so the detail's deeper keys there are not a mismatch but
    # the depth itself.
    # @intent: { entity: "repository list latest_run", action: "match the detail route", behavior: "every key the list depth serves equals the same key on the detail route for the same run, nested shards included, so the two surfaces cannot name a shared fact differently", layer: "request" }
    it "names every fact identically to the singular overview's latest_run block" do
      sharded_run(owned)

      get_repositories

      list_block = entry_for("acme/billing-service")["latest_run"]

      get "/api/v1/repositories/#{owned.id}",
          headers: { "Authorization" => "Bearer #{user_api_key.raw_token}" }

      detail_block = response.parsed_body["latest_run"]

      expect(detail_block["commit_sha"]).to eq(list_block["commit_sha"])

      list_block.each do |key, value|
        if value.is_a?(Hash)
          value.each { |nested_key, nested| expect(detail_block[key][nested_key]).to eq(nested) }
        else
          expect(detail_block[key]).to eq(value)
        end
      end
    end
  end

  # SPGD-941 — the three narrowing asks the web repositories index reads (`?q=`, `?role=owned|
  # shared`, `?sort=stale`) arriving at their second surface. The endpoint serves the identical
  # `Repository.accessible_by` population the card grid narrows, UNPAGINATED, and one
  # `BulkRegistration::MAX_BATCH` gesture puts a hundred repositories on it — until these
  # parameters the action read NO parameter at all, so an agent looking for one repository had to
  # ingest the whole body to find it. The parameters are read through the SAME three concerns the
  # web grid reads (`RequestedSearchParam`, `RequestedRoleParam`, `RequestedSortParam`), so a shape
  # the web clamps to no-ask cannot be answered differently here.
  #
  # ## What the guards are FOR here
  #
  # `?q[]=` reaches an `ILIKE`, and an Array would not raise — it would answer a question nobody
  # asked, in a body an agent then trusts. The malformed hosts below assert the NO-ASK answer
  # specifically (the whole accessible set, default order), never a bare 200, for the reason each
  # shared example's own doc comment carries: a guard that swallowed every value would also answer
  # 200 on every shape, and only the positive-path example beside the host separates the two.
  describe "narrowing the list — ?q=, ?role=, ?sort=stale" do
    def full_names
      response.parsed_body["repositories"].map { |row| row["full_name"] }
    end

    def entries
      response.parsed_body["repositories"]
    end

    describe "?q= — finding one repository by part of its name" do
      it "matches a case-insensitive substring of the full name" do
        get_repositories(params: { q: "BILLING" })

        expect(response).to have_http_status(:ok)
        expect(full_names).to eq(["acme/billing-service"])
      end

      # The `_` and `%` a caller can legitimately send are TEXT in a repository name (`org/my_repo`
      # is an ordinary slug), so an unescaped `ILIKE` would widen "my_repo" to match `my-repo` and
      # `myxrepo` — answering a substring ask with a pattern match. `sanitize_sql_like` escapes
      # them, and this is the example that keeps it true: drop the escape and this goes red
      # without anything raising anywhere else in the suite.
      it "treats a typed underscore as text, not as a single-character wildcard" do
        create_repository(user: person, github_full_name: "acme/my_repo")
        create_repository(user: person, github_full_name: "acme/my-repo")

        get_repositories(params: { q: "my_repo" })

        expect(full_names).to eq(["acme/my_repo"])
      end

      # The narrowing must happen IN SQL INSIDE `Repository.accessible_by`, never as a post-load
      # filter — this is the security claim of the parameter, and it is a property of the
      # STATEMENT. Captured off the wire (`captured_sql`, the shared subscriber) rather than
      # re-spelled here, so a read that stopped being in-scope cannot pass by agreeing with a
      # hand-written duplicate: the accessibility union and the `ILIKE` must be predicates of ONE
      # WHERE on ONE read of `repositories` — the only statement this request makes against that
      # table.
      it "narrows inside the accessible scope in SQL, not as a post-load filter" do
        sql = captured_sql('FROM "repositories"') { get_repositories(params: { q: "billing" }) }

        expect(full_names).to eq(["acme/billing-service"])
        expect(sql).to match(/ILIKE/)
        # ...and the accessibility union is still in the SAME statement: the search did not become
        # a second pass over a set that had already been resolved, which is where a post-load
        # filter would show up as two friendly-looking queries.
        expect(sql).to match(/"user_id" = /)
        expect(sql).to match(/IN \(SELECT "repository_memberships"/)
      end

      # The other half of being in-scope: a repository this key cannot open must never ENTER the
      # relation, so a name search cannot be turned into an existence probe. The filtered-empty
      # list is the whole answer — never the stranger's repository, and never an error that would
      # distinguish "matched nothing" from "does not exist".
      it "cannot be used to probe for a repository this key cannot open" do
        get_repositories(params: { q: "secret-payroll" })

        expect(response).to have_http_status(:ok)
        expect(entries).to eq([])
      end

      # The positive path beside the malformed host below: `?q=<text>` IS honoured, which is what
      # separates a working guard from one that swallows every shape — including the shapes the
      # host asserts are no-asks.
      it "is honoured as a narrowing ask, not merely tolerated" do
        get_repositories(params: { q: "ledger" })

        expect(full_names).to eq(["acme/ledger"])
      end

      describe "a search parameter that is not a search string" do
        def expect_search_param_treated_as_no_ask(query)
          get_repositories(params: query)

          expect(response).to have_http_status(:ok)
          # The no-ask answer specifically: the whole accessible set, in the default name order.
          expect(full_names).to eq(["acme/billing-service", "acme/ledger"])
        end

        it_behaves_like "a surface that treats a malformed search parameter as no ask"
      end
    end

    describe "?role= — what this key owns versus what was shared with it" do
      # One of each population in the file's top-level fixture (`owned`, `shared`), so every
      # example here proves the LINE rather than a presence: an ask honoured serves its side and
      # hides the other, an ask ignored serves both.
      it "narrows to what the key's person owns" do
        get_repositories(params: { role: "owned" })

        expect(full_names).to eq(["acme/billing-service"])
      end

      it "narrows to what was shared with the key's person" do
        get_repositories(params: { role: "shared" })

        expect(full_names).to eq(["acme/ledger"])
      end

      # `shared` is the COMPLEMENT WITHIN the accessible set — not a second reading of the
      # membership table — so the two asks must partition the unparameterised list exactly, with
      # no repository on both sides and none dropped between them. That partition is what makes
      # the `role` field's owner/member distinction safe to hand a filter on.
      it "partitions the list exactly between the two asks" do
        get_repositories(params: { role: "shared" })
        shared_side = full_names

        get_repositories(params: { role: "owned" })
        owned_side = full_names

        get_repositories
        whole_list = full_names

        expect((shared_side + owned_side).sort).to eq(whole_list.sort)
        expect(shared_side & owned_side).to be_empty
      end

      describe "a role parameter that names no ownership state" do
        def expect_role_param_treated_as_no_ask(query)
          get_repositories(params: query)

          expect(response).to have_http_status(:ok)
          # The no-ask answer specifically: BOTH populations, which is what distinguishes a
          # clamped read from one that silently narrowed to either side.
          expect(full_names).to eq(["acme/billing-service", "acme/ledger"])
        end

        it_behaves_like "a surface that treats a non-owned-or-shared role parameter as no ask"
      end
    end

    describe "?sort=stale — ordering by last-ingested recency" do
      # The web grid's rule, restated for a body an agent reads as a sequence: never-ingested
      # first, then least-recently-ingested first, newest last. The fixture is arranged so the
      # stale order and the default name order DISAGREE — the never-ingested repository is named
      # last — so an implementation that ignored the ask serves a different sequence and this
      # goes red.
      it "puts never-ingested first and the most recently ingested last" do
        create_test_run(repository: owned, commit_sha: "cafe0902", total_specs_count: 10,
                        created_at: 1.hour.ago)
        create_test_run(repository: shared, commit_sha: "cafe0901", total_specs_count: 10,
                        created_at: 3.months.ago)
        create_repository(user: person, github_full_name: "acme/zebra")

        get_repositories(params: { sort: "stale" })

        expect(full_names).to eq(["acme/zebra", "acme/ledger", "acme/billing-service"])
      end

      # A shareable URL is a deterministic one: two identical calls must answer with an identical
      # sequence, and the name tie-break is what makes that true rather than merely likely —
      # Ruby's `sort_by` promises no stability on its own, so the tie-break is the determinism.
      it "answers two identical calls with an identical sequence" do
        create_test_run(repository: owned, commit_sha: "cafe0903", total_specs_count: 10,
                        created_at: 1.hour.ago)
        create_repository(user: person, github_full_name: "acme/zebra")

        get_repositories(params: { sort: "stale" })
        first_read = full_names
        get_repositories(params: { sort: "stale" })

        expect(full_names).to eq(first_read)
        # The pinned sequence: ledger and zebra are BOTH never-ingested, so the tie-break orders
        # the limb (`ledger` < `zebra`); the ingested repository follows it, newest-run aside.
        expect(first_read).to eq(["acme/ledger", "acme/zebra", "acme/billing-service"])
      end

      # Same-limb ties — every repository here is never-ingested, one limb, same null recency —
      # so the sequence this asserts is entirely the name tie-break's, and zebra was INSERTED
      # first to prove the order comes from the name and not from row order.
      it "breaks same-recency ties on the name, not on insertion order" do
        create_repository(user: person, github_full_name: "acme/zebra")
        create_repository(user: person, github_full_name: "acme/alpha")

        get_repositories(params: { sort: "stale" })

        expect(full_names).to eq(["acme/alpha", "acme/billing-service", "acme/ledger", "acme/zebra"])
      end

      describe "a sort parameter that names no ordering" do
        # Recency and name DISAGREE about the order here — the fresh run sits on the name-FIRST
        # repository and `ledger` has never been ingested — so a clamped read and an honoured one
        # serve different sequences: this is what lets the no-ask assertion say "name order" and
        # mean it.
        def expect_sort_param_treated_as_no_ask(query)
          create_test_run(repository: owned, commit_sha: "cafe0910", total_specs_count: 10,
                          created_at: 1.hour.ago)

          get_repositories(params: query)

          expect(response).to have_http_status(:ok)
          expect(full_names).to eq(["acme/billing-service", "acme/ledger"])
        end

        it_behaves_like "a surface that treats a non-stale sort parameter as no ask"
      end
    end

    describe "the three asks together" do
      it "compose — narrow, partition and order in one URL" do
        api_shared_stale = create_repository(user: stranger, github_full_name: "acme/api-legacy")
        create_membership(repository: api_shared_stale, user: person)
        api_shared_fresh = create_repository(user: stranger, github_full_name: "acme/api-fresh")
        create_membership(repository: api_shared_fresh, user: person)
        create_test_run(repository: api_shared_fresh, commit_sha: "cafe0920", total_specs_count: 10,
                        created_at: 1.hour.ago)
        create_repository(user: person, github_full_name: "acme/api-owned")

        get_repositories(params: { q: "api", role: "shared", sort: "stale" })

        # The never-ingested shared api match first, the ingested one last; the owned api match
        # and the stranger's invisible repository are both gone.
        expect(full_names).to eq(["acme/api-legacy", "acme/api-fresh"])
      end
    end

    # The asks narrow, partition and REORDER the set — none of them may change an ENTRY. Pinned
    # as whole-entry equality between an unparameterised read and a fully-asked one: same keys,
    # same values, `delivery_health` and `latest_run` included. A parameter that renamed a field,
    # re-typed a value or dropped a block under some ask would hold every example above and still
    # break this one.
    describe "what no ask may change" do
      it "serves the same entry a field at a time, however the list is narrowed" do
        create_test_run(repository: shared, commit_sha: "cafe0930", total_specs_count: 10,
                        created_at: 3.hours.ago)
        refuse(shared, at: 2.hours.ago)

        get_repositories
        unparameterised = entries

        get_repositories(params: { q: "acme", role: "shared", sort: "stale" })
        narrowed = entries

        expect(narrowed.size).to eq(1)
        expect(narrowed.first.keys).to contain_exactly(*unparameterised.first.keys)
        expect(narrowed.first).to eq(unparameterised.find { |row| row["full_name"] == "acme/ledger" })
      end
    end
  end
end
