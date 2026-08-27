# frozen_string_literal: true

require "rails_helper"

# The auth contract for this endpoint lives in `repositories_spec.rb` and is deliberately left
# untouched. This file covers the `latest_run` block — the agent-readable twin of the suite
# figures `repositories#show` renders — and the `history` array beside it, the agent-readable twin
# of the "Recent runs" panel.
RSpec.describe "GET /api/v1/repository — latest_run and history", type: :request do
  # For the settling-axis example, which asserts the moment a client computes from the body really
  # is the moment `TestRun#wall_clock_decomposable?` flips — a claim about a CLOCK, and the only
  # way to make it is to move one. Included on this group rather than configured globally in
  # `rails_helper`: no other spec in the suite travels time today, and a project-wide include for
  # one example would put `travel_to` in reach of every spec that has done without it.
  include ActiveSupport::Testing::TimeHelpers

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

  # `observation_reads` and the per-grain partition it is split into come from
  # spec/support/observation_grain_reads.rb. They lived HERE until a second request spec — the
  # flakiness file beside this one — needed the same classification, at which point keeping them
  # here would have meant a second copy in that file: two lists free to drift on which read belongs
  # to which grain, which is the drift the note above describes for the subscriber itself. The
  # reasoning that used to sit here in full moved with them, including why every grain is matched
  # POSITIVELY and never as "the reads that are not the others".
  #
  # Each cost block below still bounds its OWN grain rather than the table, because a bare total
  # cannot tell "one aggregate per grain" from "one grain reading twice". The TOTAL is pinned
  # alongside it in the by-area block, on each axis the per-grain narrowing left uncovered — the
  # unrecorded run, the history window, and the recorded run — so "exactly these reads and no other"
  # is a stated guard on every one of them rather than an inference from the grain that happens to
  # be counted.
  #
  # Every fixture in this file is UNFILTERED or has no observation rows on a branch-scoped window,
  # so the flakiness grain contributes nothing to the totals below — which is itself the contract
  # (`unstable_tests` is not constructed without `?branch=`) and is asserted as such next door
  # rather than left as an unremarked property of these fixtures.

  # ONE builder for every block that writes observation rows — the four grain blocks below (by-file
  # and by-area, rollup and cost) all want the same row and had written it out four times. Hoisted
  # for the reason the note above gives about `observation_reads`: RSpec scoping a `def` to its own
  # example group explains why a sibling's helper is INVISIBLE, it does not argue for copying it,
  # and four copies of a `create!` is four places for the row shape to drift apart.
  #
  # `duration:` is REQUIRED rather than defaulted, at every call site including the nils, on the
  # rule `spec_observation_spec.rb`'s builder states for itself: an untimed row is the state half
  # the rollup blocks turn on, and a builder that defaulted it would let an example write one
  # without meaning to. `line_number` keeps `example_id` unique within a file, so a caller can put
  # several examples in one file the way a real suite does.
  #
  # `name:` and `outcome:` default to `nil` — the column's own default and what every call site
  # here wrote before they existed, so adding them changes no existing fixture. Both are nullable
  # by schema and `Ingest::ObservationRecorder#attributes` writes `name` through `presence_of`, so
  # a nil is an ORDINARY state a producer reaches rather than an omission the builder invented.
  #
  # `defined_in:` overrides `file_path` alone, leaving `path` as the INCLUDING file. It is the one
  # input at the per-example grain with no counterpart in the rollups, which aggregate on
  # `spec_file_path` and never see the two diverge: a shared example group is DEFINED in
  # `spec/support/` and INCLUDED by the spec file that ran it, and `SpecObservation`'s "Two paths,
  # two meanings" note is what says they must not be collapsed into one coordinate.
  #
  # `included_by:` is its mirror and overrides `spec_file_path` alone, defaulting to `path` — the
  # signature itself says "not given means the including file IS the path", so `nil` passes through
  # as an ordinary VALUE with no sentinel to read it as an omission. The column is nullable by
  # schema and `Ingest::ObservationRecorder` writes it through `presence_of`, so a producer that
  # names a definition site and no including file stores a nil there. It is the only input that
  # makes `RepeatedDescriptions::Row#files_seen` differ from the raw `ARRAY_AGG … FILTER` it wraps:
  # with every row of a group carrying nil, that aggregate is SQL NULL rather than an empty array,
  # and the serialized key would be `null` instead of `[]`.
  def observe(run, path:, duration:, line_number:, name: nil, outcome: nil, defined_in: nil,
              included_by: path)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line_number}]",
      file_path: defined_in || path,
      spec_file_path: included_by,
      line_number: line_number,
      status: "unannotated", duration_seconds: duration, name: name, outcome: outcome
    )
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
        # THE THREE READINGS, and four zeros is the honest answer on this fixture rather than a
        # null. The three keys above are the run's COUNTERS and say what the client REPORTED; these
        # are counted over the per-example ROWS, and this run wrote none — so `recorded: 0` is what
        # separates "nobody sent the detail" from "nothing is readable", and three zeros without it
        # could not. A null would say "you did not ask", and there is nothing here to ask.
        "intent_readings" => { "authored" => 0, "derived" => 0, "unreadable" => 0, "recorded" => 0 },
        "duration_seconds" => 42.5,
        # Null, not an empty block: this fixture has no shards, so there is no composition to
        # explain and the MAX the key above reports *is* the SUM. The key is still present, on the
        # same rule `latest_run` itself follows one describe-block down.
        "shards" => nil,
        # Null on the same rule, one grain over: this fixture records no `spec_observations`, so
        # the run disclosed no per-example detail and there is no by-file rollup to serve. Not a
        # zeroed block — a `file_count: 0` beside an empty array would assert a run that touched no
        # spec files, which is a measurement nobody took.
        "spec_files" => nil,
        # And null at the grain above it, for the same reason and off the same absent rows: no
        # observation row means no by-area rollup either. A `directory_count: 0` beside an empty
        # array would assert a run that touched no directories.
        "spec_directories" => nil,
        # And at the per-EXAMPLE grain, off the same absent rows: no observation row means no
        # ranking either, and no coverage to state it over. Not a zeroed block — a
        # `recorded_count: 0` beside an empty array would assert a run that ran no examples.
        "slowest_examples" => nil,
        # And at the DESCRIPTION grain, off the same absent rows: a run that recorded nothing
        # described nothing, so there is no population to group and no honest zero to report over
        # it. Not a zeroed block — a `recorded_count: 0` beside an empty array would say this run
        # ran examples and repeated none of them, which is the *Vacuous Green* reading
        # `RepeatedDescriptions#recorded?` exists to refuse.
        "repeated_descriptions" => nil,
        # And the drill-in into ONE area, null for a REASON NONE OF THE FIVE ABOVE SHARE: this
        # request sent no `?spec_directory=`, so no area was asked for and none was answered. It
        # would be null on this fixture either way — there are no rows to find — but the two are
        # different facts, and only this key's `null` says nothing about the run at all. `shards`
        # twenty lines up is null about the run, the four rollups about its rows; this one is null
        # about the request. The empty ANSWER is a present block with `rows: []` and the asked-for
        # path restated in it; see `repository_spec_directory_files_spec.rb`, where the pair is
        # asserted side by side.
        "spec_directory_files" => nil,
        # And the drill-in into ONE FILE, null for the same reason as the key above it and for none
        # of the reasons the five above THAT share: this request sent no `?spec_file=`. The two
        # request-shaped nulls sit together at the bottom of the block because they are two rungs of
        # one ladder — area opened, then file opened — and the empty ANSWER to either is a present
        # block with `rows: []` and the asked-for path restated in it; see
        # `repository_spec_file_examples_spec.rb`, where that pair is asserted side by side.
        "spec_file_examples" => nil,
        # And the drill-in into ONE DESCRIPTION, null for the same request-shaped reason as the two
        # keys above it and NOT for a third one: this request sent no `?repeated_description=`. It
        # sits with them because all three are the client's asks, and last of the three because it is
        # the one that leaves their ladder — those two open a PLACE, area then file, and this opens a
        # SENTENCE, whose rows routinely span several of both. The empty ANSWER is a present block
        # with `rows: []` and the asked-for description restated in it; see
        # `repository_repeated_description_examples_spec.rb`, where that pair is asserted side by
        # side.
        "repeated_description_examples" => nil,
        # And the drill-in into the run's UNANNOTATED examples, null for the same request-shaped
        # reason as the three keys above it: this request sent no `?unannotated_examples=`. It is
        # the fourth of the client's asks and the only one that opens a POPULATION rather than a
        # pick — the three above open one area, one file and one sentence, each the rows behind a
        # LINE of a ranking, and this opens the rows behind `total_specs` MINUS `annotated_specs`,
        # two keys at the top of this very block. Its empty ANSWER is the sharpest on the block: a
        # present block with `rows: []` and `recorded_count: 0`, which is not an absence but the
        # state the metric exists to REACH; see `repository_unannotated_examples_spec.rb`, where
        # that pair is asserted side by side.
        "unannotated_examples" => nil,
        # And the RANKING above that worklist, null for the same reason and from the SAME ask —
        # `unannotated_directories` rides `?unannotated_examples=` rather than a parameter of its
        # own, so the two keys are absent and present together. It is the rung that makes the
        # narrowing usable: the worklist is ordered file-navigably, and every other area rollup on
        # this block ranks by DURATION with a `coverage_label` that is TIMING coverage, so nothing
        # here could tell a client WHICH area to go and ask about. Unlike its sibling it stays
        # WHOLE-RUN under `?spec_file=` / `?spec_directory=` — the one deliberate scope disagreement
        # inside a single block on this endpoint; see `repository_unannotated_examples_spec.rb`,
        # where both halves are asserted together.
        "unannotated_directories" => nil,
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

    # The body is the whole feature here, and THIS FILE IS ITS CONTRACT — there is no prose copy to
    # read it off, so an agent finds out `history` exists by reading the list below, not by diffing
    # responses. So the top level is pinned EXACTLY rather than key by key: a key added without a
    # line in that list fails here, and a listed key quietly dropped fails here too.
    # `contain_exactly` is what makes it bidirectional; `have_key` per block would catch neither.
    it "serves exactly the top-level keys this contract pins" do
      expect(get_repository.keys)
        .to contain_exactly("repository", "api_key", "delivery_health", "credential_health",
                            "run_anchor", "latest_run",
                            "history_window", "history",
                            "unstable_tests_window", "unstable_tests",
                            "directory_growth_window", "directory_growth",
                            "directory_run_growth_window", "directory_run_growth",
                            "directory_runtime_growth_window", "directory_runtime_growth",
                            "directory_run_file_growth_window", "directory_run_file_growth",
                            "directory_runtime_file_growth_window", "directory_runtime_file_growth",
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

  # AC5. `TestRun#annotated_fraction` returns nil for a zero denominator; emitting a `0.0` here
  # would read as a *measured* zero share beside real fractions. `/ingest` reads the same method
  # and answers the same run identically — pinned across both bodies in ingest_spec.rb.
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
    # by the guards in this file and protected by `history_runs`' shared ordering — so one response
    # body here describes one database row twice. Before this key was served on `latest_run`, those
    # two descriptions could disagree: the row said `suite_size_measured: false` as `history[0]` and
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

    # The key-set guard at the top of this file, carried down to the levels its SELECTOR cannot
    # reach. `get_repository.keys` is depth 1: it pins the seven top-level names and nothing inside
    # them, so SPGD-234 added three keys at depth 3 that no guard here named, and went green
    # straight past it. A reviewer caught that by hand on a 6/6 git precedent, and `bin/ci` has no
    # contract-drift step (`config/ci.rb` confirms) — hand-review was the only signal there was.
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
    # natural way — absent when withheld — they would have shipped named by nothing and with no red
    # spec at all.
    #
    # So these guards are stated on the OPEN gate, where nothing was watching, and the closed gate
    # is re-asserted from the SAME list so the two states cannot drift into disagreeing about what
    # the block contains.
    #
    # KEYS, NOT VALUES, on the precedent the `history[]` row guard sets further down. The `eq`s
    # above pin these names only as a side effect of asserting one fixture's arithmetic, and they
    # read as cost-figure examples; a guard whose stated subject IS the key set survives a fixture
    # whose numbers change, and says out loud what a new key owes this list before it ships.
    # SPGD-849 appended `last_shard_arrived_at` and `settling_period_seconds` and turned BOTH
    # examples below red on the way in — which is this guard working rather than a regression, and
    # is the whole reason it was stated on the open gate. Neither assertion was weakened to
    # accommodate them and neither key is branch-conditional: they are served on both gates, so the
    # one list still describes both states.
    def contract_shard_keys
      %w[count timed_count machine_seconds coverage rows balanced_wall_clock_seconds
         wall_clock_excess_seconds last_shard_arrived_at settling_period_seconds per_shard]
    end

    it "serves exactly the latest_run keys this contract pins, on a sharded run" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0198", settled: true)
      # The composition neither existing `latest_run` pin sees — both are written against the
      # unsharded fixture. Asserted BEFORE the keys are read, so this cannot quietly become a
      # second copy of a guard that already passes on the run it means to exclude.
      expect(repository.latest_test_run).to be_multi_shard

      expect(get_repository["latest_run"].keys)
        .to contain_exactly("commit_sha", "branch", "total_specs", "annotated_specs",
                            "annotated_ratio", "intent_readings", "duration_seconds", "shards",
                            "spec_files",
                            "spec_directories", "slowest_examples", "repeated_descriptions",
                            "spec_directory_files", "spec_file_examples",
                            "repeated_description_examples", "unannotated_examples",
                            "unannotated_directories",
                            "suite_size_measured",
                            "ingested_at")
    end

    it "serves exactly the shards keys this contract pins once the decomposition is open" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0199", settled: true)
      # `shards` is `null` on an unsharded run, so a key-set assertion that never checked the
      # fixture would be reading `.keys` off `nil` — Vacuous Green, in the file that exists to
      # avoid it. `wall_clock_decomposable?` is the stronger of the two states to assert, since it
      # implies `multi_shard?` and is the branch the mutation above proved unguarded.
      expect(repository.latest_test_run).to be_wall_clock_decomposable

      expect(get_repository.dig("latest_run", "shards").keys)
        .to contain_exactly(*contract_shard_keys)
    end

    it "serves those same keys while the decomposition is withheld" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0200")
      shown = repository.latest_test_run
      expect(shown).to be_multi_shard
      expect(shown).to be_wall_clock_decomposition_pending

      shards = get_repository.dig("latest_run", "shards")

      # The same ten names as the open gate, from the same list: withholding a figure withholds
      # its VALUE, not its name. That is `serialized_shards`' stated contract and the reason a
      # client tests one thing (`rows == null`) rather than distinguishing an absent key from a
      # null one — and a guard written only against the open gate would pass a change that made
      # the three keys absent here instead, which is the regression the contract exists to stop.
      expect(shards.keys).to contain_exactly(*contract_shard_keys)
      expect(shards.values_at("rows", "balanced_wall_clock_seconds", "wall_clock_excess_seconds"))
        .to all(be_nil)
    end

    # The defect, stated as an expectation. 74.25s of waiting against 253.75s of machine time is a
    # 3.4× gap on this fixture, and until now the endpoint served only the smaller number.
    it "serves the machine time beside the wall clock, and states what each was computed over" do
      run = sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0179")

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
        # The settling axis, SERVED WHILE THE THREE ABOVE ARE NULL — the state this fixture is in
        # is the one the pair exists for. Read off the run's own accessor and off the constant
        # rather than written as literals: a hardcoded timestamp would pin the fixture's clock, and
        # a hardcoded `900` is precisely the drift between the panel and the endpoint that
        # publishing from `SHARD_DELIVERY_SETTLING_PERIOD` exists to prevent.
        "last_shard_arrived_at" => run.last_shard_arrived_at.iso8601,
        "settling_period_seconds" => TestRun::SHARD_DELIVERY_SETTLING_PERIOD.to_i,
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
      run = sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0181")

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
        # Served on this fixture too, and its value does not depend on WHICH condition closed the
        # gate: the pair is a delivery fact, not a decomposition one.
        "last_shard_arrived_at" => run.last_shard_arrived_at.iso8601,
        "settling_period_seconds" => TestRun::SHARD_DELIVERY_SETTLING_PERIOD.to_i,
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
      run = sharded_run([nil, nil, nil, nil], commit_sha: "feedfacecafe0183")

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
        # Served even here, where every OTHER figure the shards could have carried is null. The
        # pair says when the rows ARRIVED, which is known whether or not they said anything when
        # they did — `Ingest::RunRecorder#upsert_shard` stamps a row on every delivery, timed or
        # silent. This is the fixture that separates "no shard reported a duration" from "no shard
        # arrived": the first is this run, and the second is NOT ASSERTED ANYWHERE because it is
        # unreachable through this endpoint — `serialized_shards` returns `nil` wholesale below
        # `multi_shard?`, so a run with no shard rows never reaches this serializer and its `null`
        # cannot be observed by a client. The `&.iso8601` in the controller is insurance for a gate
        # that widens later, not a branch a fixture here can exercise; don't go looking for the
        # example, and don't add one by bypassing `multi_shard?`.
        "last_shard_arrived_at" => run.last_shard_arrived_at.iso8601,
        "settling_period_seconds" => TestRun::SHARD_DELIVERY_SETTLING_PERIOD.to_i,
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

      # AC1. The gap this slice closes, stated as the arithmetic a client would actually perform
      # rather than as the shape of the block: from the withheld body ALONE, compute the moment the
      # decomposition comes back. Both operands are required for that — the timestamp without the
      # period makes the client hardcode 15 minutes, and the period without the timestamp gives it
      # nothing to add to — so the assertion is on the SUM, which fails if either one is wrong.
      #
      # WHICH condition failed was never the gap and is deliberately not asserted here: `count > 1`
      # and `timed_count == count` are both in this same body, so a client reading `rows: null`
      # beside them already concludes by elimination that delivery is settling. Only the WHEN was
      # unreachable.
      it "carries enough to compute when the withheld decomposition returns, while it is withheld" do
        run = sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0233")
        expect(repository.latest_test_run).to be_wall_clock_decomposition_pending

        shards = get_repository.dig("latest_run", "shards")

        # The client's own computation, over parsed JSON and nothing else.
        available_at = Time.iso8601(shards["last_shard_arrived_at"]) + shards["settling_period_seconds"]

        # `#floor`, and the truncation is REAL rather than a tolerance loosened to make this pass:
        # `iso8601` is second-granular on this endpoint (`ingested_at`, `rotated_at` and
        # `occurred_at` all serialize the same way), so a client's computed moment is the true one
        # floored by up to a second. Stated here rather than hidden behind `be_within`, because a
        # reader is entitled to know which direction the error runs — EARLY, never late, which is
        # the safe direction for a poll: coming back a second too soon costs one more request, and
        # a moment rounded the other way would tell a client the decomposition was ready before the
        # gate opened.
        expect(available_at).to eq(run.last_shard_arrived_at.floor + TestRun::SHARD_DELIVERY_SETTLING_PERIOD)
        # And the moment it computes really is the GATE's own moment, not merely a well-formed
        # time: the run is still withheld the second before it and decomposable the second after.
        # Without this the example passes against any serializer emitting a plausible timestamp
        # beside a plausible integer. The `+ 1.second` is that same floor and not a fudge — at
        # exactly `available_at` a run carrying sub-second precision is still a fraction short.
        travel_to(available_at - 1.second) { expect(run).not_to be_wall_clock_decomposable }
        travel_to(available_at + 1.second) { expect(run).to be_wall_clock_decomposable }
      end

      # AC3. The period is PUBLISHED FROM THE CONSTANT, so the endpoint and the Overview panel
      # cannot drift about how long settling takes.
      #
      # Asserted by MOVING the constant, not by comparing the served value to it — a serializer
      # with `900` typed into it satisfies an equality against `SHARD_DELIVERY_SETTLING_PERIOD` for
      # exactly as long as nobody changes the constant, which is the drift this criterion is about.
      # Under a stubbed period the literal implementation goes red and the constant-reading one
      # tracks it.
      it "serves the settling period from the constant, so a changed constant changes the body" do
        sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0234")

        expect(get_repository.dig("latest_run", "shards", "settling_period_seconds")).to eq(900)

        stub_const("TestRun::SHARD_DELIVERY_SETTLING_PERIOD", 42.minutes)

        expect(get_repository.dig("latest_run", "shards", "settling_period_seconds")).to eq(2520)
      end

      # AC2, from the other side of the gate. The key-set guards above prove both names are PRESENT
      # on both branches; this proves the timestamp is VALUED on the open one too, because a
      # present-but-null-once-settled key would satisfy every key-set assertion in this file while
      # answering nothing. A settled run saying WHEN it settled is a fact a reader wants after the
      # decomposition opens and not only before.
      it "keeps serving the arrival moment once the decomposition has opened" do
        run = sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0235", settled: true)
        expect(repository.latest_test_run).to be_wall_clock_decomposable

        shards = get_repository.dig("latest_run", "shards")

        expect(shards["last_shard_arrived_at"]).to eq(run.last_shard_arrived_at.iso8601)
        expect(shards["settling_period_seconds"]).to eq(900)
        # The decomposition really is open, so this is the settled branch and not a second copy of
        # the pending example above.
        expect(shards["rows"]).to be_present
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

  # WHERE the wall clock went, by spec file — the agent-readable twin of the by-file panel
  # `repositories#show` has rendered since SPGD-275. Every per-example fact the platform records
  # was reachable only by rendering HTML before this slice; the endpoint's own `serialized_shards`
  # rationale is the precedent, one axis over ("an agent reading only those cannot learn which part
  # it waited on").
  describe "the by-file rollup on latest_run" do
    # A run whose heaviest file sorts LAST alphabetically, so cost order and path order disagree.
    # That disagreement is the fixture's whole job: with the two orders coincident, a serializer
    # that re-sorted on `path` would serve the same array as one that inherited the aggregate's
    # `SUM(...) DESC NULLS LAST` and every ordering assertion below would pass on a list nothing
    # ranked. Verified by mutation — sorting the rows by path in the serializer turns three
    # examples in this block red, and turned only one red before the fixture was inverted.
    let!(:test_run) do
      run = create_test_run(repository: repository, commit_sha: "byfile000001",
                            branch: "main", total_specs_count: 6, duration_seconds: 12.0)
      observe(run, path: "spec/models/user_spec.rb", duration: 4.0, line_number: 1)
      observe(run, path: "spec/models/user_spec.rb", duration: 5.0, line_number: 2)
      observe(run, path: "spec/models/invoice_spec.rb", duration: 1.5, line_number: 1)
      run
    end

    def spec_files = get_repository.dig("latest_run", "spec_files")

    # AC1. The block exists, and its rows carry all four columns rather than a path and a number.
    # The array is asserted as a SEQUENCE — `eq`, not `match_array` — because the ranking is half
    # of what this key promises, and the fixture above is built so the two orders differ.
    it "serves each file's total beside what that total was summed over, heaviest first" do
      expect(spec_files["rows"]).to eq(
        [
          { "path" => "spec/models/user_spec.rb", "total_seconds" => 9.0,
            "recorded_count" => 2, "timed_count" => 2 },
          { "path" => "spec/models/invoice_spec.rb", "total_seconds" => 1.5,
            "recorded_count" => 1, "timed_count" => 1 }
        ]
      )
      expect(spec_files["file_count"]).to eq(2)
      expect(spec_files["limit"]).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
    end

    # AC8's companion: the sub-block's own key set, stated as its subject rather than pinned as a
    # side effect of the `eq` above — the pattern `contract_shard_keys` sets one block up, and for
    # the same reason. A guard whose stated subject IS the key set survives a fixture whose numbers
    # change, and says out loud what a new key owes this block before it ships.
    it "serves exactly the spec_files keys this contract pins" do
      expect(spec_files.keys).to contain_exactly("rows", "file_count", "limit")
      expect(spec_files["rows"].first.keys)
        .to contain_exactly("path", "total_seconds", "recorded_count", "timed_count")
    end

    # AC5. Read off the same presenter `repositories#show` assigns rather than re-stating the
    # fixture's numbers: two independent hand-written expectations would both still pass if the
    # endpoint started reading a different run, a different limit, or re-sorted the list. The
    # ORDER is asserted as a sequence, because that is the half a `match_array` would drop and the
    # half the `NULLS LAST` in the aggregate exists to get right.
    it "serves the same rows, in the same order, that repositories#show renders" do
      shown = SpecFileDurations.for(repository.latest_test_run)

      expect(spec_files["rows"].map { it["path"] }).to eq(shown.rows.map(&:path))
      expect(spec_files["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
      expect(spec_files["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
      expect(spec_files["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
      expect(spec_files["file_count"]).to eq(shown.file_count)
    end

    # AC6. The block's standing rule, asserted over the whole serialized body rather than per key:
    # `Row#duration_label` and `#coverage_label` are one call away in the presenter this reads
    # from, and a serializer that reached for either would still satisfy every assertion above if
    # the fixture's numbers happened to render similarly.
    it "serves numbers, never the panel's labels" do
      expect(spec_files.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(spec_files["rows"].map { it["total_seconds"] }).to all(be_a(Float).or(be_nil))
      expect(spec_files["rows"].map { it["recorded_count"] }).to all(be_a(Integer))
    end

    # AC3. THE row this grain has to get right. `SUM` skips NULLs silently, so a file none of whose
    # examples reported a timing comes back as SQL NULL — and serializing that as `0.0` would
    # assert the file cost the run nothing, which is a measurement nobody took. Both halves are
    # asserted because they fail differently: a serializer coalescing to zero passes "the file
    # appears" and fails "the total is null".
    it "serves null, not 0.0, for a file whose examples all went untimed" do
      observe(test_run, path: "spec/models/silent_spec.rb", duration: nil, line_number: 1)
      observe(test_run, path: "spec/models/silent_spec.rb", duration: nil, line_number: 2)

      silent = spec_files["rows"].find { it["path"] == "spec/models/silent_spec.rb" }

      expect(silent).not_to be_nil
      expect(silent["total_seconds"]).to be_nil
      expect(silent["recorded_count"]).to eq(2)
      expect(silent["timed_count"]).to eq(0)
      # And it sorts to the TAIL rather than the head: `duration_seconds: :desc` is NULLS FIRST in
      # Postgres, so a list that re-sorted here would name the file that reported nothing as the
      # heaviest in the run.
      expect(spec_files["rows"].last["path"]).to eq("spec/models/silent_spec.rb")
    end

    # A file whose examples were HALF timed — the state that makes a per-row denominator load
    # bearing rather than decorative. The total covers half the file, and the row is what says so;
    # a client reading `total_seconds` beside a suite-level coverage figure would take this file's
    # 3.0s as its cost.
    it "states per-row coverage on a partly timed file" do
      observe(test_run, path: "spec/models/partial_spec.rb", duration: 3.0, line_number: 1)
      observe(test_run, path: "spec/models/partial_spec.rb", duration: nil, line_number: 2)

      partial = spec_files["rows"].find { it["path"] == "spec/models/partial_spec.rb" }

      expect(partial["total_seconds"]).to eq(3.0)
      expect(partial["recorded_count"]).to eq(2)
      expect(partial["timed_count"]).to eq(1)
    end

    # AC4. The figure `rows.size` cannot supply. The list stops at the limit, so its own length
    # reads the same on "the 10 heaviest of 300" and "all 10 this run touched" — and a client with
    # only the array would report the second while looking at the first.
    it "reports how many files the run touched in all, past the limit that cut the list" do
      limit = SpecObservation::HEAVIEST_FILES_LIMIT
      (limit + 5).times do |index|
        observe(test_run, path: format("spec/models/extra_%02d_spec.rb", index),
                duration: 20.0 + index, line_number: 1)
      end

      expect(spec_files["rows"].length).to eq(limit)
      # The fixture's own two files plus the fifteen above — asserted against the table rather than
      # against a number written twice, so this cannot agree with a miscounted `COUNT(*) OVER ()`.
      expect(spec_files["file_count"]).to eq(test_run.spec_observations.distinct.count(:spec_file_path))
      expect(spec_files["file_count"]).to be > spec_files["rows"].length
      expect(spec_files["limit"]).to eq(limit)
    end
  end

  # WHERE the wall clock went, by code AREA — the block above one rung up, and the agent-readable
  # twin of the by-directory panel `repositories#show` renders. Served BESIDE the by-file rollup
  # rather than instead of it, because the area grain is NOT derivable from the file grain by a
  # client: the list above stops at ten files, so an agent holding it out of a twenty-thousand
  # example run structurally cannot sum the run's directories. `SpecDirectoryDurations`' own
  # comment states the arithmetic — *"a directory holding forty files at two seconds each is eighty
  # seconds of the run with not one of its rows in that list"* — and the fixture below is built so
  # that this file's examples FAIL under a client that tries.
  describe "the by-area rollup on latest_run" do
    # A run whose heaviest AREA is heavy through MANY SMALL FILES, and whose heaviest FILE lives in
    # a different, lighter area. Both disagreements are the fixture's job:
    #
    #   - `spec/requests` totals 12.0s over four 3.0s files. Not one of them is the heaviest file
    #     in the run; the heaviest FILE is `spec/models/user_spec.rb` at 9.0s, in the area that
    #     comes SECOND. A serializer that rolled the by-file list up by parent directory, or a
    #     client that did, ranks these two backwards — which is the non-derivability this key
    #     exists for, asserted rather than asserted about.
    #   - `spec/models` sorts BEFORE `spec/requests` alphabetically while costing less, so cost
    #     order and path order disagree and a serializer that re-sorted on `path` serves a
    #     different array from one that inherited `SUM(...) DESC NULLS LAST`.
    let!(:test_run) do
      run = create_test_run(repository: repository, commit_sha: "bydir0000001",
                            branch: "main", total_specs_count: 7, duration_seconds: 24.0)
      #   - `spec/models` carries THREE examples over TWO descriptions and `spec/requests` FOUR over
      #     four, so the distinct-description count is not the example count in either area and a
      #     serializer that served `recorded_count` twice under two names is red on the first row.
      observe(run, path: "spec/models/user_spec.rb", duration: 4.0, line_number: 1,
                   name: "User is valid with a handle")
      observe(run, path: "spec/models/user_spec.rb", duration: 5.0, line_number: 2,
                   name: "User is valid with a handle")
      observe(run, path: "spec/models/invoice_spec.rb", duration: 1.5, line_number: 1,
                   name: "Invoice finalize locks the line items")
      4.times do |index|
        observe(run, path: "spec/requests/thing_#{index}_spec.rb", duration: 3.0, line_number: 1,
                     name: "Thing #{index} responds")
      end
      run
    end

    def spec_directories = get_repository.dig("latest_run", "spec_directories")

    # AC1. The block exists, and its rows carry all four columns rather than a path and a number.
    # The array is asserted as a SEQUENCE — `eq`, not `match_array` — because the ranking is half
    # of what this key promises, and the fixture above is built so the two orders differ.
    it "serves each area's total beside what that total was summed over, heaviest first" do
      expect(spec_directories["rows"]).to eq(
        [
          { "path" => "spec/requests", "total_seconds" => 12.0,
            "recorded_count" => 4, "timed_count" => 4,
            "distinct_name_count" => 4, "named_count" => 4 },
          { "path" => "spec/models", "total_seconds" => 10.5,
            "recorded_count" => 3, "timed_count" => 3,
            "distinct_name_count" => 2, "named_count" => 3 }
        ]
      )
      expect(spec_directories["directory_count"]).to eq(2)
      expect(spec_directories["limit"]).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    end

    # The reason this key is served AT ALL, stated as a guard rather than as a comment. Every
    # figure here is read off the response, so it is the endpoint's own two blocks disagreeing:
    # the heaviest area is not the area of the heaviest file, and its total is larger than any file
    # total in the body. A client that "derived" areas by grouping `spec_files` — the substitute
    # this key exists to refuse — reads the ranking backwards on exactly this run.
    it "ranks areas by what the AREA cost, not by what its heaviest file cost" do
      body = get_repository["latest_run"]

      heaviest_area = body.dig("spec_directories", "rows").first
      heaviest_file = body.dig("spec_files", "rows").first

      expect(heaviest_file["path"]).to eq("spec/models/user_spec.rb")
      expect(heaviest_area["path"]).to eq("spec/requests")
      # The heaviest area is heavier than the heaviest FILE while holding no file as heavy as it —
      # so neither the ranking nor the total is recoverable from the block above.
      expect(heaviest_area["total_seconds"]).to be > heaviest_file["total_seconds"]
      expect(body.dig("spec_files", "rows").map { it["total_seconds"] }).to all(be < 10.0)
      # And the area total is the SUM ACROSS ITS FILES, not any one file's figure.
      expect(heaviest_area["total_seconds"]).to eq(12.0)
      expect(heaviest_area["recorded_count"]).to eq(4)
    end

    # AC8's companion: the sub-block's own key set, stated as its subject rather than pinned as a
    # side effect of the `eq` above — the pattern `contract_shard_keys` and the by-file block set,
    # and for the same reason. A guard whose stated subject IS the key set survives a fixture whose
    # numbers change, and says out loud what a new key owes this block before it ships.
    it "serves exactly the spec_directories keys this contract pins" do
      expect(spec_directories.keys).to contain_exactly("rows", "directory_count", "limit")
      expect(spec_directories["rows"].first.keys)
        .to contain_exactly("path", "total_seconds", "recorded_count", "timed_count",
                            "distinct_name_count", "named_count")
    end

    # AC5. Read off the same presenter `repositories#show` assigns rather than re-stating the
    # fixture's numbers: two independent hand-written expectations would both still pass if the
    # endpoint started reading a different run, a different limit, or re-sorted the list. The
    # ORDER is asserted as a sequence, because that is the half a `match_array` would drop and the
    # half the `NULLS LAST` in the aggregate exists to get right.
    it "serves the same rows, in the same order, that repositories#show renders" do
      shown = SpecDirectoryDurations.for(repository.latest_test_run)

      expect(spec_directories["rows"].map { it["path"] }).to eq(shown.rows.map(&:path))
      expect(spec_directories["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
      expect(spec_directories["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
      expect(spec_directories["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
      expect(spec_directories["rows"].map { it["distinct_name_count"] })
        .to eq(shown.rows.map(&:distinct_name_count))
      expect(spec_directories["rows"].map { it["named_count"] }).to eq(shown.rows.map(&:named_count))
      expect(spec_directories["directory_count"]).to eq(shown.directory_count)
    end

    # AC6. The block's standing rule, asserted over the whole serialized body rather than per key:
    # `Row#duration_label` and `#coverage_label` are one call away in the presenter this reads
    # from, and a serializer that reached for either would still satisfy every assertion above if
    # the fixture's numbers happened to render similarly.
    it "serves numbers, never the panel's labels" do
      expect(spec_directories.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(spec_directories["rows"].map { it["total_seconds"] }).to all(be_a(Float).or(be_nil))
      expect(spec_directories["rows"].map { it["recorded_count"] }).to all(be_a(Integer))
      # `Row#distinct_description_label` is the same one call away and folds "no descriptions" into
      # the value for exactly the area a client most needs to tell apart from a measured zero.
      expect(spec_directories.to_json).not_to match(/no descriptions|unnamed/)
      expect(spec_directories["rows"].map { it["distinct_name_count"] }).to all(be_a(Integer))
      expect(spec_directories["rows"].map { it["named_count"] }).to all(be_a(Integer))
    end

    # THE row the description operands exist for, and the reason both of them are served rather than
    # the distinct count alone. `COUNT(DISTINCT name)` skips NULLs, so an area whose producer sent no
    # descriptions serves `distinct_name_count: 0` — and a client dividing that by `recorded_count`
    # reads the most redundant area in the suite out of a silence nobody measured. `named_count: 0`
    # is what makes the zero readable as "nothing to count", and it is the ONLY field that can: the
    # payload carries no other figure a client could subtract to reach it.
    it "serves a zero named count beside the zero distinct count for an area carrying no descriptions" do
      observe(test_run, path: "spec/silent/one_spec.rb", duration: 1.0, line_number: 1, name: nil)
      observe(test_run, path: "spec/silent/two_spec.rb", duration: 1.0, line_number: 2, name: nil)

      silent = spec_directories["rows"].find { it["path"] == "spec/silent" }

      expect(silent["recorded_count"]).to eq(2)
      expect(silent["named_count"]).to eq(0)
      expect(silent["distinct_name_count"]).to eq(0)
    end

    # The partial area, where the two figures stop being interchangeable: the distinct count was
    # taken over the NAMED rows, so `named_count` and not `recorded_count` is the denominator a
    # client divides by, and the difference between them is what the count could not see.
    it "serves the population the distinct count was taken over, not the area's whole row count" do
      observe(test_run, path: "spec/partial/a_spec.rb", duration: 1.0, line_number: 1, name: "shared")
      observe(test_run, path: "spec/partial/b_spec.rb", duration: 1.0, line_number: 2, name: "shared")
      observe(test_run, path: "spec/partial/c_spec.rb", duration: 1.0, line_number: 3, name: nil)

      partial = spec_directories["rows"].find { it["path"] == "spec/partial" }

      expect(partial["recorded_count"]).to eq(3)
      expect(partial["named_count"]).to eq(2)
      expect(partial["distinct_name_count"]).to eq(1)
    end

    # AC3. THE row this grain has to get right, and it costs MORE here than one rung down: an area
    # is a bigger population than a file, so `0.0` for an all-untimed area is a bigger invented
    # measurement, and `SUM(...) DESC`'s NULLS FIRST would name it the heaviest AREA in the suite.
    # Both halves are asserted because they fail differently: a serializer coalescing to zero
    # passes "the area appears" and fails "the total is null".
    it "serves null, not 0.0, for an area whose examples all went untimed" do
      observe(test_run, path: "spec/silent/one_spec.rb", duration: nil, line_number: 1)
      observe(test_run, path: "spec/silent/two_spec.rb", duration: nil, line_number: 2)

      silent = spec_directories["rows"].find { it["path"] == "spec/silent" }

      expect(silent).not_to be_nil
      expect(silent["total_seconds"]).to be_nil
      # Counted across BOTH its files — the area is the population, not the file.
      expect(silent["recorded_count"]).to eq(2)
      expect(silent["timed_count"]).to eq(0)
      expect(spec_directories["rows"].last["path"]).to eq("spec/silent")
    end

    # An area whose examples were HALF timed — the state that makes a per-row denominator load
    # bearing rather than decorative, and load bearing over a wider population than a file's. The
    # total covers half the area, and the row is what says so.
    it "states per-row coverage on a partly timed area" do
      observe(test_run, path: "spec/partial/seen_spec.rb", duration: 3.0, line_number: 1)
      observe(test_run, path: "spec/partial/unseen_spec.rb", duration: nil, line_number: 1)

      partial = spec_directories["rows"].find { it["path"] == "spec/partial" }

      expect(partial["total_seconds"]).to eq(3.0)
      expect(partial["recorded_count"]).to eq(2)
      expect(partial["timed_count"]).to eq(1)
    end

    # A spec file at the REPOSITORY ROOT has no parent directory, and `DIRECTORY_EXPRESSION`
    # coalesces it to `"."` rather than dropping the row. Asserted here because it is the one input
    # at this grain that has no counterpart one rung down, and a serializer or an expression change
    # that let it fall out would silently stop the areas summing to the run.
    it "serves a root-level spec file under its coalesced area rather than dropping it" do
      observe(test_run, path: "smoke_spec.rb", duration: 2.5, line_number: 1)

      root = spec_directories["rows"].find { it["path"] == "." }

      expect(root).not_to be_nil
      expect(root["total_seconds"]).to eq(2.5)
      expect(root["recorded_count"]).to eq(1)
    end

    # AC4. The figure `rows.size` cannot supply. The list stops at the limit, so its own length
    # reads the same on "the 10 heaviest of 300" and "all 10 this run touched" — and a client with
    # only the array would report the second while looking at the first.
    it "reports how many areas the run touched in all, past the limit that cut the list" do
      limit = SpecObservation::HEAVIEST_DIRECTORIES_LIMIT
      (limit + 5).times do |index|
        observe(test_run, path: format("spec/extra_%02d/thing_spec.rb", index),
                duration: 20.0 + index, line_number: 1)
      end

      expect(spec_directories["rows"].length).to eq(limit)
      # The fixture's own two areas plus the fifteen above — asserted against the table rather than
      # against a number written twice, so this cannot agree with a miscounted `COUNT(*) OVER ()`.
      expect(spec_directories["directory_count"])
        .to eq(test_run.spec_observations.distinct.count(Arel.sql(SpecObservation::DIRECTORY_EXPRESSION)))
      expect(spec_directories["directory_count"]).to be > spec_directories["rows"].length
      expect(spec_directories["limit"]).to eq(limit)
    end
  end

  # The per-EXAMPLE grain — "which tests are slow", the question the two rollup blocks above are
  # structurally unable to answer and the one the HTML panel has answered since SPGD-266.
  describe "the latest run's slowest examples" do
    # Insertion order and duration order DIFFER on purpose. The ranking is half of what this key
    # promises, and a fixture written slowest-first would let a serializer that dropped the ORDER BY
    # — or that inherited the table's `id` order — satisfy a sequence assertion by accident.
    #
    # The four rows also span every nullable axis this block has to serve: an outcome of each of
    # the two names SpecGuard reads, one it does not read, and one row that reported no outcome at
    # all. That last one is what keeps `reported_outcome_count` from equalling `recorded_count` on
    # the happy-path fixture, so the two counts cannot be transposed unseen.
    let!(:test_run) do
      run = create_test_run(repository: repository, commit_sha: "slowest00001",
                            branch: "main", total_specs_count: 4, duration_seconds: 30.0)
      observe(run, path: "spec/models/user_spec.rb", duration: 2.0, line_number: 11,
              name: "User validates its email", outcome: "passed")
      observe(run, path: "spec/requests/checkout_spec.rb", duration: 9.5, line_number: 3,
              name: "Checkout completes an order", outcome: "failed")
      observe(run, path: "spec/models/invoice_spec.rb", duration: 0.5, line_number: 7,
              name: "Invoice totals its line items", outcome: "pending")
      observe(run, path: "spec/requests/search_spec.rb", duration: 6.25, line_number: 2,
              name: "Search ranks by relevance", outcome: nil)
      run
    end

    def slowest_examples = get_repository.dig("latest_run", "slowest_examples")

    # AC1 + AC2. Every row carries all six operands, and the array is asserted as a SEQUENCE — `eq`,
    # not `match_array` — against a fixture whose insertion order it does not match.
    it "serves each slow example's raw operands, slowest first" do
      expect(slowest_examples["rows"]).to eq(
        [
          { "name" => "Checkout completes an order",
            "file_path" => "spec/requests/checkout_spec.rb", "line_number" => 3,
            "spec_file_path" => "spec/requests/checkout_spec.rb",
            "duration_seconds" => 9.5, "outcome" => "failed" },
          { "name" => "Search ranks by relevance",
            "file_path" => "spec/requests/search_spec.rb", "line_number" => 2,
            "spec_file_path" => "spec/requests/search_spec.rb",
            "duration_seconds" => 6.25, "outcome" => nil },
          { "name" => "User validates its email",
            "file_path" => "spec/models/user_spec.rb", "line_number" => 11,
            "spec_file_path" => "spec/models/user_spec.rb",
            "duration_seconds" => 2.0, "outcome" => "passed" },
          { "name" => "Invoice totals its line items",
            "file_path" => "spec/models/invoice_spec.rb", "line_number" => 7,
            "spec_file_path" => "spec/models/invoice_spec.rb",
            "duration_seconds" => 0.5, "outcome" => "pending" }
        ]
      )
    end

    # AC3. The coverage the ranking was taken over, and the bound that cut it. `limit` is read off
    # the constant rather than written as `10`, so a change to `SLOWEST_LIMIT` cannot leave the
    # endpoint disclosing a bound it no longer applies.
    it "states what the ranking was taken over, and the bound that produced it" do
      expect(slowest_examples["recorded_count"]).to eq(4)
      expect(slowest_examples["timed_count"]).to eq(4)
      # Three of the four rows named an outcome; the fourth said nothing. Not equal to
      # `recorded_count`, so a serializer that served one figure under both names is red here.
      expect(slowest_examples["reported_outcome_count"]).to eq(3)
      expect(slowest_examples["limit"]).to eq(SpecObservation::SLOWEST_LIMIT)
    end

    # AC4. The sub-block's own key set, stated as its subject rather than pinned as a side effect
    # of the `eq` above — the pattern `contract_shard_keys` and both rollup blocks set, and for the
    # same reason. A guard whose stated subject IS the key set survives a fixture whose numbers
    # change, and says out loud what a new key owes this block before it ships.
    #
    # The row keys are pinned too, and that half is load bearing here in a way it is not one rung
    # up: the run-level outcome counters `SlowestExamples` also holds — `failed_count`,
    # `pending_count`, `other_outcome_count` — describe the run's composition rather than this
    # ranking's coverage, and this is the guard that keeps them out.
    it "serves exactly the slowest_examples keys this contract pins" do
      expect(slowest_examples.keys)
        .to contain_exactly("rows", "recorded_count", "timed_count", "reported_outcome_count",
                            "limit")
      expect(slowest_examples["rows"].first.keys)
        .to contain_exactly("name", "file_path", "line_number", "spec_file_path",
                            "duration_seconds", "outcome")
    end

    # AC6. Read off the same presenter `repositories#show` assigns to `@slowest_examples` rather
    # than re-stating the fixture's numbers: two independent hand-written expectations would both
    # still pass if the endpoint started reading a different run, a different limit, or re-sorted
    # the list. Every served axis is compared element-wise, because a serializer that zipped two
    # columns out of step would satisfy any one of them alone.
    it "serves the same rows, in the same order, that repositories#show renders" do
      shown = SlowestExamples.for(repository.latest_test_run)

      expect(slowest_examples["rows"].map { it["name"] }).to eq(shown.rows.map(&:name))
      expect(slowest_examples["rows"].map { it["file_path"] }).to eq(shown.rows.map(&:file_path))
      expect(slowest_examples["rows"].map { it["line_number"] }).to eq(shown.rows.map(&:line_number))
      expect(slowest_examples["rows"].map { it["spec_file_path"] }).to eq(shown.rows.map(&:spec_file_path))
      expect(slowest_examples["rows"].map { it["duration_seconds"] }).to eq(shown.rows.map(&:duration_seconds))
      expect(slowest_examples["rows"].map { it["outcome"] }).to eq(shown.rows.map(&:outcome))
      expect(slowest_examples["recorded_count"]).to eq(shown.recorded_count)
      expect(slowest_examples["timed_count"]).to eq(shown.timed_count)
      expect(slowest_examples["reported_outcome_count"]).to eq(shown.reported_outcome_count)
    end

    # AC2's standing rule, asserted over the whole serialized block rather than per key — and this
    # is the grain where it costs the most. FOUR label methods sit one call away on the very rows
    # this block maps (`SpecObservation#label`, `#location_label`, `#duration_label`,
    # `#outcome_label`), and each folds a fallback string into the value a client would have to
    # parse back out.
    it "serves numbers and raw strings, never the panel's labels" do
      expect(slowest_examples.to_json).not_to match(/of \d|\d+\.\d+s|not reported/)
      expect(slowest_examples["rows"].map { it["duration_seconds"] }).to all(be_a(Float))
      expect(slowest_examples["rows"].map { it["line_number"] }).to all(be_a(Integer))
      expect(slowest_examples.values_at("recorded_count", "timed_count", "reported_outcome_count",
                                        "limit")).to all(be_a(Integer))
      # `#location_label`'s join, specifically: the two operands are served as two keys, so no
      # value in this block is the string it would build from them.
      expect(slowest_examples.to_json).not_to include("spec/requests/checkout_spec.rb:3")
    end

    # THE VACUOUS GREEN CASE `SlowestExamples#outcomes_reported?` was written for, at the API grain.
    # A run whose client sends no outcomes stores a nil on every row, and `failed_count` over it is
    # zero — a zero that counts SILENCE, not health. A client holding ten null outcomes and no
    # coverage figure cannot tell that run from one where these ten happened to be the quiet ones,
    # which is exactly why `reported_outcome_count` is served beside the rows rather than left to
    # be inferred from them.
    it "distinguishes a run that reported no outcomes from one whose slowest ten were quiet" do
      silent = create_test_run(repository: repository, commit_sha: "noOutcome001", duration_seconds: 12.0)
      observe(silent, path: "spec/models/a_spec.rb", duration: 3.0, line_number: 1, name: "a", outcome: nil)
      observe(silent, path: "spec/models/b_spec.rb", duration: 1.0, line_number: 1, name: "b", outcome: nil)
      expect(repository.latest_test_run).to eq(silent)

      expect(slowest_examples["rows"].map { it["outcome"] }).to eq([nil, nil])
      expect(slowest_examples["recorded_count"]).to eq(2)
      # The figure that does the distinguishing. Zero REPORTED, over two recorded rows — and the
      # fixture at the top of this block, whose rows are equally not-all-failing, reads 3.
      expect(slowest_examples["reported_outcome_count"]).to eq(0)
    end

    # An outcome string SpecGuard does not read, echoed verbatim. Nothing platform-side validates
    # this column — `Ingest::Payload` does not — so a serializer that mapped unknown strings onto a
    # known vocabulary would be inventing a verdict the producer never sent.
    it "echoes an outcome it does not recognise rather than folding it into a known one" do
      exotic = create_test_run(repository: repository, commit_sha: "exotic000001", duration_seconds: 5.0)
      observe(exotic, path: "spec/models/a_spec.rb", duration: 3.0, line_number: 1,
              name: "a", outcome: "aborted_by_runner")
      expect(repository.latest_test_run).to eq(exotic)

      expect(slowest_examples["rows"].first["outcome"]).to eq("aborted_by_runner")
      expect(slowest_examples["reported_outcome_count"]).to eq(1)
    end

    # A row whose producer sent no description. `null` is the honest record of that, and the row is
    # still LOCATABLE — which is the whole reason the location is served as operands rather than
    # substituted through `#label`, whose fallback would put `"spec/models/a_spec.rb:1"` in the
    # `name` field and make a nameless test indistinguishable from one named after its own file.
    it "serves a nameless row as null and still locates it" do
      nameless = create_test_run(repository: repository, commit_sha: "nameless0001", duration_seconds: 5.0)
      observe(nameless, path: "spec/models/a_spec.rb", duration: 3.0, line_number: 42, name: nil)
      expect(repository.latest_test_run).to eq(nameless)

      row = slowest_examples["rows"].first

      expect(row["name"]).to be_nil
      expect(row["file_path"]).to eq("spec/models/a_spec.rb")
      expect(row["line_number"]).to eq(42)
    end

    # THREE DISTINCT COLUMNS, and the one input that proves they are three. A shared example group
    # is DEFINED in `spec/support/` and INCLUDED by the file that ran it, so `file_path` and
    # `spec_file_path` genuinely differ — and `line_number` belongs to the first of them, never to
    # the second. Serving `spec_file_path` is also what makes this block JOINABLE: it is the column
    # the two rollups aggregate on, so a client can carry a ranked test back to its rollup row.
    it "keeps the definition site and the including file as separate operands" do
      shared = create_test_run(repository: repository, commit_sha: "sharedex0001", duration_seconds: 5.0)
      observe(shared, path: "spec/models/user_spec.rb", defined_in: "spec/support/shared_examples.rb",
              duration: 3.0, line_number: 8, name: "behaves like an auditable record")
      expect(repository.latest_test_run).to eq(shared)

      row = slowest_examples["rows"].first

      expect(row["file_path"]).to eq("spec/support/shared_examples.rb")
      expect(row["line_number"]).to eq(8)
      expect(row["spec_file_path"]).to eq("spec/models/user_spec.rb")
      # And the rollup one rung up aggregated on the INCLUDING file, which is what the join is for.
      expect(get_repository.dig("latest_run", "spec_files", "rows").first["path"])
        .to eq(row["spec_file_path"])
    end

    # Untimed rows are OUT of the ranking and IN the coverage — the separation `slowest_in`'s
    # `.timed` scope and `coverage_in`'s two different COUNTs exist to make. A client dividing
    # `timed_count` by `recorded_count` learns the ranking covered four of six examples; one
    # holding only the rows would report six.
    it "ranks only the timed rows while counting all of them" do
      observe(test_run, path: "spec/models/silent_spec.rb", duration: nil, line_number: 1, name: "silent one")
      observe(test_run, path: "spec/models/silent_spec.rb", duration: nil, line_number: 2, name: "silent two")

      expect(slowest_examples["rows"].map { it["name"] }).not_to include("silent one", "silent two")
      expect(slowest_examples["rows"].length).to eq(4)
      expect(slowest_examples["recorded_count"]).to eq(6)
      expect(slowest_examples["timed_count"]).to eq(4)
    end

    # AC3's figure that `rows.size` cannot supply. The list stops at the limit, so its own length
    # reads the same on "the 10 slowest of 300" and "all 10 this run timed" — and a client with only
    # the array would report the second while looking at the first.
    it "reports how many examples the run recorded in all, past the limit that cut the list" do
      limit = SpecObservation::SLOWEST_LIMIT
      (limit + 5).times do |index|
        observe(test_run, path: "spec/extra_spec.rb", duration: 20.0 + index, line_number: index,
                name: "extra #{index}", outcome: "passed")
      end

      expect(slowest_examples["rows"].length).to eq(limit)
      # Counted against the table rather than against a number written twice, so this cannot agree
      # with a miscounted aggregate.
      expect(slowest_examples["recorded_count"]).to eq(test_run.spec_observations.count)
      expect(slowest_examples["recorded_count"]).to be > slowest_examples["rows"].length
      expect(slowest_examples["limit"]).to eq(limit)
      # And the list really is the SLOWEST ten, not the first ten the limit happened to reach.
      expect(slowest_examples["rows"].first["duration_seconds"]).to eq(34.0)
    end

    # THE REASON THIS KEY IS SERVED AT ALL, stated as a guard rather than as a comment. Every
    # figure is read off the endpoint's own response, so it is the three blocks disagreeing with
    # each other: the heaviest AREA holds none of the two slowest TESTS, and no rollup row names a
    # test. A client that "derived" slow tests from the rollups — the substitute this key exists to
    # refuse — has no row to name and no name to report.
    it "names a test, which neither rollup beside it can" do
      # Two hundred cheap examples in one file: heaviest area AND heaviest file by SUM, with not
      # one of its rows anywhere near the head of the ranking. Concentration and outliers are
      # different questions, and this fixture is the run where the two answers disagree.
      200.times do |index|
        observe(test_run, path: "spec/bulk/a_spec.rb", duration: 0.1, line_number: index,
                name: "bulk #{index}")
      end
      body = get_repository["latest_run"]

      expect(body.dig("spec_directories", "rows").first["path"]).to eq("spec/bulk")
      expect(body.dig("spec_files", "rows").first["path"]).to eq("spec/bulk/a_spec.rb")
      # The slowest TEST is in neither of them — so the ranking is not recoverable by reading a
      # rollup and opening its top row, which is the substitute this key exists to refuse.
      expect(body.dig("slowest_examples", "rows").first["name"]).to eq("Checkout completes an order")
      expect(body.dig("slowest_examples", "rows").first["spec_file_path"]).to eq("spec/requests/checkout_spec.rb")
      # And no rollup row carries a name at all, at either grain: they rank populations, and a
      # population has no description to report.
      expect(body.dig("spec_files", "rows").first.keys).not_to include("name")
      expect(body.dig("spec_directories", "rows").first.keys).not_to include("name")
    end
  end

  # WHICH DESCRIPTIONS this run recorded more than once, ranked by what those examples cost between
  # them — the agent-readable twin of the "Descriptions this run recorded more than once" panel
  # `repositories#show` has rendered since SPGD-344, and the fifth and last run-grain panel to cross
  # to this endpoint.
  #
  # The grain is unlike the four blocks above it. Those roll one run's rows up by where the code
  # LIVES — the example, its file, its area — and no rollup of "where" can see that two of those
  # rows claim to test the same thing. So nothing in this block is satisfiable by a rollup of the
  # blocks beside it, and the last example here is the one that says so as a guard.
  describe "the latest run's repeated descriptions" do
    # Built so a ranking by COST and a ranking by GROUP SIZE disagree, which is the whole reason the
    # aggregate orders the way it does: three examples costing 90 seconds outrank four costing two.
    # A fixture whose biggest group were also its costliest would let a serializer that inherited
    # `COUNT(*)` order satisfy the sequence assertion by accident.
    #
    # Insertion order is neither of those orders either, so the table's own `id` order is a third
    # wrong answer this fixture is red for.
    #
    # Every axis the block has to serve is spanned: a fully timed group, a partly timed one, a group
    # nothing timed at all (which must sort LAST), a group spanning two files against one living in
    # a single file, a description carried by exactly ONE example — which is not repetition and must
    # be absent — and rows carrying no description at all, which cannot be grouped and are counted
    # separately. The single-example row is the COSTLIEST row in the run, so a read that dropped the
    # `HAVING COUNT(*) > 1` would head the list with it rather than merely lengthen it.
    let!(:test_run) do
      run = create_test_run(repository: repository, commit_sha: "repeated0001",
                            branch: "main", total_specs_count: 12, duration_seconds: 120.0)
      # Four examples, two files, two of them untimed. Inserted with the alphabetically LATER file
      # first, so `files_seen`' sort is doing work rather than echoing insertion order.
      observe(run, path: "spec/requests/checkout_spec.rb", duration: 1.0, line_number: 1,
              name: "Checkout completes an order")
      observe(run, path: "spec/requests/checkout_spec.rb", duration: 1.0, line_number: 2,
              name: "Checkout completes an order")
      observe(run, path: "spec/models/order_spec.rb", duration: nil, line_number: 3,
              name: "Checkout completes an order")
      observe(run, path: "spec/models/order_spec.rb", duration: nil, line_number: 4,
              name: "Checkout completes an order")
      # Two examples, neither timed — the group with no total to rank.
      observe(run, path: "spec/models/search_spec.rb", duration: nil, line_number: 5,
              name: "Search ranks by relevance")
      observe(run, path: "spec/models/search_spec.rb", duration: nil, line_number: 6,
              name: "Search ranks by relevance")
      # Three examples, 90 seconds between them: fewer rows than the group above and forty-five
      # times its cost.
      3.times do |index|
        observe(run, path: "spec/models/invoice_spec.rb", duration: 30.0, line_number: 7 + index,
                name: "Invoice totals its line items")
      end
      # Carried by ONE example, and the most expensive row in the run. Not repetition.
      observe(run, path: "spec/models/user_spec.rb", duration: 500.0, line_number: 10,
              name: "User validates its email")
      # Two rows the producer never described. Excluded from the grouping in SQL, counted by the
      # second read, and pooling them would invent the largest repetition on the page.
      observe(run, path: "spec/models/legacy_spec.rb", duration: 7.0, line_number: 11, name: nil)
      observe(run, path: "spec/models/legacy_spec.rb", duration: nil, line_number: 12, name: nil)
      run
    end

    def repeated_descriptions = get_repository.dig("latest_run", "repeated_descriptions")

    # AC1 + AC2 + AC4. Every row carries all five operands, and the array is asserted as a SEQUENCE
    # — `eq`, not `match_array` — against a fixture whose insertion order it does not match and
    # whose group sizes rank it the other way round.
    #
    # THE UNTIMED GROUP IS LAST, which is `NULLS LAST` doing its job: Postgres sorts NULLs FIRST on
    # a `DESC` order by default, so a read that dropped the clause would head a list about what
    # repetition COST with the one group nobody measured.
    #
    # `total_seconds` is `null` on that group and never `0.0`: a group nothing timed has no total,
    # and a zero would assert three examples that ran instantly.
    #
    # `files_seen` is SORTED rather than in insertion order, and the multi-file group is inserted
    # later-file-first so that is a real assertion.
    it "serves each repeated description's raw operands, costliest first" do
      expect(repeated_descriptions["rows"]).to eq(
        [
          { "name" => "Invoice totals its line items", "total_seconds" => 90.0,
            "recorded_count" => 3, "timed_count" => 3,
            "files_seen" => ["spec/models/invoice_spec.rb"] },
          { "name" => "Checkout completes an order", "total_seconds" => 2.0,
            "recorded_count" => 4, "timed_count" => 2,
            "files_seen" => ["spec/models/order_spec.rb", "spec/requests/checkout_spec.rb"] },
          { "name" => "Search ranks by relevance", "total_seconds" => nil,
            "recorded_count" => 2, "timed_count" => 0,
            "files_seen" => ["spec/models/search_spec.rb"] }
        ]
      )
    end

    # A description carried by ONE example is not repetition, and this fixture's single-example row
    # is the costliest row in the run — so a read that lost `HAVING COUNT(*) > 1` would not merely
    # add a row, it would put that row at the head of the ranking. Its own example rather than an
    # inference from the `eq` above, because the sequence assertion would report the failure as a
    # length mismatch and name nothing.
    it "leaves a description only one example carried out of the ranking" do
      expect(repeated_descriptions["rows"].map { it["name"] }).not_to include("User validates its email")
      expect(test_run.spec_observations.where(name: "User validates its email").count).to eq(1)
    end

    # AC3. The four honesty figures and the two bounds, each pinned against what the fixture wrote
    # rather than against a number that only agrees with itself.
    #
    # `repeated_recorded_count` / `repeated_timed_count` are over the whole REPEATED population —
    # nine examples under three descriptions, five of them timed — and not over the run: the single
    # example and the two unnamed rows are outside them, which is what makes them different figures
    # from `recorded_count` rather than a second spelling of it.
    #
    # `limit` is read off the constant rather than written as `10`, so a change to
    # `REPEATED_DESCRIPTIONS_LIMIT` cannot leave the endpoint disclosing a bound it no longer
    # applies.
    it "states the population it grouped, the rows it could not, and the bound that cut the list" do
      expect(repeated_descriptions["group_count"]).to eq(3)
      expect(repeated_descriptions["recorded_count"]).to eq(12)
      expect(repeated_descriptions["unnamed_row_count"]).to eq(2)
      expect(repeated_descriptions["repeated_recorded_count"]).to eq(9)
      expect(repeated_descriptions["repeated_timed_count"]).to eq(5)
      expect(repeated_descriptions["limit"]).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
      # Counted against the table rather than against a number written twice here.
      expect(repeated_descriptions["recorded_count"]).to eq(test_run.spec_observations.count)
    end

    # AC6, and the reason both figures are served rather than the difference between them. A client
    # holding `recorded_count` and `unnamed_row_count` holds `named_row_count`'s two operands and
    # can tell "ten of these twelve rows were described" from "none of them were" — the distinction
    # `#named?` draws, WITHOUT this endpoint shipping the predicate or the subtraction.
    it "hands the client both operands of named_row_count rather than the subtraction" do
      shown = RepeatedDescriptions.for(repository.latest_test_run)

      expect(repeated_descriptions["recorded_count"] - repeated_descriptions["unnamed_row_count"])
        .to eq(shown.named_row_count)
      expect(repeated_descriptions.keys).not_to include("named_row_count", "named")
    end

    # AC5's first half, and the shape a truncated list would otherwise wear. `rows.size` alone reads
    # identically on "the 10 costliest of 80" and "all 3", so `group_count` is the figure that tells
    # them apart — the `COUNT(*) OVER ()` counted after the `HAVING` and before the `LIMIT`.
    it "reports how many descriptions were repeated in all, past the limit that cut the list" do
      limit = SpecObservation::REPEATED_DESCRIPTIONS_LIMIT
      (limit + 5).times do |index|
        2.times do |copy|
          observe(test_run, path: "spec/extra_spec.rb", duration: 100.0 + index,
                  line_number: (index * 2) + copy + 100, name: "extra #{index}")
        end
      end

      expect(repeated_descriptions["rows"].length).to eq(limit)
      expect(repeated_descriptions["group_count"]).to eq(limit + 5 + 3)
      expect(repeated_descriptions["group_count"]).to be > repeated_descriptions["rows"].length
      expect(repeated_descriptions["limit"]).to eq(limit)
      # And the window pair describes the WHOLE repeated population rather than the ten rows that
      # fit — the figure a client would otherwise read off a truncated head and call complete.
      expect(repeated_descriptions["repeated_recorded_count"]).to eq(9 + ((limit + 5) * 2))
    end

    # AC1's last clause, and the one state that tells `Row#files_seen` apart from the raw
    # `ARRAY_AGG(DISTINCT spec_file_path) FILTER (WHERE spec_file_path IS NOT NULL)` it wraps. On
    # every group above, the two are byte-identical — Postgres sorts as a byproduct of the DISTINCT,
    # and nothing filtered — so no assertion up there can see the difference. Here every row of the
    # group carries a nil including file, the FILTER removes them all, and the aggregate is SQL NULL
    # rather than an empty array. `files_seen` is `Array()`-normalized, so the key is `[]`.
    #
    # A `null` here would be a third meaning for the key — "we do not know where these ran" spelled
    # the same way an absent value is — that no client could tell from the absence of a group.
    it "serves an empty array, not null, for a group whose rows named no including file" do
      unlocated = create_test_run(repository: repository, commit_sha: "unlocated001", duration_seconds: 9.0)
      2.times do |index|
        observe(unlocated, path: "spec/support/shared.rb", included_by: nil, duration: 1.0,
                line_number: index, name: "behaves like an auditable record")
      end
      expect(repository.latest_test_run).to eq(unlocated)

      row = repeated_descriptions["rows"].first

      # The nil really did reach the column, so this is the aggregate's NULL and not a fixture that
      # happened to write an empty string.
      expect(unlocated.spec_observations.pluck(:spec_file_path)).to eq([nil, nil])
      expect(row["files_seen"]).to eq([])
      expect(row["recorded_count"]).to eq(2)
    end

    # AC7. Read off the same presenter `repositories#show` assigns to `@repeated_descriptions`
    # rather than re-stating the fixture's numbers: two independent hand-written expectations would
    # both still pass if the endpoint started reading a different run, a different limit, or
    # re-sorted the list. Every served axis is compared element-wise, because a serializer that
    # zipped two columns out of step would satisfy any one of them alone.
    it "serves the same rows, in the same order, that repositories#show renders" do
      shown = RepeatedDescriptions.for(repository.latest_test_run)

      expect(repeated_descriptions["rows"].map { it["name"] }).to eq(shown.rows.map(&:name))
      expect(repeated_descriptions["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
      expect(repeated_descriptions["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
      expect(repeated_descriptions["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
      expect(repeated_descriptions["rows"].map { it["files_seen"] }).to eq(shown.rows.map(&:files_seen))
      expect(repeated_descriptions["group_count"]).to eq(shown.group_count)
      expect(repeated_descriptions["recorded_count"]).to eq(shown.recorded_count)
      expect(repeated_descriptions["unnamed_row_count"]).to eq(shown.unnamed_row_count)
      expect(repeated_descriptions["repeated_recorded_count"]).to eq(shown.repeated_recorded_count)
      expect(repeated_descriptions["repeated_timed_count"]).to eq(shown.repeated_timed_count)
    end

    # AC2's standing rule, asserted over the whole serialized block rather than per key. Two label
    # methods sit one call away on the very rows this block maps: `Row#duration_label` renders
    # `"1.23s"` or `"not reported"`, and `Row#coverage_label` renders `"6 of 8"`. Both are sentences
    # a client would have to parse back into the numbers they were built from.
    it "serves numbers, never the panel's labels" do
      expect(repeated_descriptions.to_json).not_to match(/\d+ of \d+|\d+\.\d+s|not reported/)
      expect(repeated_descriptions["rows"].map { it["recorded_count"] }).to all(be_a(Integer))
      expect(repeated_descriptions["rows"].map { it["timed_count"] }).to all(be_a(Integer))
      expect(repeated_descriptions["rows"].filter_map { it["total_seconds"] }).to all(be_a(Float))
      expect(repeated_descriptions.values_at("group_count", "recorded_count", "unnamed_row_count",
                                             "repeated_recorded_count", "repeated_timed_count",
                                             "limit")).to all(be_a(Integer))
    end

    # AC4's other half. The object deliberately carries no `#redundant?` — a description carried by
    # several examples is evidence of repetition AND the ordinary shape of a table-driven loop or a
    # shared example group, and nothing here decides which — so the response carries no verdict key
    # either. Nor does it ship the comparisons the client can make itself.
    it "presents the ranking without judging it, and ships operands rather than predicates" do
      expect(repeated_descriptions.keys)
        .not_to include("redundant", "truncated", "complete", "any_timed", "recorded")
      expect(repeated_descriptions["rows"].first.keys).not_to include("timed", "redundant")
    end

    # AC3's key set, stated as this example's subject rather than pinned as a side effect of the
    # `eq` above — the pattern all four sibling blocks set. A guard whose stated subject IS the key
    # set survives a fixture whose numbers change, and says out loud what a new key owes this block
    # before it ships.
    #
    # The row keys are pinned too, and that half is load bearing here: `Row` is a `Struct`, so
    # `#to_h` would serialize `file_paths` — the raw, unsorted, possibly-`nil` `ARRAY_AGG` — beside
    # or instead of `files_seen`, and this is the guard that keeps it out.
    it "serves exactly the repeated_descriptions keys this contract pins" do
      expect(repeated_descriptions.keys)
        .to contain_exactly("rows", "group_count", "recorded_count", "unnamed_row_count",
                            "repeated_recorded_count", "repeated_timed_count", "limit")
      expect(repeated_descriptions["rows"].first.keys)
        .to contain_exactly("name", "total_seconds", "recorded_count", "timed_count", "files_seen")
    end

    # THE REASON THIS KEY IS SERVED AT ALL, stated as a guard rather than as a comment. Every figure
    # is read off the endpoint's own response, so it is the blocks disagreeing with each other: the
    # heaviest file and the slowest test are both the single-example row this ranking excludes, and
    # no row of any block beside this one can say that three examples claim to test the same thing.
    it "names a repetition, which no block beside it can" do
      body = get_repository["latest_run"]

      # The costliest FILE and the slowest TEST are the run's one unrepeated example — so a client
      # reading either rollup and opening its top row lands on the row this ranking excludes.
      expect(body.dig("spec_files", "rows").first["path"]).to eq("spec/models/user_spec.rb")
      expect(body.dig("slowest_examples", "rows").first["name"]).to eq("User validates its email")
      # And the costliest REPETITION is a different row set entirely.
      expect(body.dig("repeated_descriptions", "rows").first["name"])
        .to eq("Invoice totals its line items")
      # No block beside this one carries a group size at the description grain: the rollups rank
      # populations by WHERE code lives, and the ranking beside them ranks individuals.
      expect(body.dig("spec_files", "rows").first.keys).not_to include("name")
      expect(body.dig("slowest_examples", "rows").first.keys).not_to include("recorded_count")
    end
  end

  # AC5, and the distinction the whole block exists for. Three runs produce an empty ranking and
  # only one of them is a run with nothing to say — *Vacuous Green* at this grain, and the reason
  # `#recorded?`, `#named?` and `#any?` are three predicates rather than one.
  describe "a run whose ranking is empty for three different reasons" do
    # A run that wrote NO rows. `null`, key present, on `slowest_examples`' rule verbatim — never a
    # zeroed block, because a `recorded_count: 0` beside an empty array would assert a run that ran
    # no examples. Its own example lives in the block below, beside its three siblings' nulls; this
    # one is here so the three empty states can be compared side by side.
    it "serves null for a run that recorded nothing, and a block for one that recorded and repeated nothing" do
      silent = create_test_run(repository: repository, commit_sha: "empty0000001", duration_seconds: 42.5)
      expect(silent.spec_observations).to be_empty
      expect(repository.latest_test_run).to eq(silent)

      expect(get_repository.dig("latest_run", "repeated_descriptions")).to be_nil

      unique = create_test_run(repository: repository, commit_sha: "empty0000002", duration_seconds: 42.5)
      3.times do |index|
        observe(unique, path: "spec/a_spec.rb", duration: 1.0, line_number: index, name: "unique #{index}")
      end
      expect(repository.latest_test_run).to eq(unique)

      block = get_repository.dig("latest_run", "repeated_descriptions")

      # THE HONEST ZERO. The block is SERVED, with an empty ranking and a zero `group_count` over a
      # run that really did describe three examples and repeat none of them — the state a
      # `rows.any?` gate would blank, telling a client the run disclosed no description grain when
      # it disclosed three examples' worth.
      expect(block).not_to be_nil
      expect(block["rows"]).to eq([])
      expect(block["group_count"]).to eq(0)
      expect(block["recorded_count"]).to eq(3)
      expect(block["unnamed_row_count"]).to eq(0)
      expect(block["repeated_recorded_count"]).to eq(0)
      expect(block["repeated_timed_count"]).to eq(0)
    end

    # AC6. The third empty state, and the one the two figures above exist to separate from the
    # second. A producer that sends no `name` stores a nil on every row — `Ingest::ObservationRecorder`
    # writes it through `presence_of` — so the grouping has nothing to group and returns the SAME
    # empty list a suite of entirely unique descriptions returns. "Nobody told us what these tests
    # are called" is not "every test here is unique", and `unnamed_row_count` against
    # `recorded_count` is what tells a client which one it is holding.
    it "distinguishes a run nobody described from one whose every description is unique" do
      nameless = create_test_run(repository: repository, commit_sha: "empty0000003", duration_seconds: 42.5)
      5.times { |index| observe(nameless, path: "spec/a_spec.rb", duration: 1.0, line_number: index, name: nil) }
      expect(repository.latest_test_run).to eq(nameless)

      block = get_repository.dig("latest_run", "repeated_descriptions")

      expect(block["rows"]).to eq([])
      expect(block["group_count"]).to eq(0)
      # Every row excluded before the grouping — so `named_row_count` is zero, and the empty
      # ranking above it is silence rather than a finding.
      expect(block["recorded_count"]).to eq(5)
      expect(block["unnamed_row_count"]).to eq(5)
      # The comparison a client makes, and the one the block beside it answers the other way.
      expect(block["recorded_count"] - block["unnamed_row_count"]).to eq(0)
    end

    # The fourth state, which is not empty at all and is the one `#recorded?` is chosen over
    # `#any_timed?` to protect. A run that recorded repetition and timed NONE of it has a real
    # ranking with no order to it — every `total_seconds` null — and the block is served with the
    # rows in it, because "we found repetition and nobody measured it" is a finding and blanking it
    # would be the same silence one rung down.
    it "serves the repetition it found even when nothing under it was timed" do
      untimed = create_test_run(repository: repository, commit_sha: "empty0000004", duration_seconds: 42.5)
      2.times { |index| observe(untimed, path: "spec/a_spec.rb", duration: nil, line_number: index, name: "twice") }
      expect(repository.latest_test_run).to eq(untimed)

      block = get_repository.dig("latest_run", "repeated_descriptions")

      expect(block["rows"].length).to eq(1)
      expect(block["rows"].first["total_seconds"]).to be_nil
      expect(block["rows"].first["recorded_count"]).to eq(2)
      expect(block["rows"].first["timed_count"]).to eq(0)
      expect(block["repeated_timed_count"]).to eq(0)
      expect(block["repeated_recorded_count"]).to eq(2)
    end
  end

  # AC2. The whole pre-SPGD-255 corpus, plus every client that sends no per-example detail.
  describe "a run that recorded no per-example rows" do
    it "serves spec_files as null, with the key still present" do
      create_test_run(repository: repository, commit_sha: "norows000001", duration_seconds: 42.5)

      block = get_repository["latest_run"]

      # Asserted as the REASON rather than the null alone: a hard-coded `be_nil` here would keep
      # passing if the gate stopped being `#recorded?` and started being something else that
      # happens to be false on this fixture.
      expect(repository.latest_test_run.spec_observations).to be_empty
      expect(block).to have_key("spec_files")
      expect(block["spec_files"]).to be_nil
    end

    # AC2 at the grain above, and its own example rather than a third `expect` in the one above:
    # the two keys are gated by two different presenters' `#recorded?`, so a change that unblanked
    # one leaves the other's guard green and must be named by a red example of its own.
    it "serves spec_directories as null, with the key still present" do
      create_test_run(repository: repository, commit_sha: "norows000002", duration_seconds: 42.5)

      block = get_repository["latest_run"]

      expect(repository.latest_test_run.spec_observations).to be_empty
      expect(block).to have_key("spec_directories")
      expect(block["spec_directories"]).to be_nil
    end

    # AC1 at the per-example grain, and its own example on the rule the two above set: three keys
    # gated by three different presenters' `#recorded?`, so a change that unblanked one leaves the
    # others' guards green and must be named by a red example of its own.
    #
    # The gate is `SlowestExamples#recorded?`, NOT `#any?`, and that distinction has no counterpart
    # in the two blocks above. A run that recorded fifty examples and timed none of them has an
    # EMPTY ranking over a real per-example grain, and `#recorded?` serves the block for it while
    # `rows.any?` would blank it — asserting the run whose observations are genuinely absent is
    # what keeps this example about the gate rather than about the emptiness of the array.
    it "serves slowest_examples as null, with the key still present" do
      create_test_run(repository: repository, commit_sha: "norows000003", duration_seconds: 42.5)

      block = get_repository["latest_run"]

      expect(repository.latest_test_run.spec_observations).to be_empty
      expect(block).to have_key("slowest_examples")
      expect(block["slowest_examples"]).to be_nil
    end

    # The other side of that gate, and the reason it is `#recorded?`. This run RECORDED rows and
    # timed none of them, so there is a per-example grain to disclose and an empty ranking over it
    # — the state a `rows.any?` gate would serve as `null`, telling a client the run reported no
    # per-example detail when it reported fifty examples' worth.
    it "serves the block, with an empty ranking, for a run that recorded rows and timed none" do
      untimed = create_test_run(repository: repository, commit_sha: "untimed00001", duration_seconds: 42.5)
      3.times { |index| observe(untimed, path: "spec/a_spec.rb", duration: nil, line_number: index, name: "a#{index}") }
      expect(repository.latest_test_run).to eq(untimed)

      block = get_repository.dig("latest_run", "slowest_examples")

      expect(block).not_to be_nil
      expect(block["rows"]).to eq([])
      expect(block["recorded_count"]).to eq(3)
      expect(block["timed_count"]).to eq(0)
    end

    # AC5 at the by-description grain, and its own example on the rule the three above set: four
    # keys gated by four different presenters' `#recorded?`, so a change that unblanked one leaves
    # the others' guards green and must be named by a red example of its own.
    #
    # The gate is `RepeatedDescriptions#recorded?`, NOT `#any?` — the object's class comment is
    # explicit that "this run reported no tests", "this run reported no descriptions" and "nothing
    # was repeated" are three different facts. The other side of this gate, where a run with rows
    # and no repetition gets a served block with an honest zero over it, is asserted in "a run whose
    # ranking is empty for three different reasons" above; asserting the run whose observations are
    # genuinely ABSENT is what keeps this example about the gate rather than about the emptiness of
    # the array.
    it "serves repeated_descriptions as null, with the key still present" do
      create_test_run(repository: repository, commit_sha: "norows000004", duration_seconds: 42.5)

      block = get_repository["latest_run"]

      expect(repository.latest_test_run.spec_observations).to be_empty
      expect(block).to have_key("repeated_descriptions")
      expect(block["repeated_descriptions"]).to be_nil
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
        # ⚠️ NO `intent_readings` HERE, and its absence is the point of this line rather than an
        # omission. `latest_run` carries it; a HISTORY row does not. It is one aggregate over one
        # run's per-example rows, and a window of thirty history rows would be thirty of them — the
        # N+1 every "reads it once whatever the history holds" example in this file exists to
        # refuse. The history's job is to be DIFFERENCED, and the counters above are what a client
        # differences; a reading is a fact about the run in front of you.
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
        "annotated_specs" => 10, "annotated_ratio" => 0.25,
        # Present and four zeros, unlike the eight nulls below it, and the difference is what each
        # key's absence would MEAN. Those are null because nothing was asked or nothing was
        # recorded; this is always served, because a correction a client has to opt into leaves it
        # reading `total_specs - annotated_specs` as the count of what SpecGuard cannot see.
        "intent_readings" => { "authored" => 0, "derived" => 0, "unreadable" => 0, "recorded" => 0 },
        "duration_seconds" => 42.5,
        "shards" => nil, "spec_files" => nil, "spec_directories" => nil,
        "slowest_examples" => nil, "repeated_descriptions" => nil,
        # Null because this request asked for no area — the key present and unasked, exactly as it
        # was before the drill-in existed and on every request that does not send the parameter.
        "spec_directory_files" => nil,
        # And null because it asked for no file either — the key present and unasked, exactly as it
        # was before the drill-in existed and on every request that does not send the parameter.
        "spec_file_examples" => nil,
        # And null because it asked for no description either, on the same rule and for the same
        # reason as the two above it.
        "repeated_description_examples" => nil,
        # And null because it asked for no unannotated listing either. The same rule as the three
        # above it, arrived at from the other side: this key's `null` is a fact about the REQUEST,
        # and the empty answer it must never be confused with — a fully-annotated run — is a present
        # block with `recorded_count: 0`.
        "unannotated_examples" => nil,
        # And the ranking above it, null from the SAME ask rather than one of its own — the two
        # annotation keys share `?unannotated_examples=` and are therefore absent together.
        "unannotated_directories" => nil,
        "suite_size_measured" => true,
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
        .to contain_exactly("repository", "api_key", "delivery_health", "credential_health",
                            "run_anchor", "latest_run",
                            "history_window", "history",
                            "unstable_tests_window", "unstable_tests",
                            "directory_growth_window", "directory_growth",
                            "directory_run_growth_window", "directory_run_growth",
                            "directory_runtime_growth_window", "directory_runtime_growth",
                            "directory_run_file_growth_window", "directory_run_file_growth",
                            "directory_runtime_file_growth_window", "directory_runtime_file_growth",
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

  # NAMING THE RUN WITH `?commit_sha=` — the one parameter on this endpoint that re-anchors rather
  # than narrows, and the counterpart to the block above rather than a variant of it. `?branch=` asks
  # about a SERIES and leaves `latest_run` exactly where it was (the block above pins that, and
  # deliberately); this asks WHICH RUN, and everything hanging off the anchor moves with it.
  #
  # The coherence property is what these examples are really for. `Api::V1::RepositoriesController`
  # re-anchors ONE memo, and every run-grain block reads through it, so the failure worth pinning is
  # not "does `latest_run` move" but "does anything fail to move with it" — a response serving
  # `latest_run` on the named sha beside a growth window anchored on a different one would be
  # internally inconsistent in a way no single-block assertion catches.
  describe "naming the run with ?commit_sha=" do
    # Three runs on three shas, OLDEST NAMED. Deliberately not the newest and not the second: the
    # target must be a row the endpoint would never have picked by itself, so an implementation that
    # ignored the parameter entirely — or that read it and then fell back — is red rather than
    # accidentally green. All three carry different suite figures for the same reason.
    #
    # One branch throughout, so `previous_test_run_on_branch` has an honest baseline to find for the
    # named run: the growth-window agreement example below needs the anchor to have a predecessor,
    # and a branch-per-run fixture would serve `no_previous_run` and pass vacuously.
    def three_run_history
      first = create_test_run(repository: repository, commit_sha: "aaa000000001", branch: "main",
                              total_specs_count: 10, annotated_specs_count: 2, duration_seconds: 1.5)
      second = create_test_run(repository: repository, commit_sha: "bbb000000002", branch: "main",
                               total_specs_count: 20, annotated_specs_count: 8, duration_seconds: 2.5)
      third = create_test_run(repository: repository, commit_sha: "ccc000000003", branch: "main",
                              total_specs_count: 30, annotated_specs_count: 15, duration_seconds: 3.5)

      [first, second, third]
    end

    # AC1's headline, stated against `latest_run` itself before the rollups below narrow in on the
    # blocks that hang off it. Asserted as a WHOLE-BLOCK comparison against the default call's, so
    # this cannot pass by the sha moving while the figures beside it stayed on the newest run — the
    # exact half-re-anchored shape the single-memo design exists to prevent.
    it "anchors latest_run on the named run rather than on the newest" do
      first, _second, third = three_run_history

      default = get_repository
      named = get_repository(query: { commit_sha: first.commit_sha })

      expect(response).to have_http_status(:ok)
      expect(default["latest_run"]).to include("commit_sha" => third.commit_sha,
                                               "total_specs" => 30, "annotated_specs" => 15,
                                               "duration_seconds" => 3.5)
      expect(named["latest_run"]).to include("commit_sha" => first.commit_sha,
                                             "total_specs" => 10, "annotated_specs" => 2,
                                             "annotated_ratio" => 0.2, "duration_seconds" => 1.5)
    end

    # AC1's other half — THE FIVE ROLLUPS AND THE THREE DRILL-INS, every block that hangs off the
    # anchor, asserted in ONE response so "they all describe the same run" is a property of the body
    # rather than of eight separate requests.
    #
    # The fixture gives the two runs DIFFERENT rows at every grain, which is what makes each
    # assertion discriminating: the named run's file, area, slowest example and repeated description
    # are all absent from the newest run, so a block that failed to re-anchor serves the newest run's
    # rows and is red on its own name rather than merely on a count.
    it "re-anchors all five rollups and all three drill-ins onto the named run" do
      named_run = create_test_run(repository: repository, commit_sha: "old000000001", branch: "main",
                                  total_specs_count: 2, duration_seconds: 9.0)
      2.times do |line|
        observe(named_run, path: "spec/legacy/audit_spec.rb", duration: 4.0 + line, line_number: line,
                           name: "audits the ledger")
      end
      newest = create_test_run(repository: repository, commit_sha: "new000000002", branch: "main",
                               total_specs_count: 1, duration_seconds: 1.0)
      observe(newest, path: "spec/models/order_spec.rb", duration: 0.5, line_number: 1,
                      name: "totals the order")

      body = get_repository(query: { commit_sha: named_run.commit_sha,
                                     spec_directory: "spec/legacy",
                                     spec_file: "spec/legacy/audit_spec.rb",
                                     repeated_description: "audits the ledger" })
      block = body["latest_run"]

      expect(block["commit_sha"]).to eq(named_run.commit_sha)
      # The by-file and by-area rollups, ranking the named run's rows and not the newest run's.
      expect(block["spec_files"]["rows"].map { |row| row["path"] })
        .to eq(["spec/legacy/audit_spec.rb"])
      expect(block["spec_directories"]["rows"].map { |row| row["path"] }).to eq(["spec/legacy"])
      # The per-example ranking and the by-description ranking, likewise.
      expect(block["slowest_examples"]["rows"].map { |row| row["name"] })
        .to all(eq("audits the ledger"))
      expect(block["repeated_descriptions"]["rows"].map { |row| row["name"] })
        .to eq(["audits the ledger"])
      # The three drill-ins, each opened by its own parameter ON the re-anchored run. A drill-in that
      # read the newest run would find no rows for these asks and serve an empty panel.
      expect(block["spec_directory_files"]["rows"].map { |row| row["path"] })
        .to eq(["spec/legacy/audit_spec.rb"])
      expect(block["spec_file_examples"]["rows"].map { |row| row["name"] })
        .to all(eq("audits the ledger"))
      expect(block["repeated_description_examples"]["rows"].map { |row| row["name"] })
        .to all(eq("audits the ledger"))
      # The fifth rollup. Null here because this fixture's run has one part — the KEY's presence is
      # what is asserted, on the same rule the block itself follows.
      expect(block).to have_key("shards")
    end

    # `shards` re-anchored, on its own fixture because the rollup example above cannot reach it: a
    # sharded run needs `test_run_shards` rows, and a run that has them is exactly the run the naive
    # fixture does not build. Named run sharded, newest run not — so a block reading the newest run
    # serves `null` and is red rather than merely differently-shaped.
    #
    # Written locally rather than reusing the `sharded_run` helper the shard block upstairs defines:
    # RSpec scopes a `def` to its own example group, so that one is INVISIBLE here — the same
    # scoping fact the note at the top of this file records about `observation_reads`. This needs
    # only the two rows and none of that helper's `settled:` machinery, since nothing below asks for
    # the decomposition.
    def two_shard_run(commit_sha:)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20, annotated_specs_count: 5,
                                         duration_seconds: 45.0)
      [30.0, 45.0].each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 10,
                                    annotated_specs_count: 2, duration_seconds: seconds)
      end
      run
    end

    it "re-anchors shards onto the named run" do
      sharded = two_shard_run(commit_sha: "shard0000001")
      create_test_run(repository: repository, commit_sha: "plain0000002")

      expect(get_repository["latest_run"]["shards"]).to be_nil
      expect(get_repository(query: { commit_sha: sharded.commit_sha })["latest_run"]["shards"])
        .to include("count" => 2)
    end

    # AC1's disclosure half: the block that says which run was described and why.
    it "discloses a resolved ask on run_anchor" do
      first, = three_run_history

      body = get_repository(query: { commit_sha: first.commit_sha })

      expect(body["run_anchor"]).to eq(
        "source" => "requested",
        "requested_commit_sha" => first.commit_sha,
        "resolved" => true,
        "commit_sha" => first.commit_sha,
        "branch" => "main",
        # Read off the constant and never as a literal 60, so lowering the rule cannot leave this
        # example asserting a bound the platform no longer enforces.
        "observations_retained" => true,
        "retention_runs" => SpecObservation::BRANCH_RETENTION_RUNS
      )
    end

    # AC2. A default call is what it was, plus this one key — and `source`/`resolved` say so without
    # inventing an ask. `resolved` is TRUE here and that is the deliberate reading: it is false in
    # exactly one case, a client that named a sha and is not being served it, so an
    # `unless resolved` warning does not fire on every unparameterised GET.
    it "discloses the default anchor when no run was named" do
      _first, _second, third = three_run_history

      expect(get_repository["run_anchor"]).to eq(
        "source" => "default",
        "requested_commit_sha" => nil,
        "resolved" => true,
        "commit_sha" => third.commit_sha,
        "branch" => "main",
        "observations_retained" => true,
        "retention_runs" => SpecObservation::BRANCH_RETENTION_RUNS
      )
    end

    # AC3. Not a 404 and not an empty block: the newest run, and a disclosure that the ask was made
    # and missed. Both halves are asserted, because either alone is passable by a broken
    # implementation — serving the newest run silently would satisfy the first, and a block reporting
    # `resolved: false` beside a nulled `latest_run` would satisfy the second.
    #
    # THE RAW ASK IS ASSERTED PRESENT, and it is the load-bearing key here: it is the only place in
    # the body that still holds what the client typed, so without it a fallback is indistinguishable
    # from the client's own bug.
    it "falls back to the newest run and says so when the named sha has no run" do
      _first, _second, third = three_run_history

      body = get_repository(query: { commit_sha: "deadbeefdead" })

      expect(response).to have_http_status(:ok)
      expect(body["run_anchor"]).to eq(
        "source" => "requested",
        "requested_commit_sha" => "deadbeefdead",
        "resolved" => false,
        "commit_sha" => third.commit_sha,
        "branch" => "main",
        # The retention disclosure describes the run ACTUALLY SERVED, which under a fallback is the
        # newest run and not the sha the client typed — the same rule `commit_sha`/`branch` two
        # lines up already follow.
        "observations_retained" => true,
        "retention_runs" => SpecObservation::BRANCH_RETENTION_RUNS
      )
      expect(body["latest_run"]).to include("commit_sha" => third.commit_sha, "total_specs" => 30)
    end

    # AC3, the repository-with-no-runs corner the example above cannot reach. `run_anchor` is a
    # statement about the REQUEST and is present on every response; `latest_run` is the key that goes
    # null for "CI has never reported". The two facts are separable and the block must not conflate
    # them — `resolved: false` here is about the ask, and `commit_sha: null` about there being
    # nothing to fall back to.
    it "keeps run_anchor present on a repository CI has never reported to" do
      body = get_repository(query: { commit_sha: "deadbeefdead" })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to be_nil
      expect(body["run_anchor"]).to eq(
        "source" => "requested",
        "requested_commit_sha" => "deadbeefdead",
        "resolved" => false,
        "commit_sha" => nil,
        "branch" => nil,
        # `null`, not `true` and not `false`: there is no run to ask, and a boolean here would be a
        # verdict about a run that does not exist — the same separation `commit_sha: null` draws one
        # line up. `retention_runs` still ships, because the RULE exists whether or not a run does.
        "observations_retained" => nil,
        "retention_runs" => SpecObservation::BRANCH_RETENTION_RUNS
      )
    end

    # AC4. A sha is NOT unique in `test_runs` — the only unique index is
    # `(repository_id, ci_run_id) WHERE ci_run_id IS NOT NULL` — so a CI re-run of one commit is a
    # second row and "the run for this sha" has more than one answer.
    # `Repository#latest_test_run_for_commit` picks the same one every other newest-run reader on
    # that model picks, and this pins WHICH.
    #
    # Two runs at the SAME INSTANT, so the `created_at` half of the ordering cannot separate them and
    # the tie-break — the id, which is the ingest sequence — is the only thing that can. A finder
    # ordering on `created_at` alone would pass or fail here at the database's discretion, which is
    # the shape this example exists to forbid.
    it "resolves two runs on one sha to the newer, broken by ingest sequence" do
      instant = 1.hour.ago
      older = create_test_run(repository: repository, commit_sha: "twice0000001", branch: "main",
                              total_specs_count: 11, created_at: instant)
      newer = create_test_run(repository: repository, commit_sha: "twice0000001", branch: "main",
                              total_specs_count: 22, created_at: instant)

      expect(newer.id).to be > older.id
      expect(newer.created_at).to eq(older.created_at)

      body = get_repository(query: { commit_sha: "twice0000001" })

      expect(body["latest_run"]).to include("commit_sha" => "twice0000001", "total_specs" => 22)
      expect(body["run_anchor"]).to include("resolved" => true)
    end

    # AC6, and the property the single-memo design exists for. Every block that names the run it is
    # anchored on must name THE SAME run — asserted by reading the anchor out of four independent
    # places in one body and requiring them equal, rather than by restating the fixture's sha four
    # times, so a partial re-anchor cannot pass by the expectation drifting with it.
    #
    # `previous_test_run` follows the anchor without a change of its own: it is already "the newest
    # run strictly older than THIS one, on THIS one's branch". The baseline is asserted to be the
    # named run's PREDECESSOR and not the newest run's, which is the half that would silently stay
    # put if the growth blocks read `Repository#latest_test_run` directly.
    it "keeps every anchored block naming the same run under an explicit ask" do
      first, second, _third = three_run_history

      body = get_repository(query: { commit_sha: second.commit_sha })
      anchors = [
        body["run_anchor"]["commit_sha"],
        body["latest_run"]["commit_sha"],
        body["directory_run_growth_window"]["anchor_commit_sha"],
        body["directory_runtime_growth_window"]["anchor_commit_sha"]
      ]

      expect(anchors).to all(eq(second.commit_sha))
      # The baseline moved with the anchor: `first` is the run before `second`, not the run before
      # the newest one (which would be `second` itself).
      expect(body["directory_run_growth_window"]["baseline_commit_sha"]).to eq(first.commit_sha)
      expect(body["directory_runtime_growth_window"]["baseline_commit_sha"]).to eq(first.commit_sha)
    end

    # `history` is NOT re-anchored, and the `history[0] == latest_run` identity is NOT expected to
    # hold under an explicit ask. Stated as an expectation rather than left as an unremarked property
    # of the fixture, so a later slice that "fixes" the mismatch by narrowing `history` to the named
    # run has to argue with this example — and so a client reading `run_anchor` learns why the two
    # disagree rather than filing it as a bug.
    it "leaves history where it was, and lets latest_run differ from history[0]" do
      first, _second, third = three_run_history

      named = get_repository(query: { commit_sha: first.commit_sha })

      expect(named["history"].map { |row| row["commit_sha"] })
        .to eq(get_repository["history"].map { |row| row["commit_sha"] })
      expect(named["history"].first["commit_sha"]).to eq(third.commit_sha)
      expect(named["latest_run"]["commit_sha"]).to eq(first.commit_sha)
      expect(named["run_anchor"]).to include("source" => "requested", "resolved" => true)
    end

    # AC5, first half. `?commit_sha=` is "no ask", not `WHERE commit_sha = ''` — the column is NOT
    # NULL and `TestRun` validates its presence, so a blank matches nothing and an implementation
    # that queried on it would fall back while `run_anchor` claimed a request had been made.
    it "reads a blank commit_sha as no ask rather than as an empty query" do
      _first, _second, third = three_run_history

      body = get_repository(query: { commit_sha: "" })

      expect(body["latest_run"]).to include("commit_sha" => third.commit_sha)
      expect(body["run_anchor"]).to eq(
        "source" => "default",
        "requested_commit_sha" => nil,
        "resolved" => true,
        "commit_sha" => third.commit_sha,
        "branch" => "main",
        "observations_retained" => true,
        "retention_runs" => SpecObservation::BRANCH_RETENTION_RUNS
      )
    end

    # AC5, second half. The three shapes a query string can legally parse into that are not a sha are
    # listed ONCE, in `spec/support/shared_examples/malformed_commit_sha_param.rb`, against the guard
    # they all land on (`RequestedCommitShaParam#requested_commit_sha`). What is local here is how
    # THIS surface says it dropped the ask.
    #
    # The disclosure is asserted alongside the anchor, and that is the half a bare 200 would miss: a
    # guard that dropped the ask but left `run_anchor` claiming one would be a response asserting it
    # had honoured a request it ignored — the failure the block was added to prevent, arriving
    # through the door the block was added by.
    describe "a commit-sha parameter that is not a sha" do
      def expect_commit_sha_param_treated_as_no_ask(query)
        _first, _second, third = three_run_history

        body = get_repository(query: query)

        expect(response).to have_http_status(:ok)
        expect(body["latest_run"]).to include("commit_sha" => third.commit_sha)
        expect(body["run_anchor"]).to include("source" => "default", "requested_commit_sha" => nil,
                                              "resolved" => true, "commit_sha" => third.commit_sha)
      end

      it_behaves_like "a surface that treats a malformed commit-sha parameter as no ask"

      # The positive-path example the shared examples' own doc comment requires to sit beside them: a
      # guard that swallowed EVERY value would answer 200 on all three malformed shapes too, and
      # nothing above separates "the guard rejects non-Strings" from "the parameter does nothing".
      it "honours a commit_sha that IS a string" do
        first, = three_run_history

        expect(get_repository(query: { commit_sha: first.commit_sha })["latest_run"])
          .to include("commit_sha" => first.commit_sha)
      end
    end

    # `?commit_sha=` and `?branch=` are independent asks and compose without either overriding the
    # other — the run-grain half anchors on the named run while `history` narrows to the named
    # branch. Worth pinning because the two parameters are the only ones here that select ROWS rather
    # than open panels, and an implementation that let the branch predicate reach the anchor finder
    # would silently fail to resolve a sha whose run is on another branch.
    it "composes with ?branch= without either ask overriding the other" do
      feature = create_test_run(repository: repository, commit_sha: "feat00000001",
                                branch: "feature/x", total_specs_count: 5)
      main_run = create_test_run(repository: repository, commit_sha: "main00000002", branch: "main",
                                 total_specs_count: 50)

      body = get_repository(query: { commit_sha: feature.commit_sha, branch: "main" })

      expect(body["latest_run"]).to include("commit_sha" => feature.commit_sha, "total_specs" => 5)
      expect(body["run_anchor"]).to include("source" => "requested", "resolved" => true,
                                            "branch" => "feature/x")
      expect(body["history"].map { |row| row["commit_sha"] }).to eq([main_run.commit_sha])
      expect(body["history_window"]).to include("branch_scope" => "single_branch", "branch" => "main")
    end

    # The anchor finder costs ONE read, and only when a sha was actually named. Bounded because it
    # sits on the critical path of every run-grain block — it is resolved before `latest_run`, the
    # rollups, the drill-ins and both growth windows — so a second lookup here is a second lookup for
    # the whole response, and a lookup on a DEFAULT call is one every unparameterised GET pays for
    # nothing. `requested_test_run` and `latest_test_run` both memoize across the nil; this is what
    # says so from the outside.
    it "reads the named run once, and reads nothing extra when no sha was named" do
      first, = three_run_history

      # Matched on the WHERE clause rather than on a `LIMIT 1` literal: the finder binds its limit,
      # so the emitted SQL carries `LIMIT $3` and a literal match would count zero and pass
      # vacuously. `commit_sha` appears in no other predicate this endpoint issues.
      by_sha = ->(sql) { sql.include?(%("test_runs"."commit_sha" = )) }

      expect(executed_sql { get_repository(query: { commit_sha: first.commit_sha }) }.count(&by_sha))
        .to eq(1)
      expect(executed_sql { get_repository }.count(&by_sha)).to eq(0)
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
    # added without a line in the hash below fails here, and a pinned key dropped fails
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
    # The `ANALYZE` in the examples below reaches past the per-example rollback. This puts back
    # what it perturbs — see the mechanism, and the measured numbers, in the support file.
    restores_relation_statistics_for "test_runs"

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
    # The `ANALYZE` in the examples below reaches past the per-example rollback. This puts back
    # what it perturbs — see the mechanism, and the measured numbers, in the support file.
    restores_relation_statistics_for "test_runs"

    def create_main_runs(count, prefix:)
      Array.new(count) do |index|
        create_test_run(repository: repository, commit_sha: "#{prefix}%08d" % index, branch: "main",
                        total_specs_count: 100 + index)
      end
    end

    # The invariance, from the smallest baseline that holds the WINDOW'S STATE fixed to the full
    # thirty-row bound and past it. A baseline taken inside the window would sit inside the leak it
    # is meant to measure; forty rows is what proves the bound is enforced rather than the fixture
    # merely being small.
    #
    # TWO ROWS WAS ONCE THE BASELINE AND IS NOW THREE, and the reason is a property of this endpoint
    # rather than a concession. Blocks served here read CONDITIONALLY ON STATE rather than on window
    # size, so the baseline has to be taken in the same STATE as the full window or it sits inside
    # the leak it is meant to measure.
    #
    # `SpecDirectoryWindowGrowth` asks `spec_observations` nothing at all where the window holds a
    # single run, because there is no earlier run to compare against — which is what ruled out ONE
    # row. THREE is what rules out two, and the mechanism is the query cache rather than a gate:
    # `directory_run_growth` compares the latest run against the PREVIOUS run on its branch, and at
    # a window of two those ARE the window's two ends, so both growth blocks emit a BYTE-IDENTICAL
    # statement and the second is served from the cache — one read where every larger window pays
    # two. At three rows the window spans runs 1→3 and the run-over-run pair spans 2→3, the two
    # statements differ, and the state is the one thirty and forty are in.
    #
    # Three rows is still TWENTY-SEVEN short of the bound: a per-row `pick` for `shard_count` reads
    # as twenty-seven extra statements here, which is the leak this bounds.
    it "costs the same at 3 branch rows, at 30 and at 40" do
      create_main_runs(3, prefix: "cost")
      get_repository(query: { branch: "main" })
      baseline = executed_sql { get_repository(query: { branch: "main" }) }.length

      create_main_runs(27, prefix: "grow")
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

      # `run_anchor`'s retention boundary is excluded on the SAME rule the `shard_totals` pick is
      # excluded by in the comment above: it is one indexed read ABOUT THE ANCHORED RUN, not part of
      # this window, so counting it here would make the budget read as three and hide which of the
      # two axes moved if one ever did. `TestRun#observations_retained?` emits it.
      #
      # Excluded STRUCTURALLY rather than by luck: it is the only branch-scoped read that selects
      # two columns with an OFFSET, where every window read selects `test_runs.*`. And it is bounded
      # at exactly ONE statement below rather than merely dropped — an exclusion that swallowed a
      # per-row boundary read would be the very leak this example exists to catch, so the carve-out
      # is asserted rather than assumed.
      boundary_reads = statements.grep(/FROM "test_runs"/).grep(/OFFSET/)
      history_queries = statements.grep(/FROM "test_runs"/).grep(/"branch" = /)
                                  .grep_v(/\(test_runs\.created_at, test_runs\.id\) < /)
                                  .grep_v(/OFFSET/)
      grouped_counts = statements.grep(/FROM "test_run_shards"/).grep(/GROUP BY/)

      # One boundary read for the whole response, however many rows the window holds — the anchored
      # run is asked once and no row is asked at all.
      expect(boundary_reads.length).to eq(1)
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
      # stays green while the window costs thirty-two. Exactly THREE reads of the table — the
      # window's one grouped aggregate, plus TWO single un-grouped `shard_totals` picks, one for the
      # `latest_run` row and one for the PREVIOUS run on its branch, which `directory_run_growth`'s
      # `TestRun#assembled_like?` gate has to ask about a row `preload_shard_counts` never saw — is
      # the bound that catches it.
      expect(statements.grep(/FROM "test_run_shards"/).length).to eq(3)
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
                .grep_v(/\(test_runs\.created_at, test_runs\.id\) < /)
                .grep_v(/OFFSET/)

      expect(history.length).to eq(1)
      # Both clauses, in that order, in one statement. `latest_run`'s own `LIMIT 1` read carries no
      # branch predicate and is filtered out above, and so is `directory_run_growth`'s previous-run
      # lookup, which DOES carry one — it is excluded on the row-value predicate
      # `Repository#previous_test_run_on_branch` emits and `recent_test_runs` does not, so this
      # cannot pass by matching either. `run_anchor`'s retention boundary carries one too and is
      # excluded on its OFFSET — it selects two columns where every window read selects
      # `test_runs.*`, and the example above bounds it at exactly one statement so dropping it here
      # cannot hide a per-row read.
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

  # The by-file rollup's own axis, and it is stated as CONSTANT rather than as minimal — the
  # endpoint pays for it on every run, recorded or not, because `SpecFileDurations.for` issues its
  # aggregate unconditionally and `#recorded?` is an answer DERIVED from that read rather than a
  # gate in front of it. There is no cheaper way to ask: `test_runs` carries no observation
  # counter, so the emptiness of the set is not knowable without a read.
  #
  # COUNTED AGAINST THE TABLE rather than as a delta off a baseline, and that is the whole point of
  # the shape. A `baseline + 1` equality cannot distinguish "one grouped aggregate" from "one query
  # that happens to be the only one added this release", and it silently rebaselines the day
  # anything else on the endpoint changes its own cost. `queries_against` names the table, so what
  # is pinned is the thing the budget is actually about: the endpoint reads `spec_observations`
  # exactly once FOR THIS GRAIN, whatever the run looks like.
  #
  # NARROWED TO THE GRAIN, not rebaselined to two, when the by-area rollup was added beside this
  # one. Rewriting these three `eq(1)`s as `eq(2)` would have made this block pass on a by-file
  # serializer that read the table twice and a by-area one that read it not at all — the arrival of
  # a sibling silently dissolving a guard that had held. `file_grain_reads` classifies by which
  # aggregate issued the statement (see the partition at the top of this file), so what this block
  # asserts today is what it asserted before the sibling existed. The total across both grains is
  # pinned once, in the by-area block below.
  describe "what the by-file rollup costs the endpoint" do
    # The axis this example is NAMED for: the size of the suite. 20 examples over 2 files and 2000
    # over 200 cost the same one read, which is what makes the block affordable at the roadmap's
    # 20,000-example design point. A serializer that fetched rows and rolled them up in Ruby — or
    # one that took a second pass for `file_count` — reads as two here and as more as the suite
    # grows.
    it "reads spec_observations exactly once, on a run with rows and on a run without" do
      bare = create_test_run(repository: repository, commit_sha: "cost00000001", duration_seconds: 42.5)
      get_repository
      expect(bare.spec_observations).to be_empty
      # Paid on the run that has nothing to disclose too — the honest cost, and the one a gate in
      # front of the read would remove at the price of a second query on every run that does.
      expect(file_grain_reads { get_repository }.length).to eq(1)

      small = create_test_run(repository: repository, commit_sha: "cost00000002", duration_seconds: 42.5)
      2.times do |index|
        10.times { |line| observe(small, path: "spec/small_#{index}_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(small)
      expect(file_grain_reads { get_repository }.length).to eq(1)
      expect(get_repository.dig("latest_run", "spec_files", "file_count")).to eq(2)

      big = create_test_run(repository: repository, commit_sha: "cost00000003", duration_seconds: 42.5)
      200.times do |index|
        10.times { |line| observe(big, path: "spec/big_#{index}_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(big)
      expect(file_grain_reads { get_repository }.length).to eq(1)
      # And the rollup really was served at 200 files — a serializer that quietly stopped emitting
      # the block above some width would satisfy every count above.
      expect(get_repository.dig("latest_run", "spec_files", "file_count")).to eq(200)
      expect(get_repository.dig("latest_run", "spec_files", "rows").length)
        .to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
    end

    # The history axis, restated for this key alone. `spec_files` is served on `latest_run` and on
    # nothing else, so a window of ten runs must not read the table ten times — the N+1 that would
    # be invisible in the example above, where every fixture has exactly one run to serve.
    it "reads it once whatever the history holds" do
      run = create_test_run(repository: repository, commit_sha: "costwindow01", duration_seconds: 42.5)
      observe(run, path: "spec/a_spec.rb", duration: 0.5, line_number: 1)
      15.times { |index| create_test_run(repository: repository, commit_sha: "costwin%05d" % index) }

      expect(repository.test_runs.count).to eq(16)
      expect(file_grain_reads { get_repository }.length).to eq(1)
    end
  end

  # AC7. The by-area rollup's own axis, stated on the block above's terms because it is the same
  # cost one rung up: EXACTLY ONE additional query, on every run recorded or not, and CONSTANT in
  # the size of the suite. `SpecDirectoryDurations.for` issues `directory_durations_in`
  # unconditionally, so `#recorded?` is an answer DERIVED from the read rather than a gate in front
  # of it — and it is worth saying plainly that this is NOT "no query when unrecorded", which is the
  # restatement the by-file criterion had to be corrected on. There is no cheaper way to ask:
  # `test_runs` carries no observation counter.
  #
  # It needs no index of its own. The read groups on an EXPRESSION and narrows on a COLUMN, and
  # only the second decides the access path, so `index_spec_observations_on_test_run_id` serves it
  # — EXPLAIN-certified at the 20-run seed in `spec/models/spec_observation_spec.rb`, which is
  # where a plan belongs rather than in a request spec.
  describe "what the by-area rollup costs the endpoint" do
    # The suite-size axis, and the one that decides whether this key is affordable at the roadmap's
    # 20,000-example design point: 20 examples over 2 areas and 2000 over 200 cost the same single
    # read. A serializer that fetched rows and grouped them in Ruby — or that took a second pass
    # for `directory_count` — reads as two here and as more as the suite grows.
    it "reads spec_observations exactly once for the area grain, on a run with rows and without" do
      bare = create_test_run(repository: repository, commit_sha: "acost0000001", duration_seconds: 42.5)
      get_repository
      expect(bare.spec_observations).to be_empty
      # PAID ON THE RUN THAT HAS NOTHING TO DISCLOSE, which is the honest cost and not the flattering
      # one. A gate in front of the read would buy this run its query back at the price of a second
      # one on every run that does record.
      expect(area_grain_reads { get_repository }.length).to eq(1)
      # And the UNRECORDED path reads the table SEVEN times IN TOTAL — no eighth. Asserted here and
      # not only on the recorded fixture below, because a read matching no grain's pattern is
      # invisible to every per-grain guard by construction, and the unrecorded branch is exactly
      # where an `exists?` gate or a preload would be tempting to add.
      #
      # Pinned as a bare `6` here, and that is deliberate rather than an oversight: this example
      # classifies nothing — it holds `area_grain_reads` alone, so there are no grain lists in
      # scope to sum, and putting them in scope would re-narrow the one assertion that has to stay
      # UNclassified to catch the read matching no grain's pattern. The sum-of-grains form belongs
      # at the site that already does the classifying, where it is written ALONGSIDE the literal
      # and not in place of it — see "reads spec_observations exactly seven times in total" below.
      expect(observation_reads { get_repository }.length).to eq(7)
      expect(get_repository.dig("latest_run", "spec_directories")).to be_nil

      small = create_test_run(repository: repository, commit_sha: "acost0000002", duration_seconds: 42.5)
      2.times do |index|
        10.times { |line| observe(small, path: "spec/small_#{index}/a_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(small)
      expect(area_grain_reads { get_repository }.length).to eq(1)
      expect(get_repository.dig("latest_run", "spec_directories", "directory_count")).to eq(2)

      big = create_test_run(repository: repository, commit_sha: "acost0000003", duration_seconds: 42.5)
      200.times do |index|
        10.times { |line| observe(big, path: "spec/big_#{index}/a_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(big)
      expect(area_grain_reads { get_repository }.length).to eq(1)
      # And the rollup really was served at 200 areas — a serializer that quietly stopped emitting
      # the block above some width would satisfy every count above.
      expect(get_repository.dig("latest_run", "spec_directories", "directory_count")).to eq(200)
      expect(get_repository.dig("latest_run", "spec_directories", "rows").length)
        .to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    end

    # The history axis, restated for this key alone. `spec_directories` is served on `latest_run`
    # and on nothing else, so a window of sixteen runs must not read the table sixteen times — the
    # N+1 that is invisible in the example above, where every fixture has one run to serve.
    it "reads it once whatever the history holds" do
      run = create_test_run(repository: repository, commit_sha: "acostwindow1", duration_seconds: 42.5)
      observe(run, path: "spec/models/a_spec.rb", duration: 0.5, line_number: 1)
      15.times { |index| create_test_run(repository: repository, commit_sha: "acostwin%04d" % index) }

      expect(repository.test_runs.count).to eq(16)
      expect(area_grain_reads { get_repository }.length).to eq(1)
      # The N+1 this example exists to catch need not land on any grain's pattern — a per-run
      # preload of `spec_observations` matches none of them, so the per-grain count alone would
      # stay at 1 through sixteen extra reads. The total is what names it.
      expect(observation_reads { get_repository }.length).to eq(7)
    end

    # "GAINS EXACTLY ONE" — the half neither per-grain block can state, and the reason it is stated
    # once rather than in both. Two guards each saying "my grain reads once" leave a further read
    # added by anything else on this endpoint unnamed; the table-level total is what closes that,
    # and it is the criterion this ticket was written against.
    #
    # SEVEN, as `1 + 1 + 2 + 2 + 0 + 1`: one aggregate per rollup grain, two for the per-example
    # ranking — whose presenter issues a capped scan and a coverage aggregate — two for the
    # by-description ranking, whose presenter issues a grouped aggregate and the presence count it
    # cannot window over, NONE for the cross-run flakiness grain, which is not constructed on an
    # unfiltered window, and ONE for the run's intent readings. Restated as the sum of the classified
    # lists rather than as a literal, so a grain that stopped reading and another that started
    # reading twice cannot cancel out into a passing total.
    #
    # ⭐ THE LAST TERM IS THE ONLY UNGATED ADDITION THIS ENDPOINT HAS TAKEN. Every drill-in here
    # costs nothing until a client asks for it; `latest_run.intent_readings` is served on every
    # response, and SPGD-711 took that cost deliberately — it is four integers off one aggregate over
    # one run, and the correction it carries (that most unannotated tests are READ, not invisible) is
    # worthless to a client that has to opt into it. The figure moved from six to seven here and
    # nowhere else on this file's fixtures, which is what says the addition is one read rather than
    # one per grain.
    #
    # The flakiness list is destructured and asserted EMPTY rather than dropped on the floor. Two
    # separate things break if it is not: a grain silently added to this request would be adopted by
    # the total without anything naming it, and — the sharper one — the sum below would keep passing
    # if the flakiness composition read were mis-classified into the per-example grain, since the
    # two patterns overlapped before `spec/support/observation_grain_reads.rb` tightened the second.
    # The by-description patterns were chosen against that same trap: two of the flakiness grain's
    # four also `GROUP BY name`, so this fixture's empty flakiness list is what would catch a
    # description pattern loose enough to adopt them.
    it "reads spec_observations exactly seven times in total — one per rollup grain, two per ranking, and no other" do
      run = create_test_run(repository: repository, commit_sha: "acosttotal01", duration_seconds: 42.5)
      observe(run, path: "spec/models/a_spec.rb", duration: 0.5, line_number: 1)
      observe(run, path: "spec/requests/b_spec.rb", duration: 0.5, line_number: 1)

      area, file, example, description, flakiness, _growth, _dfiles, _fex, _dex, _dfg, _rtg, _dfrtg,
        _utr, _unann, _debt, readings = observation_reads_by_grain { get_repository }

      expect(area.length).to eq(1)
      expect(file.length).to eq(1)
      expect(example.length).to eq(2)
      expect(description.length).to eq(2)
      expect(flakiness).to be_empty
      expect(readings.length).to eq(1)
      # And the classified reads are ALL of them — the assertion the per-grain blocks cannot make,
      # because a read matching no grain's pattern is invisible to every one of them.
      expect(observation_reads { get_repository }.length)
        .to eq(classified_observation_reads { get_repository })
      expect(observation_reads { get_repository }.length).to eq(7)
    end
  end

  # AC5. The per-example ranking's own axis, stated on the two blocks above's terms — with one
  # difference that has to be said out loud rather than inherited: this grain costs TWO, not one.
  # `SlowestExamples.for` issues both reads unconditionally, so `#recorded?` is an answer DERIVED
  # from them rather than a gate in front of them, and the pair is the honest figure: an indexed
  # backward scan capped at `SLOWEST_LIMIT`, and one aggregate over the same index's leading column.
  # Both sit behind `index_spec_observations_on_test_run_id_and_duration_seconds` and are
  # EXPLAIN-certified in `spec/models/spec_observation_spec.rb`, which is where a plan belongs.
  #
  # The `+ 2` IS WRITTEN AS `+ 2` AND NEVER REBASELINED, on the precedent the sharded cost block
  # sets above — but it is pinned as TWO CLASSIFIED READS rather than as a delta off a `count_queries`
  # baseline, because there is no "off" state on this endpoint to take that baseline against: the
  # two reads fire on every run, recorded or not, so a before-and-after delta cannot be measured at
  # runtime the way the shard block's gated one can. Two positively-matched statements is the
  # stronger form of the same claim — it says WHICH two, so a read that stopped being issued and a
  # different one that started cannot cancel out — and the table-level total in the block above is
  # what pins the `2` as an ADDITION to the rollups' `2` rather than a replacement of it.
  describe "what the per-example ranking costs the endpoint" do
    # The axis this example is NAMED for: the size of the suite. 20 examples over 2 files and 2000
    # over 200 cost the same two reads, which is what makes the block affordable at the roadmap's
    # 20,000-example design point. A serializer that fetched rows and sorted them in Ruby — or that
    # took a third pass for the coverage figures — reads as three here and as more as the suite
    # grows.
    it "reads spec_observations exactly twice for this grain, on a run with rows and without" do
      bare = create_test_run(repository: repository, commit_sha: "ecost0000001", duration_seconds: 42.5)
      get_repository
      expect(bare.spec_observations).to be_empty
      # PAID ON THE RUN THAT HAS NOTHING TO DISCLOSE. `#recorded?` is computed FROM the coverage
      # aggregate, so declining to serve the block costs exactly what serving it does.
      expect(example_grain_reads { get_repository }.length).to eq(2)
      expect(get_repository.dig("latest_run", "slowest_examples")).to be_nil

      small = create_test_run(repository: repository, commit_sha: "ecost0000002", duration_seconds: 42.5)
      2.times do |index|
        10.times { |line| observe(small, path: "spec/small_#{index}_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(small)
      expect(example_grain_reads { get_repository }.length).to eq(2)
      expect(get_repository.dig("latest_run", "slowest_examples", "recorded_count")).to eq(20)

      big = create_test_run(repository: repository, commit_sha: "ecost0000003", duration_seconds: 42.5)
      200.times do |index|
        10.times { |line| observe(big, path: "spec/big_#{index}_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(big)
      expect(example_grain_reads { get_repository }.length).to eq(2)
      # And the ranking really was served at 2000 examples — a serializer that quietly stopped
      # emitting the block above some width would satisfy every count above.
      expect(get_repository.dig("latest_run", "slowest_examples", "recorded_count")).to eq(2000)
      expect(get_repository.dig("latest_run", "slowest_examples", "rows").length)
        .to eq(SpecObservation::SLOWEST_LIMIT)
    end

    # THE WHOLE ENDPOINT'S count, not this table's — the figure a client actually pays, and the one
    # `queries_against`'s per-table narrowing cannot see. Stated as UNCHANGED across two orders of
    # magnitude of suite size rather than as a number, because the number belongs to the endpoint's
    # other blocks and would rebaseline every time one of them changed.
    it "leaves the endpoint's total query count unmoved as the suite grows" do
      run = create_test_run(repository: repository, commit_sha: "ecosttotal01", duration_seconds: 42.5)
      10.times { |line| observe(run, path: "spec/a_spec.rb", duration: 0.5, line_number: line) }
      get_repository
      baseline = count_queries { get_repository }

      big = create_test_run(repository: repository, commit_sha: "ecosttotal02", duration_seconds: 42.5)
      200.times do |index|
        10.times { |line| observe(big, path: "spec/big_#{index}_spec.rb", duration: 0.5, line_number: line) }
      end
      expect(repository.latest_test_run).to eq(big)
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository.dig("latest_run", "slowest_examples", "rows").length)
        .to eq(SpecObservation::SLOWEST_LIMIT)
    end

    # The history axis, restated for this key alone. `slowest_examples` is served on `latest_run`
    # and on nothing else, so a window of sixteen runs must not read the table thirty-two times —
    # the N+1 that is invisible in the examples above, where every fixture has one run to serve.
    it "reads it twice whatever the history holds" do
      run = create_test_run(repository: repository, commit_sha: "ecostwindow1", duration_seconds: 42.5)
      observe(run, path: "spec/models/a_spec.rb", duration: 0.5, line_number: 1)
      15.times { |index| create_test_run(repository: repository, commit_sha: "ecostwin%04d" % index) }

      expect(repository.test_runs.count).to eq(16)
      expect(example_grain_reads { get_repository }.length).to eq(2)
      expect(observation_reads { get_repository }.length).to eq(7)
    end
  end

  # AC8. The by-description ranking's own axis, on the per-example block's terms, and it costs TWO
  # for a DIFFERENT reason than that one does. `SlowestExamples` pays a second read for a coverage
  # figure it could not window over its capped scan; `RepeatedDescriptions` pays one because its
  # grouped read EXCLUDES null names in the WHERE clause, so no window over that read could ever
  # have counted the rows it dropped, and `.description_presence_in` is the only thing that can
  # answer for them. Both fire unconditionally, so `#recorded?` is an answer DERIVED from the reads
  # rather than a gate in front of them.
  #
  # The plan belongs in `spec/models/spec_observation_spec.rb`, where the grouped read is already
  # EXPLAIN-certified at the 20-run seed against `index_spec_observations_on_test_run_id`, and it is
  # NOT re-certified here: this block issues the panel's reads unchanged, so the certification
  # transfers. What a request spec can say that a model spec cannot is HOW MANY of them the endpoint
  # issues, and that is all this block says.
  describe "what the by-description ranking costs the endpoint" do
    # The axis this example is NAMED for: the size of the suite. 20 examples over 2 descriptions and
    # 2000 over 200 cost the same two reads, which is what makes the block affordable at the
    # roadmap's 20,000-example design point. A serializer that fetched rows and grouped them in Ruby
    # — or that took a third pass for the presence counts — reads as three here and as more as the
    # suite grows.
    it "reads spec_observations exactly twice for this grain, on a run with rows and without" do
      bare = create_test_run(repository: repository, commit_sha: "dcost0000001", duration_seconds: 42.5)
      get_repository
      expect(bare.spec_observations).to be_empty
      # PAID ON THE RUN THAT HAS NOTHING TO DISCLOSE. `#recorded?` is computed FROM the presence
      # read, so declining to serve the block costs exactly what serving it does.
      expect(description_grain_reads { get_repository }.length).to eq(2)
      expect(get_repository.dig("latest_run", "repeated_descriptions")).to be_nil

      small = create_test_run(repository: repository, commit_sha: "dcost0000002", duration_seconds: 42.5)
      2.times do |index|
        10.times do |line|
          observe(small, path: "spec/small_spec.rb", duration: 0.5, line_number: (index * 10) + line,
                  name: "small #{index}")
        end
      end
      expect(repository.latest_test_run).to eq(small)
      expect(description_grain_reads { get_repository }.length).to eq(2)
      expect(get_repository.dig("latest_run", "repeated_descriptions", "group_count")).to eq(2)

      big = create_test_run(repository: repository, commit_sha: "dcost0000003", duration_seconds: 42.5)
      200.times do |index|
        10.times do |line|
          observe(big, path: "spec/big_spec.rb", duration: 0.5, line_number: (index * 10) + line,
                  name: "big #{index}")
        end
      end
      expect(repository.latest_test_run).to eq(big)
      expect(description_grain_reads { get_repository }.length).to eq(2)
      # And the ranking really was served at 200 repeated descriptions — a serializer that quietly
      # stopped emitting the block above some width would satisfy every count above.
      expect(get_repository.dig("latest_run", "repeated_descriptions", "group_count")).to eq(200)
      expect(get_repository.dig("latest_run", "repeated_descriptions", "rows").length)
        .to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
    end

    # THE WHOLE ENDPOINT'S count, not this table's — the figure a client actually pays, and the one
    # `queries_against`'s per-table narrowing cannot see. Stated as UNCHANGED across two orders of
    # magnitude of suite size rather than as a number, because the number belongs to the endpoint's
    # other blocks and would rebaseline every time one of them changed.
    it "leaves the endpoint's total query count unmoved as the suite grows" do
      run = create_test_run(repository: repository, commit_sha: "dcosttotal01", duration_seconds: 42.5)
      10.times { |line| observe(run, path: "spec/a_spec.rb", duration: 0.5, line_number: line, name: "a") }
      get_repository
      baseline = count_queries { get_repository }

      big = create_test_run(repository: repository, commit_sha: "dcosttotal02", duration_seconds: 42.5)
      200.times do |index|
        10.times do |line|
          observe(big, path: "spec/big_spec.rb", duration: 0.5, line_number: (index * 10) + line,
                  name: "big #{index}")
        end
      end
      expect(repository.latest_test_run).to eq(big)
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository.dig("latest_run", "repeated_descriptions", "rows").length)
        .to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
    end

    # The history axis, restated for this key alone. `repeated_descriptions` is served on
    # `latest_run` and on nothing else, so a window of sixteen runs must not read the table
    # thirty-two times — the N+1 that is invisible in the examples above, where every fixture has
    # one run to serve.
    it "reads it twice whatever the history holds" do
      run = create_test_run(repository: repository, commit_sha: "dcostwindow1", duration_seconds: 42.5)
      2.times { |line| observe(run, path: "spec/models/a_spec.rb", duration: 0.5, line_number: line, name: "a") }
      15.times { |index| create_test_run(repository: repository, commit_sha: "dcostwin%04d" % index) }

      expect(repository.test_runs.count).to eq(16)
      expect(description_grain_reads { get_repository }.length).to eq(2)
      expect(observation_reads { get_repository }.length).to eq(7)
    end
  end
end
