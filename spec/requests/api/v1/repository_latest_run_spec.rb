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
        .to contain_exactly("repository", "api_key", "latest_run", "history_window", "history")
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
    def sharded_run(durations, commit_sha:)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, annotated_specs_count: 5000,
                                         duration_seconds: durations.compact.max)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    annotated_specs_count: 1250, duration_seconds: seconds)
      end
      run
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
        "coverage" => { "duration_seconds" => 4, "machine_seconds" => 4 }
      )
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
        "coverage" => { "duration_seconds" => 3, "machine_seconds" => 3 }
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
        "coverage" => { "duration_seconds" => 0, "machine_seconds" => 0 }
      )
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
        "duration_seconds", "shard_count", "suite_size_measured", "ingested_at"
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
        "shards" => nil, "ingested_at" => third.created_at.iso8601
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

      expect(blank).to eq(absent)
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

    # AC5. This is the first request parameter read anywhere in `Api::V1`, so the shapes a query
    # string can legally parse into are worth pinning rather than assuming. `?branch[]=main` is an
    # Array and `?branch[a]=b` is an `ActionController::Parameters`; neither is a String, and an
    # unguarded `.presence` on either is a 500 on an authenticated GET.
    #
    # A non-String is treated as no filter — the same answer an absent param gets — rather than a
    # 400, because there is nothing here for a client to correct that a missing param would not
    # equally have. `branch => nil` in the window is what says the filter did not apply, so the
    # response is not silently claiming to have honoured a request it dropped.
    [
      ["an array", { branch: ["main"] }],
      ["a nested hash", { branch: { a: "b" } }],
      ["an array of hashes", { branch: [{ a: "b" }] }]
    ].each do |shape, query|
      it "answers 200 rather than 500 when branch arrives as #{shape}" do
        branch_starved_repository

        body = get_repository(query: query)

        expect(response).to have_http_status(:ok)
        expect(body["history_window"]).to include("branch_scope" => "all_branches", "branch" => nil,
                                                  "limit" => 10)
        expect(body["history"].length).to eq(10)
      end
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

      expect(filtered.values_at("repository", "api_key", "latest_run"))
        .to eq(unfiltered.values_at("repository", "api_key", "latest_run"))
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
        .to contain_exactly("repository", "api_key", "latest_run", "history_window", "history")
      expect(body["history"].first.keys).to contain_exactly(
        "commit_sha", "branch", "total_specs", "annotated_specs", "annotated_ratio",
        "duration_seconds", "shard_count", "suite_size_measured", "ingested_at"
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

  # AC6. What a narrowed window costs, asserted AT ITS OWN BOUND. The unfiltered budget examples
  # below bound at ten; a branch-scoped window bounds at thirty, and thirty is where a per-row
  # `pick` for `shard_count` would show up as twenty-nine extra queries that a three-row fixture
  # cannot distinguish from none.
  describe "what a branch-scoped history costs the endpoint" do
    def executed_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        statements << payload[:sql] unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

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
    def count_queries
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def sharded_run(shard_count, commit_sha:)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, duration_seconds: 74.25)
      shard_count.times do |index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    duration_seconds: 60.0 + index)
      end
      run
    end

    it "costs the same on a 4-shard run, a 40-shard run and a run with no shards at all" do
      create_test_run(repository: repository, commit_sha: "noshards0000", duration_seconds: 42.5)
      get_repository
      baseline = count_queries { get_repository }

      sharded_run(4, commit_sha: "fourshards00")
      expect(count_queries { get_repository }).to eq(baseline)

      sharded_run(40, commit_sha: "fortyshards0")
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository.dig("latest_run", "shards", "count")).to eq(40)
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
