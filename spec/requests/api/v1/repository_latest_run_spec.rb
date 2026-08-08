# frozen_string_literal: true

require "rails_helper"

# The auth contract for this endpoint lives in `repositories_spec.rb` and is deliberately left
# untouched. This file covers the `latest_run` block — the agent-readable twin of the suite
# figures `repositories#show` renders — and the `history` array beside it, the agent-readable twin
# of the "Recent runs" panel.
RSpec.describe "GET /api/v1/repository — latest_run and history", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  # `query:` rather than a `branch:` keyword, so an example can send a non-String `branch` (an
  # Array, a nested hash) the same way a real client's malformed query string would.
  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  # `executed_sql` and `count_queries` come from spec/support/query_capture.rb. The cost blocks
  # below bound the endpoint on different axes — runs for a branch-scoped window, shards on one run
  # — but they must agree on what they are counting, so the `cached` / SCHEMA / TRANSACTION
  # exclusion lives in the shared helper rather than being restated per block. RSpec scopes a `def`
  # to its own example group, so a helper defined in either block is invisible to the other; that
  # is how it came to be written twice here before it was hoisted out of the file entirely.

  describe "a repository with an ingested run" do
    let!(:test_run) do
      create_test_run(repository: repository,
                      commit_sha: "a1b2c3d4e5f6",
                      branch: "main",
                      total_specs_count: 40,
                      annotated_specs_count: 10,
                      duration_seconds: 42.5)
    end

    it "reports the latest run's suite facts" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to eq(
        "commit_sha" => "a1b2c3d4e5f6",
        "branch" => "main",
        "total_specs" => 40,
        "annotated_specs" => 10,
        "annotated_ratio" => 0.25,
        "duration_seconds" => 42.5,
        # Null, not an empty block: this fixture has no shards, so there is no composition to
        # explain and the MAX the key above reports *is* the SUM. The key is still present, on the
        # same rule `latest_run` itself follows one describe-block down.
        "shards" => nil,
        "suite_size_measured" => true,
        "ingested_at" => test_run.created_at.iso8601
      )
    end

    # AC2. Read off the same accessor `repositories#show` assigns to `@latest_test_run` rather than
    # re-stating the fixture's numbers: two independent hand-written expectations would still both
    # pass if the endpoint started reading a *different* row.
    it "reports the same row, and the same figures, that repositories#show renders" do
      shown = repository.latest_test_run
      block = get_repository["latest_run"]

      expect(block["commit_sha"]).to eq(shown.commit_sha)
      expect(block["branch"]).to eq(shown.branch)
      expect(block["total_specs"]).to eq(shown.total_specs_count)
      expect(block["annotated_specs"]).to eq(shown.annotated_specs_count)
      expect(block["duration_seconds"]).to eq(shown.duration_seconds)
      # The panel renders a second cost figure — `machine_seconds` — beside the wall clock, so
      # "the same figures" is only true if this endpoint accounts for it. This fixture has no
      # shards, and the *reason* the block is null is asserted rather than the null alone: a
      # hard-coded `be_nil` here would keep passing if the gate stopped being `multi_shard?`.
      # The composition where the two figures actually differ is covered further down.
      expect(shown).not_to be_multi_shard
      expect(shown.machine_seconds).to be_nil
      expect(block["shards"]).to be_nil
      expect(block["ingested_at"]).to eq(shown.created_at.iso8601)
    end

    it "leaves the existing repository and api_key blocks in place" do
      body = get_repository

      expect(body.dig("repository", "full_name")).to eq("acme/billing-service")
      expect(body["api_key"]).to have_key("last_used_at")
    end

    # The documented body is the whole feature here — an agent finds out `history` exists by reading
    # `docs/DEVELOPMENT.md`, not by diffing responses. So the top level is pinned EXACTLY rather
    # than key by key: a sixth key added without a line in that doc fails here, and a documented key
    # quietly dropped fails here too. `contain_exactly` is what makes it bidirectional; `have_key`
    # per block would catch neither.
    it "serves exactly the top-level keys docs/DEVELOPMENT.md documents" do
      expect(get_repository.keys)
        .to contain_exactly("repository", "api_key", "latest_run", "history_window", "history",
                            "branches_window", "branches")
    end

    it "scopes latest_run to the key's own repository" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      create_test_run(repository: other, commit_sha: "otherrepo", total_specs_count: 7)

      expect(get_repository.dig("latest_run", "commit_sha")).to eq("a1b2c3d4e5f6")
    end
  end

  # The `created_at desc, id desc` tie-break, which is the half of "same row" a single-run fixture
  # cannot exercise: two runs stamped the same instant order by id, so the endpoint and the
  # dashboard cannot name different commits for the same repository.
  describe "two runs ingested in the same instant" do
    # Both runs land on one `created_at`, so `created_at` alone cannot order them and only the id
    # tie-break can. Extracted so the `history` example below pins the SAME pair rather than
    # building a second fixture that might tie differently.
    def two_runs_stamped_together
      stamp = 1.hour.ago
      older = create_test_run(repository: repository, commit_sha: "older0", total_specs_count: 1)
      newer = create_test_run(repository: repository, commit_sha: "newer0", total_specs_count: 1)
      [older, newer].each { |run| run.update_columns(created_at: stamp) }

      [older, newer]
    end

    it "breaks the created_at tie the same way Repository#latest_test_run does" do
      _older, newer = two_runs_stamped_together

      expect(repository.latest_test_run).to eq(newer)
      expect(get_repository.dig("latest_run", "commit_sha")).to eq(repository.latest_test_run.commit_sha)
    end

    # The invariant `history` is most likely to break, and the only fixture that can catch it: an
    # ordering that dropped the id tie-break still agrees with `latest_run` on every distinctly
    # stamped fixture and disagrees only here. Asserted on the RESPONSE's own two blocks — not each
    # against the model — because a re-sort in the serializer would move both of the model's
    # answers not at all and both of the response's independently.
    it "names the same run in history[0] as in latest_run" do
      older, newer = two_runs_stamped_together

      body = get_repository

      expect(body["history"].first["commit_sha"]).to eq(body.dig("latest_run", "commit_sha"))
      expect(body["history"].map { |row| row["commit_sha"] }).to eq([newer.commit_sha, older.commit_sha])
    end
  end

  # AC3. `null`, not a zeroed block: a repository whose CI has never reported must not be
  # indistinguishable from one that reported an empty suite.
  describe "a repository whose CI has never reported" do
    it "reports latest_run as null rather than a block of zeros" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body).to have_key("latest_run")
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. Both columns are nullable and Ingest::Payload accepts a body omitting either.
  describe "a run that reported no branch and no duration" do
    before do
      create_test_run(repository: repository, commit_sha: "nobranch", total_specs_count: 3,
                      annotated_specs_count: 1, branch: nil, duration_seconds: nil)
    end

    it "keeps branch null instead of substituting a name" do
      expect(get_repository["latest_run"]).to include("branch" => nil)
    end

    it "keeps duration_seconds null instead of asserting the run took no time" do
      expect(get_repository["latest_run"]).to include("duration_seconds" => nil)
    end
  end

  # AC5. `TestRun#annotated_fraction` floors at 0.0 by zero-denominator guard; emitting that here
  # would read as a *measured* zero share beside real fractions.
  describe "a run that reported zero tests" do
    before { create_test_run(repository: repository, commit_sha: "emptysuite", total_specs_count: 0) }

    it "reports no ratio rather than a confident 0.0" do
      expect(get_repository["latest_run"]).to include("annotated_ratio" => nil)
    end

    it "still reports the counts, so a client can see the suite was empty" do
      expect(get_repository["latest_run"]).to include("total_specs" => 0, "annotated_specs" => 0)
    end

    # The counts above are the whole problem: `total_specs: 0` is a report, not a measurement, and
    # nothing else in the block distinguishes "the suite is empty" from "the run never measured a
    # suite". `false` — not a missing key, not `null` — is what says so, on the same rule
    # `timed_shard_count` follows on a history row: a guard a client must first test for the
    # presence of is not a guard.
    it "flags a run that reported no tests as not a measurement of the suite" do
      expect(get_repository["latest_run"]).to include("suite_size_measured" => false)
    end

    # THE IDENTITY. In the unfiltered window `history[0]` is the SAME ROW as `latest_run` — pinned
    # in docs/DEVELOPMENT.md and protected by `history_runs`' shared ordering — so one response body
    # here describes one database row twice. Before this key was served on `latest_run`, those two
    # descriptions could disagree: the row said `suite_size_measured: false` as `history[0]` and
    # could not say it at all thirty lines up.
    #
    # Read off the two blocks and compared to each other rather than against a hard-coded `false`,
    # because the claim is agreement and not a value: a serializer that hard-codes `true` on
    # `latest_run` is caught by the example above, and one that stops reading the same row is caught
    # only here. `commit_sha` is asserted equal first so the comparison cannot pass by comparing two
    # blocks that describe DIFFERENT rows which happen to agree.
    it "agrees with history[0] about the same row it serializes twice" do
      body = get_repository

      expect(body["history_window"]["branch_scope"]).to eq("all_branches")
      expect(body["latest_run"]["commit_sha"]).to eq(body["history"].first["commit_sha"])
      expect(body["latest_run"]["suite_size_measured"])
        .to eq(body["history"].first["suite_size_measured"])
      # Stated, so the example cannot go vacuously green on two rows that both measured a suite —
      # `false` is the only value on which the two blocks could ever have disagreed.
      expect(body["latest_run"]["suite_size_measured"]).to be(false)
    end
  end

  # The other half of the predicate, stated under its own name. The exact-body example at the top of
  # this file already carries `true`, but it carries it among eight other keys and fails under any
  # of them; this is the one example whose name says which value drifted.
  describe "a run that measured a suite" do
    it "reports latest_run.suite_size_measured as true" do
      create_test_run(repository: repository, commit_sha: "measured0000", total_specs_count: 40,
                      annotated_specs_count: 10)

      expect(get_repository["latest_run"]).to include("suite_size_measured" => true)
    end
  end

  # AC6. The unit trap: `TestRun#annotated_ratio` is a 0–100 percentage and `#annotated_fraction`
  # is the 0–1 fraction `/ingest` answers with. A client reading both endpoints must not find them
  # disagreeing by 100×.
  #
  # Written against an UNSHARDED run (no `ci_run_id`) on purpose. `Ingest::RunRecorder` folds every
  # shard of a sharded run onto one row and recomputes its counters as the SUM of the shards, so
  # mid-run the ingest response and a later GET legitimately describe different totals — asserting
  # they match across a sharded fixture would encode an invariant that does not hold.
  describe "agreement with the /ingest response for the same run" do
    it "answers the same annotated_ratio /ingest did, in the same 0–1 unit" do
      post "/api/v1/ingest",
           params: ingest_payload(
             commit_sha: "c0ffee1234",
             branch: "main",
             specs: [
               annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12),
               annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 30, layer: "request"),
               unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)
             ]
           ).to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:accepted)
      ingested = response.parsed_body

      block = get_repository["latest_run"]

      expect(block["annotated_ratio"]).to eq(ingested["annotated_ratio"])
      expect(block["total_specs"]).to eq(ingested["total_specs"])
      expect(block["annotated_specs"]).to eq(ingested["annotated_specs"])
    end

    # Guards the direction the agreement above cannot catch on its own: both sides could drift to
    # the percentage together and still agree with each other.
    it "is the fraction, not the percentage the dashboard renders" do
      create_test_run(repository: repository, commit_sha: "quarter", total_specs_count: 40,
                      annotated_specs_count: 10)

      run = repository.latest_test_run

      expect(get_repository.dig("latest_run", "annotated_ratio")).to eq(run.annotated_fraction)
      expect(get_repository.dig("latest_run", "annotated_ratio")).not_to eq(run.annotated_ratio)
    end
  end

  # AC1/AC6. Every example above this point runs at `shard_count == 0` — the one composition where
  # the run's MAX and its SUM are the same number, and therefore the one composition that cannot
  # show whether the endpoint knows the difference.
  #
  # The durations are the suite's canonical fixture, shared with
  # `spec/requests/api/v1/ingest_spec.rb` (which builds them through `Ingest::RunRecorder` and pins
  # the MAX at 74.25) and `spec/requests/repositories_spec.rb` (which renders them in the Overview
  # panel). Three surfaces, one set of rows: if the API and the panel ever start naming different
  # cost figures for the same run, one of these files goes red.
  describe "a run assembled from more than one shard" do
    # Written directly, in the shape `repositories_spec.rb`'s own `sharded_run` helper uses. The
    # recorder is exercised in the ingest spec; the question here is only what the serializer does
    # with the rows it leaves behind.
    #
    # `settled:` backdates the shard rows' `updated_at`, and it exists because the naive fixture
    # cannot reach the decomposition at all. `TestRun#shard_delivery_settled?` reads
    # `MAX(updated_at)` over these rows against a 15-minute window, so a run whose shards were
    # created inline is a run something wrote to a moment ago — still arriving, by that proxy.
    # Every example below that asserts a NON-null `rows` / floor / excess must pass `settled: true`
    # or it gets three nulls and passes for the wrong reason, which is the Vacuous Green shape this
    # file is otherwise careful about.
    #
    # It DEFAULTS to false so the examples written before the decomposition landed keep the exact
    # fixture they were written against — their four-key assertions are the byte-identical
    # regression check on the original block, and silently settling their runs would change what
    # they cover.
    #
    # `update_all` rather than `travel_to`: the fixture states the fact it needs (these rows were
    # last written to half an hour ago) instead of moving the whole clock under every other query
    # in the example, and it leaves the frozen-vs-real-time question — which no spec in this suite
    # has had to answer yet — unasked.
    def sharded_run(durations, commit_sha:, settled: false, shard_ids: nil)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, annotated_specs_count: 5000,
                                         duration_seconds: durations.compact.max)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: shard_ids ? shard_ids[index] : (index + 1).to_s,
                                    total_specs_count: 5000,
                                    annotated_specs_count: 1250, duration_seconds: seconds)
      end
      run.test_run_shards.update_all(updated_at: 30.minutes.ago) if settled
      run
    end

    # The doc-drift guard at the top of this file, carried down to the levels its SELECTOR cannot
    # reach. `get_repository.keys` is depth 1: it pins the seven top-level names and nothing inside
    # them, so SPGD-234 added three keys at depth 3 with no line in `docs/DEVELOPMENT.md` and went
    # green straight past it. A reviewer caught that by hand on a 6/6 git precedent, and `bin/ci`
    # has no doc-drift step (`config/ci.rb` confirms) — hand-review was the only signal there was.
    #
    # WHAT WAS ACTUALLY UNGUARDED, established by mutation rather than by reading. The value
    # assertions in this block are full-hash `eq`s, so they DO pin these key sets today: appending
    # a key to `serialized_shards` turns three of them red, and one to `serialized_latest_run`
    # turns two red. The hole is one axis over. Every one of those five pins is written against a
    # run where the conditional branch is CLOSED — unsharded for `latest_run`, un-settled for
    # `shards` — so a key served only on the OPEN branch is invisible to all five: appending one
    # under `if decomposable` leaves this whole file green, and so does a `latest_run` key served
    # only `if multi_shard?`. That is precisely where SPGD-234's three keys landed. They were
    # caught only because their contract makes them present-and-null when withheld; written the
    # natural way — absent when withheld — they would have shipped with no doc line and no red
    # spec at all.
    #
    # So these guards are stated on the OPEN gate, where nothing was watching, and the closed gate
    # is re-asserted from the SAME list so the two states cannot drift into disagreeing about what
    # the block contains.
    #
    # KEYS, NOT VALUES, on the precedent the `history[]` row guard sets further down. The `eq`s
    # above pin these names only as a side effect of asserting one fixture's arithmetic, and they
    # read as cost-figure examples; a guard whose stated subject IS the key set survives a fixture
    # whose numbers change, and says out loud what a new key owes the doc before it ships.
    def documented_shard_keys
      %w[count timed_count machine_seconds coverage rows balanced_wall_clock_seconds
         wall_clock_excess_seconds per_shard]
    end

    it "serves exactly the latest_run keys docs/DEVELOPMENT.md documents, on a sharded run" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0198", settled: true)
      # The composition neither existing `latest_run` pin sees — both are written against the
      # unsharded fixture. Asserted BEFORE the keys are read, so this cannot quietly become a
      # second copy of a guard that already passes on the run it means to exclude.
      expect(repository.latest_test_run).to be_multi_shard

      expect(get_repository["latest_run"].keys)
        .to contain_exactly("commit_sha", "branch", "total_specs", "annotated_specs",
                            "annotated_ratio", "duration_seconds", "shards",
                            "suite_size_measured", "ingested_at")
    end

    it "serves exactly the documented shards keys once the decomposition is open" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0199", settled: true)
      # `shards` is `null` on an unsharded run, so a key-set assertion that never checked the
      # fixture would be reading `.keys` off `nil` — Vacuous Green, in the file that exists to
      # avoid it. `wall_clock_decomposable?` is the stronger of the two states to assert, since it
      # implies `multi_shard?` and is the branch the mutation above proved unguarded.
      expect(repository.latest_test_run).to be_wall_clock_decomposable

      expect(get_repository.dig("latest_run", "shards").keys)
        .to contain_exactly(*documented_shard_keys)
    end

    it "serves those same keys while the decomposition is withheld" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0200")
      shown = repository.latest_test_run
      expect(shown).to be_multi_shard
      expect(shown).to be_wall_clock_decomposition_pending

      shards = get_repository.dig("latest_run", "shards")

      # The same eight names as the open gate, from the same list: withholding a figure withholds
      # its VALUE, not its name. That is `serialized_shards`' stated contract and the reason a
      # client tests one thing (`rows == null`) rather than distinguishing an absent key from a
      # null one — and a guard written only against the open gate would pass a change that made
      # the three keys absent here instead, which is the regression the contract exists to stop.
      expect(shards.keys).to contain_exactly(*documented_shard_keys)
      expect(shards.values_at("rows", "balanced_wall_clock_seconds", "wall_clock_excess_seconds"))
        .to all(be_nil)
    end

    # The defect, stated as an expectation. 74.25s of waiting against 253.75s of machine time is a
    # 3.4× gap on this fixture, and until now the endpoint served only the smaller number.
    it "serves the machine time beside the wall clock, and states what each was computed over" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0179")

      block = get_repository["latest_run"]

      # AC2: unchanged in key, type and value. It is still the MAX.
      expect(block["duration_seconds"]).to eq(74.25)
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 4,
        "machine_seconds" => 253.75,
        "coverage" => { "duration_seconds" => 4, "machine_seconds" => 4 },
        # Present and null, not absent: this fixture's shards were written a moment ago, so
        # `shard_delivery_settled?` reads the run as still arriving and the decomposition is
        # withheld exactly where the Overview panel withholds it. The settled shape of these three
        # keys is asserted in "names which shard the run waited on" below — which is the example
        # that would go red if the gate were nailed shut, since this one cannot tell a correct gate
        # from a permanently closed one.
        "rows" => nil,
        "balanced_wall_clock_seconds" => nil,
        "wall_clock_excess_seconds" => nil,
        # ADDED BESIDE the keys above, which keep their names, their types and their values.
        # The pin is extended rather than rewritten, so the byte-for-byte guarantee those keys
        # carried is still the same guarantee: `eq` over the whole hash fails on a changed value
        # and on a missing key alike.
        #
        # SERVED HERE WHILE `rows` IS NULL, which is the whole reason the two lists are separate.
        # The gate above withholds the RANKING because a duration-ranked read cannot be trusted
        # mid-delivery; it says nothing about the counts, which were written by
        # `Ingest::RunRecorder#upsert_shard` on every POST that has landed. A client still learns
        # how big each delivered shard was.
        #
        # DELIVERY ORDER, not slowest-first. The panel's list ranks, and a ranked read is NULLS
        # FIRST in Postgres and therefore safe only behind `TestRun#wall_clock_decomposable?`;
        # this block gates on `multi_shard?` alone, so it serves an order that claims nothing and
        # lets the client sort. `1, 2, 3, 4` here is insertion order and it is asserted as such —
        # a serializer that started ranking would put `"3"` (74.25s) at the head and go red.
        "per_shard" => [
          { "shard_id" => "1", "duration_seconds" => 61.0, "total_specs" => 5000 },
          { "shard_id" => "2", "duration_seconds" => 58.5, "total_specs" => 5000 },
          { "shard_id" => "3", "duration_seconds" => 74.25, "total_specs" => 5000 },
          { "shard_id" => "4", "duration_seconds" => 60.0, "total_specs" => 5000 }
        ]
      )
    end

    # The half `machine_seconds` and `coverage` cannot answer: WHY the expensive shard was
    # expensive. `duration = test count x cost per test`, and the two causes take opposite actions
    # — rebalance the split, or go and look at what that partition holds. Without the per-shard
    # denominator a client can compute the imbalance and not its cause, which is the same gap the
    # Overview panel had until this slice.
    #
    # Asserted as a DIVISION a client would actually perform, not as the shape of the block: the
    # point is that the two columns beside each other are sufficient, and a `total_specs` served
    # under a shard whose `duration_seconds` belongs to a different row would satisfy the shape.
    it "carries each shard's duration beside the test count it was measured over" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0231")

      rows = get_repository.dig("latest_run", "shards", "per_shard")

      per_test = rows.to_h { |row| [row["shard_id"], (row["duration_seconds"] / row["total_specs"] * 1000).round(1)] }
      # 74.25s over 5,000 tests is 14.9ms each against 11.7ms on the fastest shard: this run's
      # spread is in what the tests COST, because every shard held the same number of them.
      expect(per_test).to eq("1" => 12.2, "2" => 11.7, "3" => 14.9, "4" => 12.0)
      expect(rows.map { |row| row["total_specs"] }.uniq).to eq([5000])
    end

    # NO DERIVED RATE. The block's own rule is structured operands and never the arithmetic over
    # them — `TestRun` words the division in English for the panel and a client should be able to
    # word it differently, or not at all. A `seconds_per_spec` key would also have to invent an
    # answer for a shard whose `total_specs` is `0`, which is a real row: the column is
    # `null: false, default: 0`.
    it "serves the two operands and never the quotient, so the client owns the division" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0232")

      rows = get_repository.dig("latest_run", "shards", "per_shard")

      expect(rows.map(&:keys).uniq).to eq([%w[shard_id duration_seconds total_specs]])
      expect(rows.to_json).not_to include("per_spec")
      expect(rows.to_json).not_to include("per_test")
      expect(rows.to_json).not_to include("ms")
    end

    # A shard that loaded no specs is an ordinary row — `total_specs_count` is
    # `null: false, default: 0` — and it is the row with a wall clock and no denominator. The
    # endpoint serves the zero rather than omitting the shard or substituting a count from
    # somewhere else, and the client is the one that decides not to divide by it. The panel makes
    # the same call in words (`TestRun#shard_size_label`).
    it "serves a zero test count as a zero rather than omitting the shard" do
      run = repository.test_runs.create!(commit_sha: "feedfacecafe0233", ci_run_id: "gha-empty",
                                        total_specs_count: 10_000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: "1", total_specs_count: 10_000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: "2", total_specs_count: 0, duration_seconds: 3.5)

      rows = get_repository.dig("latest_run", "shards", "per_shard")

      expect(rows.length).to eq(2)
      expect(rows.last).to eq("shard_id" => "2", "duration_seconds" => 3.5, "total_specs" => 0)
    end

    # `shard_id` is nullable and a nil one is not an oversight: `Ingest::RunRecorder#upsert_shard`
    # records one row per delivery for a client that shards without exposing an index the gem
    # recognises. `null` says the client did not name the slice — a positional index would hand
    # back a name nothing in CI answers to, which is the mistake the panel's `shard_label` refuses
    # in the same words.
    it "serves an unnamed shard's id as null rather than as a position" do
      run = repository.test_runs.create!(commit_sha: "feedfacecafe0234", ci_run_id: "gha-unnamed",
                                        total_specs_count: 10_000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: nil, total_specs_count: 5000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: nil, total_specs_count: 5000, duration_seconds: 58.5)

      rows = get_repository.dig("latest_run", "shards", "per_shard")

      expect(rows.map { |row| row["shard_id"] }).to eq([nil, nil])
      expect(rows.map { |row| row["total_specs"] }).to eq([5000, 5000])
    end

    # AC5's "the same figures repositories#show renders", on the composition where there is
    # actually a second figure to compare. Read off the accessors the panel renders from rather
    # than the fixture's arithmetic: restating `253.75` here would still pass if the endpoint
    # summed a different set of rows than the panel does.
    it "reports the same cost figures repositories#show renders for the same run" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0180")

      shown = repository.latest_test_run
      block = get_repository["latest_run"]

      expect(shown).to be_multi_shard
      expect(block["duration_seconds"]).to eq(shown.duration_seconds)
      expect(block.dig("shards", "machine_seconds")).to eq(shown.machine_seconds)
      expect(block.dig("shards", "count")).to eq(shown.shard_count)
      expect(block.dig("shards", "timed_count")).to eq(shown.timed_shard_count)
    end

    # The coverage exists for this row. `test_run_shards.duration_seconds` is nullable and
    # `Ingest::Payload` accepts a shard without a timing, so a silent shard is an ordinary state —
    # and the SILENT ONE IS THE SLOWEST here on purpose, because a cancelled or timed-out job
    # usually is. Both figures are then computed over three rows: the SUM is a floor, and the MAX
    # is a maximum over a subset that excluded the very shard that would have set it.
    it "reports both figures' coverage when a shard reported no timing" do
      sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0181")

      block = get_repository["latest_run"]

      # 61.0, not 74.25: the shard that would have been the maximum said nothing.
      expect(block["duration_seconds"]).to eq(61.0)
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 3,
        "machine_seconds" => 179.5,
        # The whole point of the block. Without these a client reads "the run took 61s and cost
        # 179.5s" with no way to learn that both were measured over three of four shards — the
        # caption the Overview panel has and JSON does not.
        "coverage" => { "duration_seconds" => 3, "machine_seconds" => 3 },
        # Two of the gate's three conditions fail on this fixture at once (a shard is untimed AND
        # the rows were just written), so it is not the example that isolates either. The untimed
        # condition gets a settled fixture of its own below.
        "rows" => nil,
        "balanced_wall_clock_seconds" => nil,
        "wall_clock_excess_seconds" => nil,
        # The silent shard keeps its row and its `total_specs`, with `duration_seconds` null. This
        # is why the array is served in DELIVERY order rather than ranked: a duration-ranked read
        # is NULLS FIRST in Postgres, so `"3"` — the shard that reported nothing — would sit at
        # the head of a list a client is entitled to read as slowest-first. `rows` above is null
        # for exactly that reason; this list survives the same fixture because it never claimed an
        # order in the first place.
        "per_shard" => [
          { "shard_id" => "1", "duration_seconds" => 61.0, "total_specs" => 5000 },
          { "shard_id" => "2", "duration_seconds" => 58.5, "total_specs" => 5000 },
          { "shard_id" => "3", "duration_seconds" => nil, "total_specs" => 5000 },
          { "shard_id" => "4", "duration_seconds" => 60.0, "total_specs" => 5000 }
        ]
      )
    end

    # AC1's actual requirement, restated as a check a client could run: the coverage is reported as
    # COUNTS, not as the prose `TestRun#machine_seconds_coverage` / `#wall_clock_coverage` write
    # for the panel. A client that has to regex "slowest of the 3 that reported" out of a string
    # has not been told anything it can compute with.
    it "carries the coverage as counts a client can divide, not as the panel's sentences" do
      run = sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0182")

      shards = get_repository.dig("latest_run", "shards")

      expect(shards.values_at("count", "timed_count")).to all(be_a(Integer))
      # Asserted one at a time: `not_to include(a, b)` negates "includes BOTH", so it would pass
      # on a body carrying one of the two sentences.
      expect(shards.to_json).not_to include(run.machine_seconds_coverage)
      expect(shards.to_json).not_to include(run.wall_clock_coverage)
      expect(shards.to_json).not_to match(/[a-z]{3,} of /)
    end

    # AC3. `null` is not `0.0`, and this is the composition where the difference bites hardest: a
    # four-shard run where nothing reported still ran, and serializing its cost as a measured zero
    # would be the endpoint asserting the suite was free.
    it "keeps machine_seconds null, not zero, when no shard reported a timing" do
      sharded_run([nil, nil, nil, nil], commit_sha: "feedfacecafe0183")

      block = get_repository["latest_run"]

      expect(block["duration_seconds"]).to be_nil
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 0,
        "machine_seconds" => nil,
        "coverage" => { "duration_seconds" => 0, "machine_seconds" => 0 },
        # The composition that makes the gate a CORRECTNESS requirement rather than only an honesty
        # one. `duration_seconds` is nil here, and `TestRun#wall_clock_excess_seconds` subtracts
        # from it unguarded — so a serializer that computed these three keys before checking
        # `wall_clock_decomposable?` would not serve a wrong number, it would raise and 500 the
        # whole endpoint for every client reading this run.
        "rows" => nil,
        "balanced_wall_clock_seconds" => nil,
        "wall_clock_excess_seconds" => nil,
        # Every row still served, every duration still null. A run that reported no timings still
        # reported its SIZE, and those counts are the one half of the cost picture that survived —
        # zeroing the durations here would be the same assertion-that-the-suite-was-free the
        # `machine_seconds` null refuses one line up. This is the fixture where the two lists are
        # furthest apart: `rows` is withheld to avoid raising, and `per_shard` still answers.
        "per_shard" => [
          { "shard_id" => "1", "duration_seconds" => nil, "total_specs" => 5000 },
          { "shard_id" => "2", "duration_seconds" => nil, "total_specs" => 5000 },
          { "shard_id" => "3", "duration_seconds" => nil, "total_specs" => 5000 },
          { "shard_id" => "4", "duration_seconds" => nil, "total_specs" => 5000 }
        ]
      )
    end

    # The decomposition itself: WHICH shard, not just how many.
    #
    # Everything above this point can tell a client a run was assembled from four parts and cost
    # 253.75s between them without ever naming the part it waited on. `repositories#show` has
    # rendered the rows, the floor and the excess since SPGD-192; these examples are the assertion
    # that the API and that panel cannot drift apart about which shard was longest.
    describe "the per-shard decomposition behind wall_clock_decomposable?" do
      # The gate this whole block turns on, asserted POSITIVELY and first. Without it every example
      # below would pass just as well against a serializer that hard-coded three nulls — the shards
      # are created inline, so the default fixture is un-settled and the honest answer to all three
      # keys really is `null`. This is the example that says the fixture got past the gate.
      it "reaches the gate only once its shards have stopped arriving" do
        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0190")
        expect(repository.latest_test_run).not_to be_wall_clock_decomposable
        expect(repository.latest_test_run).to be_wall_clock_decomposition_pending

        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0191", settled: true)
        expect(repository.latest_test_run).to be_wall_clock_decomposable
      end

      # The head of the list is the load-bearing row: it is the shard the run's `duration_seconds`
      # MAX came from, and it is the one the panel names in prose. Compared against
      # `longest_shard_label` rather than against `"3"`, because a hard-coded name would still pass
      # if the API sorted its own way and happened to agree on this fixture — the property is that
      # the two orderings are the SAME ordering, not that they coincide once.
      it "names which shard the run waited on, slowest first, in the panel's own order" do
        run = sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0192", settled: true)
        shown = repository.latest_test_run
        expect(shown).to be_wall_clock_decomposable

        rows = get_repository.dig("latest_run", "shards", "rows")

        expect(rows.length).to eq(4)
        expect(rows.map { it["duration_seconds"] }).to eq([74.25, 61.0, 60.0, 58.5])
        # The same shard the panel calls the longest, read off the panel's own accessor.
        expect(shown.shard_label(rows.first["shard_id"])).to eq(shown.longest_shard_label)
        expect(rows.map { it["shard_id"] }).to eq(run.shard_durations.map(&:first))
      end

      # AC: the floor and the excess are the figures behind `balanced_wall_clock_label` /
      # `wall_clock_excess_label`. Read off the accessors, not restated as fixture arithmetic —
      # the precedent the "reports the same cost figures repositories#show renders" example above
      # sets, and for the same reason: `63.4375` written out here would still pass if the endpoint
      # divided a different SUM by a different count.
      it "reports the floor and the excess repositories#show renders for the same run" do
        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0193", settled: true)

        shown = repository.latest_test_run
        shards = get_repository.dig("latest_run", "shards")

        expect(shards["balanced_wall_clock_seconds"]).to eq(shown.balanced_wall_clock_seconds)
        expect(shards["wall_clock_excess_seconds"]).to eq(shown.wall_clock_excess_seconds)
        # Both non-trivial on this fixture, so an endpoint serving zeros could not pass the pair
        # above by accident: 253.75/4 is a floor the 74.25s wait sits well clear of.
        expect(shards["balanced_wall_clock_seconds"]).to be > 0
        expect(shards["wall_clock_excess_seconds"]).to be > 0
      end

      # Raw floats, not the panel's prose — the rule `duration_seconds` and `machine_seconds`
      # already follow here, extended to the keys that are likeliest to break it, since the model
      # side of this decomposition exposes `shard_distribution_labels` and `balanced_wall_clock_label`
      # that a serializer could reach for by name.
      it "serves the decomposition as numbers, not as the panel's labels" do
        run = sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0194", settled: true)

        shards = get_repository.dig("latest_run", "shards")

        expect(shards["balanced_wall_clock_seconds"]).to be_a(Float)
        expect(shards["wall_clock_excess_seconds"]).to be_a(Float)
        expect(shards["rows"].map { it["duration_seconds"] }).to all(be_a(Float))
        # Asserted one at a time, on the note the coverage example above leaves: `not_to include(a,
        # b)` negates "includes BOTH", so it would pass on a body carrying one of the two labels.
        expect(shards.to_json).not_to include(run.balanced_wall_clock_label)
        expect(shards.to_json).not_to include(run.wall_clock_excess_label)
        # Every label the panel renders for these shards, not just the duration one. SPGD-230 added
        # a size and a per-test-cost label to this same tuple, and an endpoint that served either
        # as prose would fail this example's own title while satisfying a duration-only check.
        # `compact` because the rate label is nil on a shard with no denominator.
        run.shard_distribution_labels.each do |labels|
          labels.compact.each { |label| expect(shards.to_json).not_to include(label) }
        end
        # And no prose shard names either: `shard_label` formatting stays view-side.
        expect(shards["rows"].map { it["shard_id"] }).to eq(%w[3 1 4 2])
        expect(shards.to_json).not_to include("shard 3")
      end

      # The untimed condition, ISOLATED. The example above in this file that covers an untimed
      # shard has an un-settled fixture too, so it cannot tell which of the two conditions did the
      # work. This one settles the rows, leaving `!some_shard_untimed?` as the only thing standing
      # between the request and a decomposition — and it is the composition where an ungated
      # `rows` is actively misleading rather than merely early: `duration_seconds: :desc` is NULLS
      # FIRST in Postgres, so the shard that reported NOTHING would head a list whose contract is
      # "slowest first".
      it "withholds all three keys when a shard reported no timing, even once delivery settled" do
        sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0195", settled: true)
        shown = repository.latest_test_run
        expect(shown).to be_shard_delivery_settled
        expect(shown).not_to be_wall_clock_decomposable

        shards = get_repository.dig("latest_run", "shards")

        expect(shards).to include("rows" => nil, "balanced_wall_clock_seconds" => nil,
                                  "wall_clock_excess_seconds" => nil)
        # The keys are PRESENT and null, not absent: a client tests one thing.
        expect(shards.keys).to include("rows", "balanced_wall_clock_seconds",
                                       "wall_clock_excess_seconds")
        # And the four that were always here are untouched by the gate.
        expect(shards.values_at("count", "timed_count", "machine_seconds")).to eq([4, 3, 179.5])
      end

      # The settling condition, ISOLATED — every shard present is timed, so a two-condition gate
      # would wave this run straight through with a partial SUM over a partial count. That is the
      # state `Repository#latest_test_run` puts every sharded run in for the first minutes of its
      # own delivery, which makes it the common case rather than the edge one.
      it "withholds all three keys while the shards are still arriving" do
        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0196")
        shown = repository.latest_test_run
        expect(shown).not_to be_some_shard_untimed
        expect(shown).to be_wall_clock_decomposition_pending

        shards = get_repository.dig("latest_run", "shards")

        expect(shards).to include("rows" => nil, "balanced_wall_clock_seconds" => nil,
                                  "wall_clock_excess_seconds" => nil)
        # The API withholds exactly where the panel does, and not one figure further: the four
        # keys that never depended on the decomposition are still served.
        expect(shards.values_at("count", "timed_count", "machine_seconds")).to eq([4, 4, 253.75])
      end

      # `shard_id` is nullable and a nil one is an ordinary state — `Ingest::RunRecorder#upsert_shard`
      # says a client that shards without exposing an index the gem recognises sends nothing to tell
      # its slices apart. Serving `null` rather than a position number is the whole point: "shard 2"
      # is unactionable advice when nothing in CI is called shard 2, and it would name a different
      # slice on the next run.
      it "serves an unnamed shard's id as null, never as its position in the list" do
        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0197", settled: true,
                                               shard_ids: ["1", nil, "3", "4"])

        rows = get_repository.dig("latest_run", "shards", "rows")

        expect(rows.length).to eq(4)
        expect(rows.map { it["shard_id"] }).to eq(["3", "1", "4", nil])
        # The unnamed row is served, with its timing, and is not dropped or renumbered.
        unnamed = rows.find { it["shard_id"].nil? }
        expect(unnamed["duration_seconds"]).to eq(58.5)
      end
    end
  end

  # AC4. One shard's MAX *is* its SUM, so there is no composition to disambiguate and no second
  # figure to print — the run is served exactly as it always was, with the key present and null.
  # `multi_shard?` and not `shard_count.positive?` is the gate for precisely this row.
  describe "a run assembled from a single shard" do
    it "reports no shard block, because its wall clock and its machine time are one number" do
      run = repository.test_runs.create!(commit_sha: "oneshard0000", ci_run_id: "gha-oneshard",
                                         total_specs_count: 5000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: "1", total_specs_count: 5000, duration_seconds: 61.0)

      block = get_repository["latest_run"]

      expect(run.machine_seconds).to eq(run.duration_seconds)
      expect(block).to have_key("shards")
      expect(block["shards"]).to be_nil
      expect(block["duration_seconds"]).to eq(61.0)
    end
  end

  # The agent half of "how did the suite grow". Without it the only way to answer is to poll this
  # endpoint and subtract one poll from the next — the subtraction `TestRun#assembled_like?`
  # and `#suite_size_measured?` exist to forbid.
  describe "the history array" do
    # Three runs, deliberately NOT all on one branch: `Repository#recent_test_runs` is the
    # interleaved history across every branch, and a fixture that used one branch throughout would
    # let a branch-filtered serializer pass while claiming to serve the whole history.
    def three_runs
      first = create_test_run(repository: repository, commit_sha: "run1aaaaaaaa", branch: "main",
                              total_specs_count: 30, annotated_specs_count: 6, duration_seconds: 10.0)
      second = create_test_run(repository: repository, commit_sha: "run2bbbbbbbb", branch: "feature-x",
                               total_specs_count: 12, annotated_specs_count: 3, duration_seconds: 4.0)
      third = create_test_run(repository: repository, commit_sha: "run3cccccccc", branch: "main",
                              total_specs_count: 40, annotated_specs_count: 10, duration_seconds: 42.5)
      [first, second, third]
    end

    # A sharded history row, written directly in the shape the `latest_run` block's own
    # `sharded_run` helper uses — the recorder is exercised in the ingest spec, and the question
    # here is only what the serializer does with the rows it leaves behind.
    #
    # `nil` is an ordinary member of `durations`, not an error case: `test_run_shards.duration_seconds`
    # is nullable and `Ingest::Payload` accepts a shard that reports no timing, so a silent shard is
    # the live state these rows exist to describe. The run's own `duration_seconds` defaults to the
    # MAX over the shards that REPORTED — which is exactly what the recorder stores and exactly the
    # figure whose denominator is at issue — and is overridable for the row that reports a wall
    # clock its shards no longer account for.
    def sharded_history_run(commit_sha, durations, duration_seconds: :max)
      run = repository.test_runs.create!(
        commit_sha: commit_sha, branch: "main", ci_run_id: "gha-#{commit_sha}",
        total_specs_count: 20_000, annotated_specs_count: 5000,
        duration_seconds: duration_seconds == :max ? durations.compact.max : duration_seconds
      )
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    annotated_specs_count: 1250, duration_seconds: seconds)
      end
      run
    end

    it "serves every row newest first, with the figures a client needs to difference them" do
      _first, _second, third = three_runs

      body = get_repository

      expect(body["history"].map { |row| row["commit_sha"] })
        .to eq(%w[run3cccccccc run2bbbbbbbb run1aaaaaaaa])
      expect(body["history"].first).to eq(
        "commit_sha" => "run3cccccccc",
        "branch" => "main",
        "total_specs" => 40,
        "annotated_specs" => 10,
        # The 0–1 fraction `/ingest` reports, never the 0–100 percentage the dashboard renders.
        # The 100× gap between the two is invisible in a JSON body.
        "annotated_ratio" => 0.25,
        "duration_seconds" => 42.5,
        # Zero, not null: this run named no `ci_run_id`, and "reported in one piece" is a fact
        # about its composition rather than a missing measurement.
        "shard_count" => 0,
        # Zero on the same rule, and unchanged in meaning for a run with no parts: there were none
        # to time. `duration_seconds` above is this run's own reported wall clock, not a MAX over
        # anything, so the denominator a client reads here is the count of shards that is also zero.
        "timed_shard_count" => 0,
        "suite_size_measured" => true,
        "ingested_at" => third.created_at.iso8601
      )
    end

    # The defect this ticket exists to not re-create: the human panel warns in a caption that
    # consecutive rows are routinely two branches and "are not a series". A machine client cannot
    # read a caption, so the same fact has to be structural — per-row `branch`, plus a scope marker
    # on the window that says the array was never filtered to one.
    #
    # The window is asserted whole rather than key by key: this block's whole job is to be the
    # contract, so a key that quietly stopped being served would be a client reading an ordering
    # promise that is no longer made.
    #
    # UPDATED DELIBERATELY when `?branch=` shipped, and `"branch" => nil` is the added key. It is
    # served in every response rather than only in narrowed ones, on the key-always-present rule
    # `latest_run.shards` already follows here — a client tests one thing (`branch == null` → "not
    # narrowed") instead of distinguishing an absent key from a null one. The whole-hash `eq` is
    # kept rather than relaxed to `include(...)`: relaxing it is how the next added key ships
    # unnoticed, which is the exact failure this example was written against. Every other key's
    # value is unchanged, which is the compatibility claim — `branch_scope` is still
    # `"all_branches"` and `limit` is still `10` for a request that named no branch.
    it "carries each row's own branch, and says on the window that it interleaves them" do
      three_runs

      body = get_repository

      expect(body["history"].map { |row| row["branch"] }).to eq(%w[main feature-x main])
      expect(body["history_window"]).to eq(
        # BOTH ordering keys, because the second one decides the same-instant pair below and a
        # client that read `ingested_at_desc` alone would re-sort straight through it.
        "order" => "ingested_at_desc,ingest_sequence_desc",
        "tie_break_served" => false,
        "branch_scope" => "all_branches",
        "branch" => nil,
        "limit" => 10,
        "returned" => 3
      )
    end

    # The claim `tie_break_served: false` makes, pinned rather than left as a literal nobody checks:
    # the rows genuinely do not carry the second ordering key, so the order cannot be reproduced
    # from what the client holds and the array's own order is the answer. If a later slice serves an
    # id or an ingest sequence on a row, this fails and the token has to be re-decided rather than
    # silently becoming a lie.
    it "serves no second ordering key on a row, which is what makes the array order authoritative" do
      first, _second, _third = three_runs

      row = get_repository["history"].last

      expect(row["commit_sha"]).to eq(first.commit_sha)
      # Asserted on the KEYS, and bidirectionally: a served id or ingest sequence needs a key, and
      # `contain_exactly` fails on any key not in this list. Checking the VALUES for the row's id
      # instead would read as the stronger assertion and be a weaker one — `test_runs.id` is a
      # bigint from a sequence Postgres does not roll back between examples, so it eventually
      # collides with this fixture's `total_specs` (30) or `annotated_specs` (6) and goes red on an
      # untouched serializer, under a name that blames the serializer for leaking an id.
      # `not_to include("id", "ingest_sequence")` is no better: it negates "includes BOTH", so it
      # passes on a row serving one of them — the same trap the shards example flags one describe
      # block up. `ingested_at` is the only ordering key served, and it is the one that ties.
      expect(row.keys).to contain_exactly(
        "commit_sha", "branch", "total_specs", "annotated_specs", "annotated_ratio",
        "duration_seconds", "shard_count", "timed_shard_count", "suite_size_measured", "ingested_at"
      )
    end

    # AC. Every figure re-derived straight from the table, in the ordering the model documents —
    # so the assertion cannot pass by reading the same Ruby the serializer read.
    it "matches direct SQL over the same rows" do
      three_runs

      sql = <<~SQL.squish
        SELECT commit_sha, branch, total_specs_count, annotated_specs_count, duration_seconds
        FROM test_runs WHERE repository_id = $1
        ORDER BY created_at DESC, id DESC LIMIT 10
      SQL
      rows = ActiveRecord::Base.connection.select_all(sql, "history cross-check", [repository.id]).to_a
      # Guards the comparison below against passing on two empty arrays — an empty `history` and an
      # empty result set answer identically, which is the vacuous shape this project keeps shipping.
      expect(rows.length).to eq(3)
      expect(get_repository["history"].map do |row|
        row.values_at("commit_sha", "branch", "total_specs", "annotated_specs", "duration_seconds")
      end).to eq(rows.map do |row|
        row.values_at("commit_sha", "branch", "total_specs_count", "annotated_specs_count",
                      "duration_seconds").tap { |values| values[4] = values[4]&.to_f }
      end)
    end

    # A run that reported zero tests has a count but not a measurement, so a difference taken
    # against it describes the report and not the suite. The boolean is what lets a client refuse
    # that subtraction without re-deriving the rule.
    it "flags a run that reported no tests as not a measurement of the suite" do
      create_test_run(repository: repository, commit_sha: "emptyrun0000", branch: "main",
                      total_specs_count: 0, annotated_specs_count: 0)

      row = get_repository["history"].first

      expect(row["total_specs"]).to eq(0)
      expect(row["suite_size_measured"]).to be(false)
      # Null rather than 0.0, on the endpoint's established rule: there was nothing to take a
      # share of, which is not a measured zero share.
      expect(row["annotated_ratio"]).to be_nil
    end

    # The other composition fact. `TestRun#assembled_like?` decides whether two runs may be
    # differenced on shard-count equality alone, so serving the count is serving exactly what that
    # rule reads — a client can apply it without the endpoint applying it for them.
    it "reports how many shards each row was assembled from" do
      one_piece = create_test_run(repository: repository, commit_sha: "onepiece0000", total_specs_count: 20)
      sharded = repository.test_runs.create!(commit_sha: "sharded00000", ci_run_id: "gha-sharded",
                                             total_specs_count: 20_000, duration_seconds: 74.25)
      3.times { |index| sharded.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000) }

      rows = get_repository["history"].index_by { |row| row["commit_sha"] }

      expect(rows.fetch(sharded.commit_sha)["shard_count"]).to eq(3)
      expect(rows.fetch(one_piece.commit_sha)["shard_count"]).to eq(0)
    end

    # THE ROW'S `duration_seconds` HAS A DENOMINATOR, AND IT IS NOT `shard_count`. On a sharded run
    # the wall clock is the MAX over the shards that REPORTED, so a row serving the numerator beside
    # the recorded-shard count states a coverage the figure does not have — the same honesty gap
    # `latest_run.shards.coverage` exists to close, on rows that SPGD-211 turned into a series whose
    # stated purpose is differencing.
    #
    # The two runs here are `assembled_like?` — identical `shard_count`, identical
    # `suite_size_measured` — and are opposite operational facts: one measured its wall clock over
    # every shard, the other over half of them, AND THE TWO IT LOST WERE THE SLOWEST, because a
    # cancelled or timed-out job usually is. Differencing them on `duration_seconds` alone reports a
    # 70% speedup that is entirely telemetry loss. `timed_shard_count` is the only field on either
    # row that can tell them apart.
    it "distinguishes a fully-timed row from a half-silent one that is otherwise identical" do
      timed = sharded_history_run("alltimed0000", [150.0, 300.0, 450.0, 600.0])
      silent = sharded_history_run("halfsilent00", [150.0, 180.0, nil, nil])

      rows = get_repository["history"].index_by { |row| row["commit_sha"] }
      timed_row = rows.fetch(timed.commit_sha)
      silent_row = rows.fetch(silent.commit_sha)

      # Indistinguishable on every other axis — this is what makes the new field load-bearing
      # rather than decorative.
      expect(silent_row.values_at("shard_count", "suite_size_measured")).to eq([4, true])
      expect(timed_row.values_at("shard_count", "suite_size_measured")).to eq([4, true])
      # The 70% "speedup": 600s of wall clock against 180s, from the same four-shard suite.
      expect(timed_row["duration_seconds"]).to eq(600.0)
      expect(silent_row["duration_seconds"]).to eq(180.0)
      # And the fact that undoes it, read off each row alone with no reference to `latest_run`.
      expect(timed_row["timed_shard_count"]).to eq(4)
      expect(silent_row["timed_shard_count"]).to eq(2)
    end

    # The state the endpoint's own fixtures were already sitting in, green, because nothing asserted
    # on it: three shards recorded, not one of them timed. `test_run_shards.duration_seconds` is
    # nullable and `Ingest::Payload` accepts a shard with no timing, so this is an ordinary live
    # state and not a fault — `TestRun#wall_clock_coverage` words it "0 of 3 reported" for the human
    # panel.
    #
    # `0` and not absent, null, or `3`: a run whose `duration_seconds` was measured over nothing is
    # exactly the row a client most needs to refuse to difference, and each of the three wrong
    # answers hides that in a different way — absent and null read as "the endpoint does not say",
    # `3` reads as full coverage.
    it "reports zero timed shards for a run that recorded shards and timed none of them" do
      run = sharded_history_run("nonetimed000", [nil, nil, nil], duration_seconds: 74.25)

      row = get_repository["history"].find { |candidate| candidate["commit_sha"] == run.commit_sha }

      expect(run.wall_clock_coverage).to eq("0 of 3 reported")
      expect(row).to include("shard_count" => 3, "duration_seconds" => 74.25)
      expect(row["timed_shard_count"]).to eq(0)
      # Not merely falsy: `nil` and `false` both pass a `be_falsey` here, and `nil` is one of the
      # three wrong answers.
      expect(row["timed_shard_count"]).to be_an(Integer)
    end

    # A run with no shard rows at all is absent from the grouped aggregate entirely, so its primed
    # value is the one place a nil placeholder could reach the body. It serves the same really-
    # counted `0` its `shard_count` does: there were no parts, so there were none to time. This is
    # the whole unsharded corpus — every laptop `bundle exec rspec` — and its meaning is unchanged.
    it "serves a really-counted zero for a shardless run rather than a nil placeholder" do
      run = create_test_run(repository: repository, commit_sha: "onepiece0000",
                            total_specs_count: 20, duration_seconds: 42.5)

      row = get_repository["history"].find { |candidate| candidate["commit_sha"] == run.commit_sha }

      expect(row["duration_seconds"]).to eq(42.5)
      expect(row).to include("shard_count" => 0, "timed_shard_count" => 0)
    end

    # Read off the model accessor rather than the fixture's arithmetic, on the same rule the
    # `latest_run` cost example follows: restating the count here would still pass if the preload
    # primed a number counted over a different set of rows than `TestRun#timed_shard_count` reads.
    # This is what pins the PRIMED value to the queried one — the preload's whole risk is that it
    # answers fast and wrong.
    it "primes each row's timed count to what the model itself counts" do
      run = sharded_history_run("agreement000", [61.0, 58.5, nil, 60.0])

      row = get_repository["history"].find { |candidate| candidate["commit_sha"] == run.commit_sha }

      expect(run.reload.timed_shard_count).to eq(3)
      expect(row["timed_shard_count"]).to eq(run.timed_shard_count)
      expect(row["shard_count"]).to eq(run.shard_count)
    end

    # Ten rows is ten rows whether the suite holds three tests or twenty thousand. The window
    # states the bound so a client reading a full array does not conclude the suite has run exactly
    # ten times — `returned == limit` is how it learns there is more behind it.
    it "stops at ten rows and says so rather than letting a client infer the history is complete" do
      12.times { |index| create_test_run(repository: repository, commit_sha: "bounded%06d" % index) }

      body = get_repository

      expect(repository.test_runs.count).to eq(12)
      expect(body["history"].length).to eq(10)
      expect(body["history_window"]["limit"]).to eq(10)
      expect(body["history_window"]["returned"]).to eq(10)
    end

    # `[]` and not `null` — the one place this slice departs from the `latest_run`/`shards`
    # null-means-absent rule. An empty *list* is not the lie a zeroed *block* would be: "no runs"
    # is exactly what zero rows means, and a client can iterate it without branching first.
    it "serves an empty array for a repository whose CI has never reported, while latest_run stays null" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
      expect(body["history"]).to eq([])
      expect(body["history_window"]["returned"]).to eq(0)
    end

    # `history` is added BESIDE the existing blocks, on the rule the shards slice followed — a
    # client reading this endpoint today reads the same keys, types and values tomorrow.
    it "leaves latest_run, shards and api_key exactly where they were" do
      _first, _second, third = three_runs

      body = get_repository

      expect(body["latest_run"]).to eq(
        "commit_sha" => third.commit_sha, "branch" => "main", "total_specs" => 40,
        "annotated_specs" => 10, "annotated_ratio" => 0.25, "duration_seconds" => 42.5,
        "shards" => nil, "suite_size_measured" => true,
        "ingested_at" => third.created_at.iso8601
      )
      expect(body["api_key"]).to have_key("last_used_at")
    end
  end

  # `?branch=` — asking the history for ONE branch's series.
  #
  # The block above serves the interleaved history and tells the client, in `branch_scope`, that it
  # must filter to get a series. It could not: the bound is applied before the client sees anything,
  # so `history.select { it["branch"] == "main" }` filters a window that may contain no `main` rows
  # at all while `main` holds dozens in the same table. Every example here is written so that the
  # unfiltered window CANNOT answer the question — see `branch_starved_repository`.
  describe "narrowing the history with ?branch=" do
    # The fixture the whole slice turns on, and its shape is the assertion. Twenty-five `main` runs
    # FIRST, then thirty `feature/*` runs, so:
    #
    #   * the ten newest runs repository-wide are all `feature/*` — the unfiltered window, bounded
    #     at ten, contains ZERO `main` rows, and client-side filtering of it returns `[]`;
    #   * the THIRTY newest are all `feature/*` too, which starves the deeper bound as well: an
    #     implementation that bounded at thirty and then filtered in Ruby also returns `[]`;
    #   * `main` has twenty-five runs — more than the unfiltered bound and fewer than the branch
    #     bound, so the correct count is neither limit and cannot be produced by truncation.
    #
    # Both starvation depths are deliberate, and the second was learned the hard way: a fixture
    # starved only at ten passes under a serializer that fetches thirty rows and filters the Array,
    # which is the same defect one bound further out. A fixture where `main` happened to fall inside
    # either window would pass with or without the predicate at all — the vacuous shape this project
    # keeps having to un-ship. Reverting `where(branch:)` in `Repository#recent_test_runs`, or
    # moving the filter out of the query and into Ruby, must turn these examples red; the two
    # examples immediately below state each starvation depth as its own expectation so the fixture
    # cannot silently drift into the harmless shape.
    def branch_starved_repository
      main_runs = Array.new(25) do |index|
        create_test_run(repository: repository, commit_sha: "main%08d" % index, branch: "main",
                        total_specs_count: 100 + index, annotated_specs_count: 25)
      end
      feature_runs = Array.new(30) do |index|
        create_test_run(repository: repository, commit_sha: "feat%08d" % index,
                        branch: "feature/extract-billing-#{index}",
                        total_specs_count: 7, annotated_specs_count: 1)
      end

      [main_runs, feature_runs]
    end

    # Used by the two examples below that compare one response against another response — and by
    # nothing else in this file. Both of those issue TWO real requests and assert the second is
    # identical to the first; `api_key.last_used_at` is the one field that is *supposed* to differ
    # between them, so it is the one field they exclude.
    #
    # Why it moves: every authenticated request bumps the key (`Api::BaseController` calls
    # `ApiKey#touch_last_used!`), and `Api::V1::RepositoriesController#show` serializes it with
    # argument-less `iso8601` — SECOND precision. So the value changes once per second no matter
    # how fast the two requests are, and any pair that straddles a second boundary disagrees on it.
    # That made this file randomly red (~1 in 5 full-file runs, never in isolation) on tickets that
    # touched none of this, for the endpoint behaving exactly as specified.
    #
    # The contract those examples assert is "a blank/filtered branch param changes nothing ELSE
    # about the payload". A field that advances because a second request genuinely happened was
    # never part of that contract, so asserting it was asserting something the endpoint does not
    # promise. Excluded here rather than the three fixes that look easier:
    #
    #   * `freeze_time` / `travel_to` — hides the exclusion at the call site, and would also
    #     suppress a genuine regression in `last_used_at` being bumped at all;
    #   * loosening `eq` to `include` / `match` — destroys the "changes NOTHING else" assertion
    #     that is the entire reason both examples exist;
    #   * widening the `iso8601` precision in `app/` — the serialization is a published API
    #     contract, and a spec's timing problem does not get fixed on the wire.
    #
    # Deliberately one named key off one block, not a general "drop the volatile stuff" scrub:
    # `api_key.name` and every other key in the payload stay under strict `eq`, so these examples
    # still go red for any other field that moves. Do not widen this, and do not restore the field.
    def except_last_used_at(body)
      body.merge("api_key" => body.fetch("api_key").except("last_used_at"))
    end

    it "sees the defect: the unfiltered window holds no main rows at all, so filtering it answers []" do
      branch_starved_repository

      body = get_repository

      expect(repository.test_runs.where(branch: "main").count).to eq(25)
      expect(body["history"].length).to eq(10)
      expect(body["history"].select { |row| row["branch"] == "main" }).to eq([])
    end

    # The same starvation one bound further out, pinned directly on the table rather than through
    # the endpoint — because no response exposes the thirty newest interleaved rows, and this is the
    # property that makes "bound first, filter the Array" indistinguishable from a broken filter.
    it "starves the deeper bound too: the 30 newest runs repository-wide are also all feature branches" do
      branch_starved_repository

      newest = repository.recent_test_runs(limit: Repository::TRAJECTORY_LIMIT).to_a

      expect(newest.length).to eq(Repository::TRAJECTORY_LIMIT)
      expect(newest.map(&:branch)).to all(start_with("feature/"))
    end

    # AC1. The same repository, the same instant, one query parameter — twenty-five `main` rows
    # where filtering either bounded window could only ever produce zero. Twenty-five is neither
    # limit, so the count cannot have come from truncating anything.
    it "returns only that branch's rows, and more of them than the unfiltered bound could hold" do
      main_runs, _feature_runs = branch_starved_repository

      body = get_repository(query: { branch: "main" })

      expect(response).to have_http_status(:ok)
      expect(body["history"].map { |row| row["branch"] }.uniq).to eq(["main"])
      expect(body["history"].length).to eq(25)
      expect(body["history"].length).to be > 10
      expect(body["history"].map { |row| row["commit_sha"] })
        .to eq(main_runs.reverse.map(&:commit_sha))
    end

    # AC2. Tokens a client compares, not a caption it parses. `branch_scope` takes a DISTINCT value
    # — a client that hard-coded `== "all_branches"` to mean "not a series" keeps being right — and
    # the branch name rides in its OWN key rather than interpolated into the token, so nobody has to
    # `start_with?("branch:")` their way back to the two facts.
    #
    # Whole-hash, for the same reason the unfiltered assertion is: this block is the contract.
    it "states the narrowed scope as comparable tokens, with the branch name in its own key" do
      branch_starved_repository

      expect(get_repository(query: { branch: "main" })["history_window"]).to eq(
        "order" => "ingested_at_desc,ingest_sequence_desc",
        "tie_break_served" => false,
        "branch_scope" => "single_branch",
        "branch" => "main",
        # AC2's second half: the bound ACTUALLY APPLIED, not the constant `10` the unfiltered
        # window reports. Twelve rows came back, which is only a coherent response if `limit` says
        # a deeper bound was in force — under `limit => 10` a client reading `returned` against it
        # would conclude the window overflowed its own bound.
        "limit" => 30,
        "returned" => 25
      )
    end

    it "reports the branch bound rather than the unfiltered one, and stops there" do
      Array.new(35) do |index|
        create_test_run(repository: repository, commit_sha: "deep%08d" % index, branch: "main")
      end

      body = get_repository(query: { branch: "main" })

      expect(repository.test_runs.where(branch: "main").count).to eq(35)
      expect(body["history"].length).to eq(30)
      expect(body["history_window"]).to include("limit" => 30, "returned" => 30)
      # The bound is the model's, read off the constant rather than restated — so the API's series
      # and the dashboard's chart cannot drift apart on how far back "the history" reaches.
      expect(body["history_window"]["limit"]).to eq(Repository::TRAJECTORY_LIMIT)
    end

    # AC3. The divergence from the human panel, stated as an expectation. The panel falls back to
    # its current anchor for a branch it does not recognise and renders a visible notice saying so;
    # a JSON client has no notice, so a substituted branch's rows would be a growth series computed
    # for the wrong branch with nothing in the body to detect it.
    it "answers an unknown branch with [], never another branch's rows" do
      branch_starved_repository

      body = get_repository(query: { branch: "release/does-not-exist" })

      expect(response).to have_http_status(:ok)
      expect(body["history"]).to eq([])
      expect(body["history_window"]).to include(
        "branch_scope" => "single_branch",
        # The ask restated, so a client can tell "that branch has no runs" from "your filter was
        # ignored" — two responses that would otherwise be one empty array.
        "branch" => "release/does-not-exist",
        "returned" => 0
      )
      # The half that matters. `[]` on its own would also be what a broken filter returns; what
      # must never happen is a NON-empty array of somebody else's rows.
      expect(body["history"]).not_to include(hash_including("branch" => "main"))
    end

    # AC4, first half. `?branch=` present but empty is "no filter" — it must not become
    # `WHERE branch = ''` (which matches nothing, and would make an empty param indistinguishable
    # from an unknown branch) and it must not become "give me the unfiltered window under a
    # narrowed scope token" either. It is byte-identical to sending no param at all.
    it "treats a blank branch as no filter, not as an empty branch name" do
      branch_starved_repository

      blank = get_repository(query: { branch: "" })
      absent = get_repository

      expect(except_last_used_at(blank)).to eq(except_last_used_at(absent))
      expect(blank["history_window"]).to include("branch_scope" => "all_branches", "branch" => nil,
                                                 "limit" => 10)
      expect(blank["history"].length).to eq(10)
    end

    # AC4, second half — the trap `Repository#previous_test_run_on_branch` and
    # `#suite_size_trajectory` both already guard, arriving here through a new door. `branch` is
    # nullable, `Ingest::Payload` writes `.presence`, and "SpecGuard does not know where this run
    # came from" is not a branch: `WHERE branch IS NULL` would pool every anonymous run from every
    # branch and every machine into one fictional history and serve it as a series.
    #
    # Asserted from BOTH sides, because either alone is passable by a broken guard: a blank param
    # must return the anonymous rows as part of the unfiltered history (not a NULL-scoped subset),
    # and no branch name may select them.
    it "leaves runs that reported no branch unselectable, and never pools them into a series" do
      anonymous = Array.new(3) do |index|
        create_test_run(repository: repository, commit_sha: "anon%08d" % index, branch: nil)
      end
      named = create_test_run(repository: repository, commit_sha: "named0000000", branch: "main")

      unfiltered = get_repository(query: { branch: "" })
      expect(unfiltered["history"].map { |row| row["commit_sha"] })
        .to contain_exactly(named.commit_sha, *anonymous.map(&:commit_sha))
      expect(unfiltered["history"].map { |row| row["branch"] }).to include(nil)

      # The named branch returns its own row and none of the anonymous ones.
      expect(get_repository(query: { branch: "main" })["history"].map { |row| row["commit_sha"] })
        .to eq([named.commit_sha])
    end

    # AC5. The three shapes a query string can legally parse into that are not a branch name are
    # listed ONCE, in `spec/support/shared_examples/malformed_branch_param.rb`, and the human
    # suite-trajectory panel runs the same list against the same guard
    # (`RequestedBranchParam#requested_branch`). What is local here is only how this surface SAYS
    # it dropped the ask: `branch => nil` and `branch_scope => "all_branches"` in the window, so the
    # response is not silently claiming to have honoured a request it ignored.
    describe "a branch parameter that is not a branch name" do
      def expect_branch_param_treated_as_no_ask(query)
        branch_starved_repository

        body = get_repository(query: query)

        expect(response).to have_http_status(:ok)
        expect(body["history_window"]).to include("branch_scope" => "all_branches", "branch" => nil,
                                                  "limit" => 10)
        expect(body["history"].length).to eq(10)
      end

      it_behaves_like "a surface that treats a malformed branch parameter as no ask"
    end

    # AC7. A client that filtered the history has not asked for a different latest run. Compared
    # against the SAME response's unfiltered twin rather than against restated fixture values, so
    # this cannot pass by both sides drifting together.
    #
    # `latest_run` is deliberately the `feature/*` run here while `history[0]` is a `main` row —
    # they differ, and that is the contract rather than a bug. Pinned explicitly below so a later
    # slice that "fixes" the mismatch by re-anchoring `latest_run` has to argue with this example.
    it "leaves latest_run, shards, api_key and repository exactly where they were" do
      _main_runs, feature_runs = branch_starved_repository

      filtered = get_repository(query: { branch: "main" })
      unfiltered = get_repository

      expect(except_last_used_at(filtered).values_at("repository", "api_key", "latest_run"))
        .to eq(except_last_used_at(unfiltered).values_at("repository", "api_key", "latest_run"))
      expect(filtered.dig("latest_run", "commit_sha")).to eq(feature_runs.last.commit_sha)
      expect(filtered.dig("latest_run", "branch")).to eq(feature_runs.last.branch)
      expect(filtered.dig("latest_run", "shards")).to be_nil
      # The mismatch, stated: the newest run on the repository is not the newest run on `main`.
      expect(filtered["history"].first["branch"]).to eq("main")
      expect(filtered.dig("latest_run", "branch")).not_to eq("main")
    end

    it "serves the same top-level keys, and the same row keys, under a branch param" do
      branch_starved_repository

      body = get_repository(query: { branch: "main" })

      expect(body.keys)
        .to contain_exactly("repository", "api_key", "latest_run", "history_window", "history",
                            "branches_window", "branches")
      expect(body["history"].first.keys).to contain_exactly(
        "commit_sha", "branch", "total_specs", "annotated_specs", "annotated_ratio",
        "duration_seconds", "shard_count", "timed_shard_count", "suite_size_measured", "ingested_at"
      )
    end

    # AC8. The rows are `recent_test_runs`' own ordering, tie-break included, and the branch
    # predicate rides along with it rather than being applied to a re-sorted result. Same-instant
    # rows are the only fixture that can tell the two apart: any distinctly-stamped fixture agrees
    # under both.
    it "keeps the created_at/id tie-break inside the narrowed window" do
      stamp = 2.hours.ago
      older = create_test_run(repository: repository, commit_sha: "tieold000000", branch: "main")
      newer = create_test_run(repository: repository, commit_sha: "tienew000000", branch: "main")
      [older, newer].each { |run| run.update_columns(created_at: stamp) }
      # A newer run on another branch, so the narrowed window is genuinely a filtered slice rather
      # than the whole table in disguise.
      create_test_run(repository: repository, commit_sha: "tieother0000", branch: "feature/x")

      body = get_repository(query: { branch: "main" })

      expect(body["history"].map { |row| row["commit_sha"] })
        .to eq([newer.commit_sha, older.commit_sha])
    end

    it "scopes the narrowed history to the key's own repository" do
      create_test_run(repository: repository, commit_sha: "ourmain00000", branch: "main")
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      create_test_run(repository: other, commit_sha: "theirmain000", branch: "main")

      expect(get_repository(query: { branch: "main" })["history"].map { |row| row["commit_sha"] })
        .to eq(["ourmain00000"])
    end

    # The rows a narrowed window serves are the same rows, assembled the same way — the composition
    # facts a client needs before differencing two of them are not a casualty of the filter.
    it "still primes each narrowed row's shard count" do
      create_test_run(repository: repository, commit_sha: "onepiece0000", branch: "main",
                      total_specs_count: 20)
      sharded = repository.test_runs.create!(commit_sha: "sharded00000", branch: "main",
                                             ci_run_id: "gha-sharded", total_specs_count: 20_000)
      3.times { |index| sharded.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000) }

      rows = get_repository(query: { branch: "main" })["history"].index_by { |row| row["commit_sha"] }

      expect(rows.fetch("sharded00000")["shard_count"]).to eq(3)
      expect(rows.fetch("onepiece0000")["shard_count"]).to eq(0)
    end

    # AC. Re-derived straight from the table, in the ordering and with the predicate the model
    # documents — so the assertion cannot pass by reading the same Ruby the serializer read.
    it "matches direct SQL over the same branch's rows" do
      branch_starved_repository

      sql = <<~SQL.squish
        SELECT commit_sha, branch, total_specs_count, annotated_specs_count
        FROM test_runs WHERE repository_id = $1 AND branch = $2
        ORDER BY created_at DESC, id DESC LIMIT 30
      SQL
      rows = ActiveRecord::Base.connection
                               .select_all(sql, "branch history cross-check", [repository.id, "main"]).to_a
      # Guards against the comparison passing on two empty arrays — the vacuous shape an empty
      # `history` and an empty result set answer identically.
      expect(rows.length).to eq(25)
      expect(get_repository(query: { branch: "main" })["history"].map do |row|
        row.values_at("commit_sha", "branch", "total_specs", "annotated_specs")
      end).to eq(rows.map do |row|
        row.values_at("commit_sha", "branch", "total_specs_count", "annotated_specs_count")
      end)
    end
  end

  # The half of `?branch=` that makes the other half reachable. Everything above assumes the client
  # already knows a branch name; nothing in the response told it one.
  describe "the branches catalogue" do
    # The fixture the whole slice turns on, and its shape is the assertion. Twelve `main` runs
    # FIRST, then ten `feature/*` runs, so the ten newest runs repository-wide are ALL non-`main`
    # and the unfiltered `history` — bounded at ten — carries no `main` row at all. That is the one
    # window an API client has, and `main` is exactly the name it does not contain.
    #
    # A fixture where `main` fell inside the newest ten could not observe the defect: `history`
    # would already carry the name, and the example would pass with or without a catalogue. Twelve
    # rather than ten `main` runs so the count served is neither bound and cannot have come from
    # truncating anything.
    def trunk_hidden_repository
      main_runs = Array.new(12) do |index|
        create_test_run(repository: repository, commit_sha: "main%08d" % index, branch: "main",
                        total_specs_count: 100 + index, annotated_specs_count: 25)
      end
      feature_runs = Array.new(10) do |index|
        create_test_run(repository: repository, commit_sha: "feat%08d" % index,
                        branch: "feature/extract-billing-#{index}",
                        total_specs_count: 7, annotated_specs_count: 1)
      end

      [main_runs, feature_runs]
    end

    it "sees the defect: the only window a client has holds no main row, so no response names it" do
      trunk_hidden_repository

      history = get_repository["history"]

      expect(repository.test_runs.where(branch: "main").count).to eq(12)
      expect(history.length).to eq(10)
      expect(history.map { |row| row["branch"] }).to all(start_with("feature/"))
    end

    # AC1. The same repository, the same instant, NO query parameter — and the name that appears
    # nowhere in `history` appears in `branches`, with the count that says why a client should care.
    # Removing the catalogue turns this red; nothing else in the body can answer it.
    it "names main, with its run count, on a repository whose whole history window hides it" do
      trunk_hidden_repository

      body = get_repository

      expect(body["history"].map { |row| row["branch"] }).not_to include("main")
      expect(body["branches"])
        .to include("name" => "main", "run_count" => 12, "run_count_capped" => false)
    end

    # AC1's second half, and it is the sibling panel's stated rule rather than a convenience: the
    # client that needs the catalogue most has not selected anything yet, so it cannot be a block
    # that appears only once you already selected something.
    it "serves the same catalogue whether or not a branch was asked for" do
      trunk_hidden_repository

      unfiltered = get_repository
      filtered = get_repository(query: { branch: "main" })
      unknown = get_repository(query: { branch: "release/does-not-exist" })

      expect(unfiltered["branches"]).to be_present
      expect(filtered["branches"]).to eq(unfiltered["branches"])
      expect(unknown["branches"]).to eq(unfiltered["branches"])
    end

    # AC2. The cap is a BOOLEAN BESIDE THE NUMBER, never the panel's `"30+"` caption. A client
    # comparing two branches' history must not have to strip a `+` before it can subtract, and a
    # count that stopped is a different fact from a count that finished — so both are served and
    # neither is spelled into the other.
    it "serves a stopped count as a number and a flag, not as the panel's 30+ string" do
      Array.new(35) do |index|
        create_test_run(repository: repository, commit_sha: "deep%08d" % index, branch: "main")
      end
      create_test_run(repository: repository, commit_sha: "shallow00000", branch: "feature/small")

      rows = get_repository["branches"].index_by { |row| row["name"] }

      expect(repository.test_runs.where(branch: "main").count).to eq(35)
      expect(rows.fetch("main"))
        .to eq("name" => "main", "run_count" => 30, "run_count_capped" => true)
      expect(rows.fetch("main")["run_count"]).to eq(Repository::TRAJECTORY_LIMIT)
      # The branch that finished counting says so, so `run_count_capped` is a fact about the row
      # rather than a constant the block always carries.
      expect(rows.fetch("feature/small"))
        .to eq("name" => "feature/small", "run_count" => 1, "run_count_capped" => false)
      # No figure anywhere in the block is a rendered string — the caption lives on the dashboard.
      expect(rows.values.flat_map(&:values).grep(String)).to all(satisfy { |v| !v.include?("+") })
    end

    # AC3. The walk's bound, as tokens. Whole-hash, because this block IS the contract — a key
    # added without a line in docs/DEVELOPMENT.md fails here, and a documented key dropped fails
    # here too.
    it "states the walk's bound and its own ordering as tokens, not as the helper's prose" do
      trunk_hidden_repository

      expect(get_repository["branches_window"]).to eq(
        "order" => "run_count_desc,last_run_at_desc,name_asc",
        # The middle ordering key is not a field on a row, so the array's own order is the answer
        # rather than a rendering of one — the same admission `history_window` makes.
        "tie_break_served" => false,
        "run_count_limit" => 30,
        "walk_limit" => 500,
        "walk_cut" => false,
        "returned" => 11
      )
      # Read off the model's constants rather than restated, so the response cannot come to claim a
      # bound the walk did not apply.
      expect(get_repository.dig("branches_window", "walk_limit"))
        .to eq(Repository::BRANCH_HISTORY_LIMIT)
      expect(get_repository.dig("branches_window", "run_count_limit"))
        .to eq(Repository::TRAJECTORY_LIMIT)
    end

    # AC3's load-bearing half, and the reason a bare list would be a lie past the bound. The walk is
    # NAME-ORDERED, so a repository with more branches than it walks hands the history sort an
    # alphabetical PREFIX — here `main` has a hundred runs and is not in the catalogue at all,
    # because `feature/churn-*` fills the first five hundred names. Without `walk_cut` a client
    # would read "`main` is absent" as "`main` has no runs", which is the exact inversion the
    # ordering exists to prevent.
    #
    # `insert_all!` so the fixture costs one statement rather than three thousand.
    it "says the walk stopped, on the repository where the trunk is missing because it did" do
      now = Time.current
      TestRun.insert_all!(Array.new(3000) do |index|
        { repository_id: repository.id, commit_sha: "planned%09d" % index,
          branch: (index % 30).zero? ? "main" : "feature/churn-#{index}",
          total_specs_count: 10, annotated_specs_count: 1,
          created_at: now - index.minutes, updated_at: now - index.minutes }
      end)

      body = get_repository

      expect(repository.test_runs.where(branch: "main").count).to eq(100)
      expect(body["branches"].length).to eq(Repository::BRANCH_HISTORY_LIMIT)
      # The claim this flag has to carry: `main` really is absent, and it really does have runs.
      expect(body["branches"].map { |row| row["name"] }).not_to include("main")
      expect(body["branches_window"]).to include("walk_cut" => true, "returned" => 500)
    end

    # AC3's derivation, pinned as its own example because `>=` and `==` agree on every fixture but
    # this one. A pinned branch is UNIONed into the walk's result, so a cut walk can hand back MORE
    # rows than its own bound: 501 branches, the walk takes the alphabetically-first 500
    # (`feature/000`…`feature/499`), and `?branch=feature/500` pins the one it did not reach.
    # `returned` is then 501 and a `==` derivation would report a cut walk as complete — which is
    # `RepositoriesHelper#trajectory_walk_cut?`'s stated reason for `>=`.
    it "still reports a cut walk when a pinned branch pushed the row count past the bound" do
      now = Time.current
      TestRun.insert_all!(Array.new(501) do |index|
        { repository_id: repository.id, commit_sha: "pinned%09d" % index,
          branch: "feature/%03d" % index, total_specs_count: 10, annotated_specs_count: 1,
          created_at: now - index.minutes, updated_at: now - index.minutes }
      end)

      body = get_repository(query: { branch: "feature/500" })

      expect(body["branches_window"]).to include("returned" => 501, "walk_cut" => true)
      expect(body["branches_window"]["returned"])
        .to be > body["branches_window"]["walk_limit"]
      # AC8. The pinned branch is the one the client filtered on, so the response that narrowed the
      # history can also name the branch it narrowed to — one body that does not contradict itself.
      expect(body["branches"].map { |row| row["name"] }).to include("feature/500")
      expect(body["history"].map { |row| row["branch"] }.uniq).to eq(["feature/500"])
    end

    # AC8's other half: pinning cannot invent a branch. A pinned name with no runs behind it drops
    # out with every other empty one, which is the same answer `history` gives it.
    it "does not invent a branch for a ?branch= that has no runs" do
      trunk_hidden_repository

      body = get_repository(query: { branch: "release/does-not-exist" })

      expect(body["history"]).to eq([])
      expect(body["branches"].map { |row| row["name"] }).not_to include("release/does-not-exist")
    end

    # AC4. `RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES` is about what a row of links can carry
    # before it stops being a way to find a branch. A JSON array has no such limit, and a display
    # bound leaking into a machine response would drop branches for a reason that does not apply.
    it "serves every branch the walk reached, not the eight a row of links can hold" do
      trunk_hidden_repository

      names = get_repository["branches"].map { |row| row["name"] }

      expect(RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES).to eq(8)
      expect(names.length).to eq(11)
      expect(names.length).to be > RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES
    end

    # AC5. `branch` is nullable and ingest accepts a body without it, so `null` means "the client
    # did not say" — a different fact from any branch name. The anonymous runs of every machine are
    # not one branch, and offering them a name here would offer a name `?branch=` refuses to match.
    it "leaves runs that reported no branch out of the catalogue entirely" do
      Array.new(5) { |index| create_test_run(repository: repository, commit_sha: "anon%08d" % index) }
      create_test_run(repository: repository, commit_sha: "named0000000", branch: "main")

      body = get_repository

      expect(repository.test_runs.where(branch: nil).count).to eq(5)
      expect(body["branches"]).to eq([{ "name" => "main", "run_count" => 1,
                                        "run_count_capped" => false }])
      expect(body["branches_window"]).to include("returned" => 1)
    end

    it "serves an empty catalogue, never null, for a repository whose CI has never reported" do
      body = get_repository

      expect(body["branches"]).to eq([])
      expect(body["branches_window"]).to include("returned" => 0, "walk_cut" => false)
      expect(body["latest_run"]).to be_nil
    end

    # AC. Re-derived straight from the table rather than from the same Ruby the serializer read, in
    # the ordering the model documents — most history first, ties to the branch pushed to most
    # recently, then to the name.
    it "matches direct SQL over the same repository's branches" do
      trunk_hidden_repository

      sql = <<~SQL.squish
        SELECT branch, COUNT(*) AS run_count
        FROM test_runs WHERE repository_id = $1 AND branch IS NOT NULL
        GROUP BY branch ORDER BY COUNT(*) DESC, MAX(created_at) DESC, branch ASC
      SQL
      rows = ActiveRecord::Base.connection
                               .select_all(sql, "branch catalogue cross-check", [repository.id]).to_a
      # Guards against the comparison passing on two empty arrays.
      expect(rows.length).to eq(11)
      expect(get_repository["branches"].map { |row| row.values_at("name", "run_count") })
        .to eq(rows.map { |row| [row["branch"], row["run_count"]] })
    end

    # AC7. The catalogue is a TOP-LEVEL key and is not smuggled into the window beside it —
    # `history_window` is asserted whole-hash, so a `branches` key folded in there would change a
    # block clients already read. Pinned here with a populated catalogue, which is the only state
    # where the mistake is possible.
    it "leaves history_window exactly as it was, rather than growing a branches key" do
      trunk_hidden_repository

      body = get_repository

      expect(body["branches"]).to be_present
      expect(body["history_window"]).to eq(
        "order" => "ingested_at_desc,ingest_sequence_desc",
        "tie_break_served" => false,
        "branch_scope" => "all_branches",
        "branch" => nil,
        "limit" => 10,
        "returned" => 10
      )
    end
  end

  # AC6. What the catalogue costs, on the axis it actually moves along. The two budget blocks below
  # vary shard count and run count, and BOTH build their runs with `branch: nil` — which the walk
  # excludes, so a catalogue returns zero rows there and costs nothing however it was written.
  # Neither can fail for a per-branch leak in principle. The branch axis is therefore written here
  # rather than inherited, and every run in it names a branch explicitly.
  describe "what the branches catalogue costs the endpoint" do
    def create_branches(count, prefix:)
      Array.new(count) do |index|
        create_test_run(repository: repository, commit_sha: "#{prefix}%08d" % index,
                        branch: "#{prefix}/branch-%03d" % index, total_specs_count: 10)
      end
    end

    # The invariance, from a ONE-BRANCH baseline out to forty. One query per branch — the shape the
    # `SELECT DISTINCT` this walk replaced would have invited — reads as thirty-nine extra
    # statements at the top of this example and none at the bottom.
    it "costs the same at 1 branch, at 10 and at 40" do
      create_branches(1, prefix: "one")
      get_repository
      baseline = executed_sql { get_repository }.length

      create_branches(9, prefix: "ten")
      expect(repository.test_runs.where.not(branch: nil).distinct.count(:branch)).to eq(10)
      expect(executed_sql { get_repository }.length).to eq(baseline)

      create_branches(30, prefix: "forty")
      expect(repository.test_runs.where.not(branch: nil).distinct.count(:branch)).to eq(40)
      expect(executed_sql { get_repository }.length).to eq(baseline)
      # The fixture really does carry the cardinality this example claims, so the invariance above
      # is over a branch axis that moved rather than over one that never left zero.
      expect(get_repository["branches"].length).to eq(40)
    end

    # The budget stated as ONE absolute query rather than only as "the same as before", because
    # invariance alone would also hold for a catalogue that cost forty-one queries at every size.
    it "pays exactly one query for the whole catalogue, at any branch count" do
      create_branches(40, prefix: "budget")
      # Warm the API-key lookup path so the auth queries do not vary between runs.
      get_repository

      walks = executed_sql { get_repository }.grep(/WITH RECURSIVE/)

      expect(walks.length).to eq(1)
      # One bounded walk, not a `SELECT DISTINCT branch` over the whole run history — the O(history)
      # scan `Repository#branch_histories` documents at length for refusing.
      expect(walks.first).to include("LIMIT")
      expect(executed_sql { get_repository }.grep(/SELECT DISTINCT/)).to be_empty
    end

    # AC6's second half: the walk is served by
    # `index_test_runs_on_repository_id_and_branch_and_created_at` (db/schema.rb), whose column
    # order — `(repository_id, branch, created_at, id)` — is what makes it one index descent per
    # BRANCH and none per run.
    #
    # THREE THOUSAND ROWS AND AN `ANALYZE`, not the forty above, and not `enable_seqscan = off`. On
    # a forty-row table Postgres sequentially scans however good the index is, so the plan would say
    # nothing; forcing the planner's hand only proves the index is *usable*, which is weaker than
    # the claim that matters. At a size where the choice is real the planner picks it on its own.
    #
    # EXPLAINED ON THE STATEMENT THE REQUEST ACTUALLY RAN, captured off the notification rather than
    # rebuilt here — `BRANCH_HISTORY_SQL` is `private_constant`, and a hand-copied query would be a
    # plan for a string this endpoint never executes.
    it "is served by the (repository_id, branch, created_at, id) index, with no sequential scan" do
      now = Time.current
      TestRun.insert_all!(Array.new(3000) do |index|
        { repository_id: repository.id, commit_sha: "planned%09d" % index,
          branch: (index % 30).zero? ? "main" : "feature/churn-#{index}",
          total_specs_count: 10, annotated_specs_count: 1,
          created_at: now - index.minutes, updated_at: now - index.minutes }
      end)
      ActiveRecord::Base.connection.execute("ANALYZE test_runs")

      walk = executed_sql { get_repository }.grep(/WITH RECURSIVE/).first
      # Proves the probe can produce a non-empty result at all: an unmatched grep and a clean plan
      # are indistinguishable at the assertion below.
      expect(walk).to be_present
      plan = ActiveRecord::Base.connection.select_values("EXPLAIN #{walk}").join("\n")

      expect(plan).to include("index_test_runs_on_repository_id_and_branch_and_created_at")
      expect(plan).not_to include("Seq Scan")
      # The branch is resolved by the index walk itself — an Index Cond and never a `Filter` applied
      # to rows the index already handed back, which is the shape that makes the walk O(history).
      # Matched LINE BY LINE: a multiline `.` would let the recursion's own
      # `Filter: (branch IS NOT NULL)` node — which sits on the work table, not on a run — pair up
      # with an Index Cond three lines away and report a leak that is not there.
      expect(plan.lines.grep(/Index Cond:.*branch = /)).not_to be_empty
      expect(plan.lines.grep(/Filter:.*branch = /)).to be_empty
    end
  end

  # AC6. What a narrowed window costs, asserted AT ITS OWN BOUND. The unfiltered budget examples
  # below bound at ten; a branch-scoped window bounds at thirty, and thirty is where a per-row
  # `pick` for `shard_count` would show up as twenty-nine extra queries that a three-row fixture
  # cannot distinguish from none.
  describe "what a branch-scoped history costs the endpoint" do
    def create_main_runs(count, prefix:)
      Array.new(count) do |index|
        create_test_run(repository: repository, commit_sha: "#{prefix}%08d" % index, branch: "main",
                        total_specs_count: 100 + index)
      end
    end

    # The invariance, from a ONE-ROW baseline to the full thirty-row bound and past it. A baseline
    # taken inside the window would sit inside the leak it is meant to measure; forty rows is what
    # proves the bound is enforced rather than the fixture merely being small.
    it "costs the same at 1 branch row, at 30 and at 40" do
      create_main_runs(1, prefix: "cost")
      get_repository(query: { branch: "main" })
      baseline = executed_sql { get_repository(query: { branch: "main" }) }.length

      create_main_runs(29, prefix: "grow")
      expect(repository.test_runs.where(branch: "main").count).to eq(30)
      expect(executed_sql { get_repository(query: { branch: "main" }) }.length).to eq(baseline)

      create_main_runs(10, prefix: "over")
      expect(repository.test_runs.where(branch: "main").count).to eq(40)
      expect(executed_sql { get_repository(query: { branch: "main" }) }.length).to eq(baseline)
      expect(get_repository(query: { branch: "main" })["history"].length).to eq(30)
    end

    # The budget stated as TWO absolute queries rather than only as "the same as before", because
    # invariance alone would also hold for a window that cost thirty-one queries at every size. The
    # two are the branch-scoped history SELECT and the one grouped COUNT that primes `shard_count`
    # across all thirty rows — the same pair `ShardCountPreloading` buys the human panel.
    #
    # The `test_run_shards` read is matched on `GROUP BY` rather than on the table alone, because
    # `latest_run` pays its own separate un-grouped aggregate for `shard_totals` on ONE row. That
    # query is not part of this window and is not what this example bounds; counting it here would
    # make the budget read as three and hide which of the two axes moved if one ever did.
    it "pays exactly two queries for a 30-row narrowed window: the history and one grouped count" do
      create_main_runs(30, prefix: "budget")
      # Warm the API-key lookup path so the auth queries do not vary between runs.
      get_repository(query: { branch: "main" })

      statements = executed_sql { get_repository(query: { branch: "main" }) }

      history_queries = statements.grep(/FROM "test_runs"/).grep(/"branch" = /)
      grouped_counts = statements.grep(/FROM "test_run_shards"/).grep(/GROUP BY/)

      expect(history_queries.length).to eq(1)
      expect(history_queries.first).to include("LIMIT")
      expect(grouped_counts.length).to eq(1)
      # One grouped COUNT for the WHOLE window, not one per row: thirty bind placeholders in a
      # single `IN`. A per-row `pick` reads as thirty statements here rather than one.
      expect(grouped_counts.first).to include("IN (")
      # BOTH counts ride in that ONE statement. `timed_shard_count` is served per row beside
      # `shard_count`, and the cheap way to get it wrong is a second grouped query — which keeps
      # every semantic example green, keeps this example's `length` at 1 for the `COUNT(*)` read,
      # and quietly makes the window cost three. Matching the second aggregate here is what makes
      # "exactly two" mean the two the comment above names.
      expect(grouped_counts.first).to match(/COUNT\(duration_seconds\)/i)
      # And no row pays a `pick` of its own for the timed count. The cheap way to serve
      # `timed_shard_count` per row is thirty un-grouped reads, which the two greps above cannot
      # see: they are not `GROUP BY` statements, so `grouped_counts` stays at one and this example
      # stays green while the window costs thirty-two. Exactly two reads of the table — the window's
      # one grouped aggregate, plus the single un-grouped `shard_totals` `latest_run` pays for its
      # own one row — is the bound that catches it.
      expect(statements.grep(/FROM "test_run_shards"/).length).to eq(2)
    end

    # The branch predicate and the LIMIT are ONE query, which is the entire fix: a window bounded
    # before it is filtered is what returns zero `main` rows today. Asserted on the SQL rather than
    # on the rows, because a two-query implementation that filtered in Ruby can return exactly the
    # same rows and would pass every example above.
    it "puts the branch predicate in the same statement as the bound" do
      create_main_runs(30, prefix: "onequery")
      get_repository(query: { branch: "main" })

      history = executed_sql { get_repository(query: { branch: "main" }) }
                .grep(/FROM "test_runs"/).grep(/"branch" = /)

      expect(history.length).to eq(1)
      # Both clauses, in that order, in one statement. `latest_run`'s own `LIMIT 1` read carries no
      # branch predicate and is filtered out above, so this cannot pass by matching that row.
      expect(history.first).to match(/"branch" = .*LIMIT/m)
    end

    # AC6's second half: the narrowed query is served by
    # `index_test_runs_on_repository_id_and_branch_and_created_at` (db/schema.rb), whose column
    # order — `(repository_id, branch, created_at, id)` — matches this predicate and this ordering
    # exactly.
    #
    # THREE THOUSAND ROWS AND AN `ANALYZE`, not the forty the examples above use, and not
    # `enable_seqscan = off`. On a forty-row table Postgres sequentially scans however good the
    # index is, so the plan says nothing about the index; and forcing the planner's hand with a
    # `SET` only proves the index is *usable*, which is a weaker claim than the one that matters.
    # At a size where the choice is real the planner picks the index on its own, which is the
    # property a growing repository actually depends on. Written through `insert_all!` so the
    # fixture costs one statement rather than three thousand.
    #
    # BACKWARD INDEX SCAN, and NO SORT NODE — that is the load-bearing half. The index supplies the
    # `(created_at, id) DESC` ordering, so the `Limit` stops the walk after thirty rows instead of
    # the planner sorting every run on the branch first. That is the difference between O(limit) and
    # O(history) as the branch grows, and it is the same distinction
    # `Repository#suite_size_trajectory` measured on a 40,000-run branch and documented.
    it "is served by the (repository_id, branch, created_at, id) index, walked backwards, with no sort" do
      now = Time.current
      TestRun.insert_all!(Array.new(3000) do |index|
        { repository_id: repository.id, commit_sha: "planned%09d" % index,
          # One row in thirty on `main`, so the predicate is genuinely selective and the branch has
          # a hundred runs — more than the bound, which is what makes the LIMIT meaningful.
          branch: (index % 30).zero? ? "main" : "feature/churn-#{index}",
          total_specs_count: 10, annotated_specs_count: 1,
          created_at: now - index.minutes, updated_at: now - index.minutes }
      end)
      ActiveRecord::Base.connection.execute("ANALYZE test_runs")

      plan = ActiveRecord::Base.connection.select_values(
        "EXPLAIN #{repository.recent_test_runs(limit: Repository::TRAJECTORY_LIMIT, branch: 'main').to_sql}"
      ).join("\n")

      expect(plan).to include("index_test_runs_on_repository_id_and_branch_and_created_at")
      expect(plan).to include("Index Scan Backward")
      expect(plan).not_to include("Seq Scan")
      expect(plan).not_to include("Sort")
      # The predicate is an Index Cond — resolved by the index walk itself — and not a `Filter`
      # applied to rows the index already handed back. A `Filter` here would mean the branch was
      # being matched AFTER the ordering walk, which is the shape that makes the scan O(history).
      expect(plan).to match(/Index Cond:.*branch/m)
      expect(plan).not_to match(/Filter:.*branch/m)
    end
  end

  # `index_test_run_shards_on_test_run_id` answering all three counts at once — so the endpoint's
  # cost does not move with the number of shards. A per-shard read, or one query per figure, shows
  # up here immediately; the 20,000-example fixture is 4 shards today and nothing stops it being 40.
  #
  # `history` adds a SECOND cost axis — the number of runs — and the shard example below does not
  # cover it. Its fixtures happen to create three runs, so it would only ever catch a per-run N+1
  # by accident and only above three rows; its stated axis is shards on one run and it varies run
  # count incidentally. The run-count example is therefore its own, named, and starts from a
  # one-run baseline that the shard example never establishes.
  describe "what the shard figures and the history cost the endpoint" do
    def sharded_run(shard_count, commit_sha:, settled: false)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, duration_seconds: 74.25)
      shard_count.times do |index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    duration_seconds: 60.0 + index)
      end
      run.test_run_shards.update_all(updated_at: 30.minutes.ago) if settled
      run
    end

    # The axis this example is NAMED for, and the only one it ever claimed to guard: the number of
    # shards. 4 and 40 cost the same, so nothing here is read once per shard.
    #
    # SPGD-230 added `shards.per_shard`, which is a read of the shard ROWS and cannot come out of
    # the same aggregate the three counts do — `TestRun#shard_totals` is a `pick` of four scalars
    # and widening it to haul rows would charge every caller of `shard_count` for a block only this
    # endpoint serves. So a multi-shard run costs one query more than a shardless one, and that
    # delta is PINNED AS AN EXACT NUMBER below rather than deleted from the guard: an equality
    # against a shardless baseline would have to be relaxed to an inequality to accommodate it, and
    # an inequality is a guard that stops catching the second read, and the third.
    #
    # Verified by mutation: making `serialized_shards` read `test_run.test_run_shards.map` instead
    # of the single `#shard_reports` pluck turns the 4-vs-40 assertions red (44 ≠ 8) and leaves the
    # `+ 1` at one — which is exactly the failure this example exists to catch, still caught.
    it "costs the same on a 4-shard run and a 40-shard run, one read more than a shardless one" do
      create_test_run(repository: repository, commit_sha: "noshards0000", duration_seconds: 42.5)
      get_repository
      shardless = count_queries { get_repository }

      sharded_run(4, commit_sha: "fourshards00")
      baseline = count_queries { get_repository }
      # The whole cost of serving the rows, stated as a number rather than as "more than": one
      # query, on `index_test_run_shards_on_test_run_id`, whatever the matrix width. Written
      # inline as `+ 1` rather than behind a name — an `RSpec.describe` block is not a namespace,
      # so a constant declared in one is `Object::PER_SHARD_ROW_READ`, defined project-wide from a
      # request spec. The reasoning it was named for is in the comment above, where it belongs.
      expect(baseline).to eq(shardless + 1)

      sharded_run(40, commit_sha: "fortyshards0")
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository.dig("latest_run", "shards", "count")).to eq(40)
      # And the rows really were served at 40 — a serializer that quietly stopped emitting them
      # above some width would satisfy every query count above.
      expect(get_repository.dig("latest_run", "shards", "per_shard").length).to eq(40)
    end

    # The decomposition's own axis, and it is stated as CONSTANT rather than as minimal — the
    # example above cannot state it, because on its un-settled fixtures the gate short-circuits and
    # `shard_durations` never fires at all.
    #
    # TWO extra reads here against the example above's one, and the difference between the two
    # numbers is the whole point of the pair. `#shard_reports` feeds `per_shard` and is paid by
    # every multi-shard run, gated or not — that is the `+ 1` above. `TestRun#shard_durations`
    # feeds `rows` and the two derived figures and is paid only once the gate opens, which is the
    # second read here and the only one this example can see. Both are documented as reads beside
    # the memoized `shard_totals` aggregate, deliberately kept separate so widening `shard_totals`
    # does not change what its other callers load.
    #
    # Written as `+ 2` rather than rebaselined, so a read that stopped being issued shows up as a
    # failure rather than as a quietly smaller baseline. What must not move is the number of reads
    # as the matrix grows — a per-shard `pick` reads as 40 statements here and as one everywhere
    # else, so this is the only place it is visible.
    it "costs two extra queries on a decomposable run, and the same two whether it has 4 shards or 40" do
      create_test_run(repository: repository, commit_sha: "gated0000000", duration_seconds: 42.5)
      get_repository
      baseline = count_queries { get_repository }

      four = sharded_run(4, commit_sha: "gatedfour000", settled: true)
      # The gate is open, so the cost below is the cost of actually serving the rows and not the
      # cost of declining to. Without this the example passes at `baseline` and asserts nothing.
      expect(four.reload).to be_wall_clock_decomposable
      expect(count_queries { get_repository }).to eq(baseline + 2)
      expect(get_repository.dig("latest_run", "shards", "rows").length).to eq(4)

      forty = sharded_run(40, commit_sha: "gatedforty00", settled: true)
      expect(forty.reload).to be_wall_clock_decomposable
      expect(count_queries { get_repository }).to eq(baseline + 2)
      expect(get_repository.dig("latest_run", "shards", "rows").length).to eq(40)
    end

    # The run-count axis, stated rather than inherited. `history` serves ten rows and each one
    # reports a `shard_count`, which is `TestRun#shard_totals` — one `pick` per instance — unless
    # the window is primed from a single grouped COUNT. Unprimed, this reads 1, 10 and 25 as three
    # different numbers; primed, it reads them as one.
    #
    # Baseline at ONE run on purpose. The bound is ten, so a baseline taken at three rows would sit
    # inside the window a leak scales with and understate it, and 25 exceeds the bound so the count
    # must stop moving there too — a serializer that ignored `limit` shows up as 25 ≠ 10.
    it "costs the same on 1 run, on 10 runs and on 25 runs" do
      create_test_run(repository: repository, commit_sha: "runcount0000", duration_seconds: 42.5)
      get_repository
      baseline = count_queries { get_repository }

      9.times { |index| create_test_run(repository: repository, commit_sha: "tenrun%06d" % index) }
      expect(repository.test_runs.count).to eq(10)
      expect(count_queries { get_repository }).to eq(baseline)

      15.times { |index| create_test_run(repository: repository, commit_sha: "bigrun%06d" % index) }
      expect(repository.test_runs.count).to eq(25)
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository["history"].length).to eq(10)
    end
  end
end
