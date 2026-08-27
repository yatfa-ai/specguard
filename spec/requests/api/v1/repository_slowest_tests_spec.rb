# frozen_string_literal: true

require "rails_helper"

# The `slowest_tests` block on `GET /api/v1/repository` — the agent-readable half of the "Slowest
# tests across the window" panel `repositories#show` renders, and the roadmap's first axis of suite
# intelligence ("per-test duration") at the grain the Project Goals pin as semantic.
#
# Its own file, beside the sibling `repository_unstable_tests_spec.rb`, on the split that file makes
# against `repository_latest_run_spec.rb` for the same reason: every example here needs a multi-RUN
# fixture, while every block in that file is a fact about ONE run and builds a one-run repository to
# say so. The grain is the difference, and it is what makes the fixtures unshareable rather than
# merely inconvenient to share.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder` AND MATCHED BY
# `Ingest::IdentityResolver` — never inserted with an identity already attached, the rule
# `spec/requests/repository_window_slowest_tests_spec.rb` states for the panel and which binds
# harder here. Every state this block turns on is one the real pipeline produces: an unresolved row
# is a run the resolver has not reached, a moved test is the same description under a new path, and
# a reworded test is an ANNOTATED example whose identity is anchored on its declared intent while
# its description changed under it. A fixture that wrote `spec_identity_id` itself would make the
# two states that must never serialize alike — `unresolved` and an honest empty ranking — both
# unreachable, which is the one thing this file exists to pin.
RSpec.describe "GET /api/v1/repository — slowest_tests", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def get_repository(repo: repository, key: nil, query: {})
    token = (key || repo.api_keys.create!).raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  # The two keys under test, always read together: the window block explains the rows block, and
  # reading either alone is how a `null` gets asserted without its reason.
  def blocks(**)
    body = get_repository(**)
    [body["slowest_tests_window"], body["slowest_tests"]]
  end

  # One ingested CI run, through the producer and then through the resolver — the two halves the
  # endpoint runs as a `202` and a job behind it. `resolve: false` is the state the endpoint has
  # answered from and the job has not reached, which is a state this block has to serve.
  #
  # Every run is stamped back in time so the window orders them the way CI produced them rather than
  # by whatever order the fixture inserted them in — which is what makes the ⭐ anchor-orientation
  # example below able to fail.
  def ingest(repo, specs, commit_sha:, branch: "main", at: nil, resolve: true)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: specs.count { |spec| spec[:status] == "annotated" },
        duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    Ingest::IdentityResolver.resolve(run) if resolve
    run
  end

  def example_spec(name:, duration:, file_path:, line_number: 1, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  STEADY = "Ledger rebuild walks every entry"
  MOVED = "Checkout rejects an expired card"
  UNTIMED = "Webhook replays a failed delivery"
  # The reworded test's LATER description — an annotated example, so its identity is its declared
  # intent and survives the change that `unstable_tests`, grouped on `name`, would read as two
  # tests.
  RENAMED = "Invoice#finalize freezes every line"
  RENAMED_WAS = "Invoice#finalize locks the line items"

  # The suite one run of the window reported, at `index`. Four tests, each chosen for one property
  # of this block:
  #
  # * a steady test, so there is a head to the list nothing clever happened to;
  # * ⭐ a MOVED test — same description, a different spec file on either side of the window;
  # * ⭐ a REWORDED test — an annotated example whose identity is its intent, so the identity is
  #   unchanged while its description is not;
  # * an UNTIMED test, so there is a row whose `total_seconds` must serve `null` and never `0.0`.
  def window_specs(index)
    [
      example_spec(name: STEADY, duration: 3.0, file_path: "spec/models/ledger_spec.rb", line_number: 1),
      example_spec(name: MOVED, duration: 1.0, line_number: 2,
                   file_path: index < 2 ? "spec/models/checkout_spec.rb" : "spec/billing/checkout_spec.rb"),
      annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3, duration: 0.5,
                     name: index < 2 ? RENAMED_WAS : RENAMED),
      example_spec(name: UNTIMED, duration: nil, file_path: "spec/models/webhook_spec.rb", line_number: 4)
    ]
  end

  # ⚠️ The shas differ IN THEIR FIRST SEVEN CHARACTERS AND CARRY THEIR ORDINAL, and that is
  # load-bearing rather than cosmetic: the ⭐ anchor example asserts WHICH run decided membership,
  # and a fixture whose runs were indistinguishable would pass just as green with the partition
  # inverted to the oldest.
  def window_repository(runs: 4, branch: "main", **options)
    repository.tap do |repo|
      runs.times do |index|
        ingest(repo, window_specs(index), commit_sha: "run#{index}sha#{format("%07d", index)}",
                                          branch: branch, at: (30 - index).days.ago, **options)
      end
    end
  end

  def row_for(block, identity_id) = block["rows"].find { |row| row["spec_identity_id"] == identity_id }

  def identity_named(text) = repository.spec_identities.find_by(text_digest: SpecIdentity.digest_for(text))

  def row_described(block, description)
    block["rows"].find { |row| row["descriptions"].include?(description) }
  end

  # ⭐⭐⭐ CRITERION 1 — THE REGRESSION GUARD FOR THE ORDERING HAZARD, and the reason this file leads
  # with it rather than with the happy path.
  #
  # `SlowestTests.for` documents its window as OLDEST FIRST and takes `runs.last` as the ANCHOR that
  # decides which tests are on the list at all. `history_runs` is `Repository#recent_test_runs`,
  # ordered `(created_at, id) DESC` — NEWEST first — so the controller hands it in `.reverse`d.
  # Dropping that `.reverse` does not raise: `validate_anchor!` checks tenancy only and an old run
  # of the same repository passes it, so the block comes back fully populated, plausible, and
  # anchored on the OLDEST run of the window.
  #
  # Which is why this asserts the SERVED `anchor_run` against the window's newest run rather than
  # merely asserting that some run was named. It is the one example in this file that fails if the
  # `.reverse` is dropped, and it is written to fail LOUDLY: the fixture's newest and oldest runs
  # carry different shas, different timestamps and — through the partition below — different
  # membership.
  describe "⭐ which run the ranking was anchored on" do
    it "names the NEWEST run of the window, never the oldest" do
      window_repository
      newest = repository.test_runs.order(created_at: :desc, id: :desc).first
      oldest = repository.test_runs.order(created_at: :asc, id: :asc).first

      _window, block = blocks(query: { branch: "main" })

      expect(block["anchor_run"]).to eq(
        "test_run_id" => newest.id,
        "commit_sha" => newest.commit_sha,
        "branch" => "main",
        "ingested_at" => newest.created_at.iso8601
      )
      # Stated as a REFUSAL as well, because the two runs are the two answers a reversed window
      # picks between and an assertion naming only the right one reads as an accident.
      expect(block["anchor_run"]["test_run_id"]).not_to eq(oldest.id)
      expect(newest.id).not_to eq(oldest.id)
    end

    # The anchor is a PARTITION and not a label, so the same reversal is asserted where it changes
    # WHICH TESTS ARE SERVED. A test present in the window's oldest runs and gone by the newest is
    # not on this list; anchored on the oldest it would be, and the test that only exists in the
    # newest runs would not.
    it "ranks the tests the newest run holds, and not the ones only the oldest run held" do
      # Two runs of a suite whose slow test was DELETED, then two more of the suite that replaced
      # it — so the two candidate sets are disjoint and the anchor's choice is visible in the rows.
      2.times do |index|
        ingest(repository,
               [example_spec(name: "Legacy importer parses the old format", duration: 99.0,
                             file_path: "spec/models/legacy_spec.rb")],
               commit_sha: "old#{index}sha#{format("%07d", index)}", at: (30 - index).days.ago)
      end
      2.times do |index|
        ingest(repository,
               [example_spec(name: STEADY, duration: 3.0, file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "new#{index}sha#{format("%07d", index)}", at: (10 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })
      descriptions = block["rows"].flat_map { |row| row["descriptions"] }

      expect(descriptions).to eq([STEADY])
      # The 99-second test really is in the window and really is slower — it is excluded by the
      # partition, not by being cheap. Anchored on the oldest run it would lead this list.
      expect(descriptions).not_to include("Legacy importer parses the old format")
    end
  end

  # The happy path, and the contract pin. The body is the whole feature here — there is no prose
  # copy for an agent to read the shape off — so both blocks are pinned EXACTLY rather than key by
  # key, on the rule the sibling file's contract states: a key added without a line in this list
  # fails here, and a listed key quietly dropped fails here too.
  describe "a branch-scoped window whose runs reported per-example timings" do
    before { window_repository }

    it "serves exactly the keys this contract pins, on the window and on the rows block" do
      window, block = blocks(query: { branch: "main" })

      expect(window.keys)
        .to contain_exactly("order", "tie_break_served", "branch_scope", "branch", "grouped")
      expect(block.keys).to contain_exactly(
        "rows", "state", "anchor_run", "run_count", "recorded", "resolved",
        "excluded_unresolved_rows", "recorded_count", "unresolved_count", "resolved_count",
        "candidate_count", "timed_count", "untimed_count", "complete", "truncated",
        "unexamined_count", "limit"
      )
      expect(block["rows"].first.keys).to contain_exactly(
        "spec_identity_id", "total_seconds", "slowest_seconds", "run_count", "recorded_count",
        "timed_count", "untimed_count", "timed", "repeated_within_run", "moved", "renamed",
        "descriptions", "files_seen"
      )
    end

    it "states the window it was drawn over, and claims a reproducible order" do
      window, _block = blocks(query: { branch: "main" })

      expect(window).to eq(
        "order" => "total_seconds_desc_nulls_last,recorded_count_desc,spec_identity_id_asc",
        # TRUE, and it is true because `spec_identity_id` goes out on the row. All four operands of
        # `SlowestTests::Row#sort_key` — the nil flag, the total, the appearance count and the
        # identity — are served, so a client CAN reproduce this exact order.
        "tie_break_served" => true,
        "branch_scope" => "single_branch",
        "branch" => "main",
        "grouped" => true
      )
    end

    # The order is the presenter's own and is NOT re-sorted here — and the claim `tie_break_served`
    # makes is checked rather than taken: the order a client computes from the fields it holds is
    # the order it received.
    it "serves the presenter's order, slowest first, with the untimed row last" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].flat_map { |row| row["descriptions"] })
        .to eq([STEADY, MOVED, RENAMED, RENAMED_WAS, UNTIMED])
      expect(block["rows"].sort_by do |row|
        [row["total_seconds"].nil? ? 1 : 0, -(row["total_seconds"] || 0.0), -row["recorded_count"],
         row["spec_identity_id"]]
      end).to eq(block["rows"])
    end

    # ⭐ The window TOTAL beside the single worst run, and the pair is the point: 12 seconds is one
    # twelve-second test or four runs of a three-second one, and a ranking ordered on the sum alone
    # cannot tell a client which it is looking at.
    it "serves each test's window total beside its single longest run, as numbers and not sentences" do
      _window, block = blocks(query: { branch: "main" })

      steady = row_described(block, STEADY)
      expect(steady).to include(
        "total_seconds" => 12.0, "slowest_seconds" => 3.0, "run_count" => 4,
        "recorded_count" => 4, "timed_count" => 4, "untimed_count" => 0, "timed" => true,
        "repeated_within_run" => false, "moved" => false, "renamed" => false,
        "descriptions" => [STEADY], "files_seen" => ["spec/models/ledger_spec.rb"]
      )
      expect(steady["spec_identity_id"]).to eq(identity_named(STEADY).id)
      # No value on the row is a sentence. `SlowestTests` exposes four label readers
      # (`duration_label`, `slowest_label`, `coverage_label`, `appearance_label`) and not one of
      # them is served — the operands go out and the client divides.
      expect(block["rows"].flat_map(&:keys).uniq)
        .not_to include("duration_label", "slowest_label", "coverage_label", "appearance_label")
    end

    # A group nothing timed serves `null` and never `0.0` — a zero there is a measurement invented
    # out of silence, and it would name the unmeasured test the cheapest in the suite rather than
    # the unknown one.
    it "serves a null duration for a test nothing timed, never a zero" do
      _window, block = blocks(query: { branch: "main" })

      untimed = row_described(block, UNTIMED)
      expect(untimed).to include(
        "total_seconds" => nil, "slowest_seconds" => nil, "timed" => false,
        "timed_count" => 0, "recorded_count" => 4, "untimed_count" => 4
      )
      expect(block["rows"].last).to eq(untimed)
    end

    it "serves the coverage figures the panel words, as counts and booleans" do
      _window, block = blocks(query: { branch: "main" })

      expect(block).to include(
        "state" => "ranked",
        "run_count" => 4,
        "recorded" => true,
        "resolved" => true,
        "excluded_unresolved_rows" => false,
        "recorded_count" => 4,
        "unresolved_count" => 0,
        "resolved_count" => 4,
        "candidate_count" => 4,
        # Three of the anchor's four resolved rows carried a duration; the untimed test is the
        # fourth, and it is a faithful record rather than a defect.
        "timed_count" => 3,
        "untimed_count" => 1,
        "complete" => false,
        "truncated" => false,
        "unexamined_count" => 0,
        "limit" => SpecObservation::SLOWEST_LIMIT
      )
      expect(block.values_at("run_count", "recorded_count", "unresolved_count", "resolved_count",
                             "candidate_count", "timed_count", "untimed_count", "unexamined_count",
                             "limit")).to all(be_an(Integer))
      expect(block.values_at("recorded", "resolved", "excluded_unresolved_rows", "complete",
                             "truncated")).to all(be_in([true, false]))
    end

    # `limit` is read off `SpecObservation`'s own constant rather than restated in the controller,
    # so the response cannot claim a bound the query did not apply.
    it "reports the bound the query actually applied" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["limit"]).to eq(10).and eq(SpecObservation::SLOWEST_LIMIT)
    end
  end

  # ⭐ CRITERION 5 — the two flags that are the whole point of the identity grain, and that no other
  # key on this endpoint can express.
  describe "a test whose file or description changed inside the window" do
    before { window_repository }

    # Under any positional key this is TWO rows of 2 seconds each, neither at its right place in the
    # list. It is ONE row of 4, and it names both files the history it summed came from.
    it "keeps a moved test in one row, flags it, and names both files it was recorded under" do
      _window, block = blocks(query: { branch: "main" })

      moved = row_described(block, MOVED)
      expect(block["rows"].count { |row| row["descriptions"].include?(MOVED) }).to eq(1)
      expect(moved).to include(
        "moved" => true, "renamed" => false, "total_seconds" => 4.0, "run_count" => 4,
        "files_seen" => ["spec/billing/checkout_spec.rb", "spec/models/checkout_spec.rb"],
        "descriptions" => [MOVED]
      )
    end

    # ⭐ The same guarantee on the other axis — and the one `unstable_tests` is STRUCTURALLY
    # incapable of making, since grouped on `name` a reword is two tests there. The descriptions come
    # back as a SET, so neither is "the current one" and the row serves both rather than promoting
    # one and discarding the rest.
    it "keeps a reworded test in one row, flags it, and names both descriptions it wore" do
      _window, block = blocks(query: { branch: "main" })

      renamed = row_described(block, RENAMED)
      expect(renamed).to include(
        "renamed" => true, "moved" => false, "total_seconds" => 2.0, "run_count" => 4,
        "descriptions" => [RENAMED, RENAMED_WAS].sort,
        "files_seen" => ["spec/models/invoice_spec.rb"]
      )
      # And the flag is not a decoration every row wears: the test that did neither says so.
      expect(row_described(block, STEADY)).to include("moved" => false, "renamed" => false)
    end

    # `unstable_tests` groups on `name` over the SAME window in the SAME response, so the row above
    # is nameable proof of what this block adds: two descriptions there, one test here.
    it "serves an identity the name-grained sibling block cannot express" do
      body = get_repository(query: { branch: "main" })

      expect(body["slowest_tests"]["rows"].map { |row| row["spec_identity_id"] }).to all(be_present)
      # The sibling serves no identity at all — which is precisely why a client holding it cannot
      # rebuild this ranking, and why `tie_break_served` is `false` on windows whose key is withheld.
      expect(body["unstable_tests"]["rows"].flat_map(&:keys)).not_to include("spec_identity_id")
    end

    # A test that ran more than once inside a single run — a table-driven loop, or a shared example
    # group — is one identity and several rows, and that is what separates "slow in four runs" from
    # "run twice in each of two".
    it "flags a test that ran more than once inside a run, with both operands beside the boolean" do
      repo = create_repository(user: @user, github_full_name: "acme/loop-service")
      2.times do |index|
        specs = 3.times.map do |case_index|
          example_spec(name: "Currency converts each supported code", duration: 2.0, line_number: 1,
                       file_path: "spec/models/currency_spec.rb",
                       id: "./spec/models/currency_spec.rb[1:#{case_index}]")
        end
        ingest(repo, specs, commit_sha: "loop#{index}sha#{format("%06d", index)}",
                            at: (30 - index).days.ago)
      end

      _window, block = blocks(repo: repo, query: { branch: "main" })

      expect(block["rows"].first).to include(
        "repeated_within_run" => true, "recorded_count" => 6, "run_count" => 2,
        "total_seconds" => 12.0, "slowest_seconds" => 2.0
      )
    end
  end

  # ⭐ CRITERION 3 — the one real design decision, and the one this block would be an anchor-picking
  # accident without. `SlowestTests#branch`: *"Runtimes compared across branches are runtimes of
  # different code, so the window is branch-anchored exactly as those are."*
  describe "an unfiltered window whose runs interleave two branches" do
    # Alternating `main` and `feature/x`, with a test that exists ONLY on the feature branch. Over
    # the interleaved window the anchor is whichever branch ran last, so the partition it decides
    # ranks one branch's tests against the other's history. Grouped per branch neither can happen.
    # A falsifier rather than a smoke test.
    def interleaved_repository
      6.times do |index|
        specs = [example_spec(name: STEADY, duration: 3.0, file_path: "spec/models/ledger_spec.rb")]
        specs << example_spec(name: "Feature flag gates the new checkout", duration: 9.0, line_number: 2,
                              file_path: "spec/models/flag_spec.rb")                        unless index.even?
        ingest(repository, specs, commit_sha: "mix#{index}sha#{format("%07d", index)}",
                                  branch: index.even? ? "main" : "feature/x", at: (30 - index).days.ago)
      end
      repository
    end

    it "serves null rows and a window that says why, rather than an empty list" do
      interleaved_repository

      window, block = blocks

      expect(block).to be_nil
      expect(window).to eq(
        "order" => "total_seconds_desc_nulls_last,recorded_count_desc,spec_identity_id_asc",
        "tie_break_served" => true,
        "branch_scope" => "all_branches",
        "branch" => nil,
        "grouped" => false
      )
      # The key is PRESENT and null — never absent — so a client tests one thing rather than
      # distinguishing an absent key from a null one.
      expect(get_repository).to have_key("slowest_tests")
    end

    # The refusal, made non-vacuous. The same window under `?branch=` DOES reach the ranking and DOES
    # report the branch honestly, so the null above is a decision about SCOPE rather than a fixture
    # with nothing in it.
    it "ranks the same window once a branch is named, per branch and not across them" do
      interleaved_repository

      _main_window, main_block = blocks(query: { branch: "main" })
      feature_window, feature_block = blocks(query: { branch: "feature/x" })

      expect(main_block["state"]).to eq("ranked")
      expect(main_block["run_count"]).to eq(3)
      expect(main_block["rows"].flat_map { |row| row["descriptions"] }).to eq([STEADY])

      expect(feature_window["branch"]).to eq("feature/x")
      expect(feature_block["run_count"]).to eq(3)
      # The feature branch's own test leads its own list — and is absent from `main`'s above, which
      # is the whole of what branch-anchoring buys.
      expect(feature_block["rows"].flat_map { |row| row["descriptions"] })
        .to eq(["Feature flag gates the new checkout", STEADY])
    end
  end

  # ⭐ CRITERION 2 and CRITERION 6 — the four states, the one that must never read as "nothing is
  # slow", and the `null`-versus-`0` split that lets a client tell a pre-read figure from a measured
  # zero.
  describe "the states in which there is no ranking to serve" do
    # THE POST-INGEST STATE, and the reason `state` is on this block at all.
    # `Ingest::IdentityResolutionJob` is asynchronous, so this is what EVERY run looks like for the
    # seconds after it lands. Served as an empty list it is "nobody has told us which tests these
    # are" wearing the spelling of "everything is fast".
    it "distinguishes an unresolved window from a ranked one with nothing slow in it" do
      window_repository(resolve: false)

      window, block = blocks(query: { branch: "main" })

      expect(window["grouped"]).to be(true)
      expect(block["state"]).to eq("unresolved")
      expect(block["rows"]).to eq([])
      expect(block["anchor_run"]).to be_present
      # The window HAS per-example rows — the resolver simply has not reached them. Both facts are
      # served, because only the first separates this from a repository with no per-example grain.
      expect(block).to include(
        "recorded" => true, "resolved" => false, "recorded_count" => 4,
        "unresolved_count" => 4, "excluded_unresolved_rows" => true
      )
    end

    # ⭐ CRITERION 6 — the `UNREAD` split, and the ONE example in this file that fails if the
    # controller fabricates a zero. In `unresolved` the candidate step never ran, so `resolved_count`,
    # `candidate_count` and `timed_count` are figures nothing measured: a `0` there is
    # wire-indistinguishable from a window MEASURED to have found none, which is exactly the
    # distinction these keys exist to let a client draw.
    it "serves null — never zero — for the figures the read that would have produced them never reached" do
      window_repository(resolve: false)

      _window, block = blocks(query: { branch: "main" })

      # Asserted through `include` rather than on fetched values, so this pins the keys
      # PRESENT-and-null: a payload that dropped them would satisfy `be_nil` and is a different bug.
      expect(block).to include("resolved_count" => nil, "candidate_count" => nil, "timed_count" => nil)
      # And the two figures the gate DID read are real counts of a real population — the split is
      # per-key and not a blanket nulling of the block.
      expect(block).to include("recorded_count" => 4, "unresolved_count" => 4)
    end

    # A different absence, and one nothing is going to clear on its own: the newest run reported no
    # per-example detail at all, so there is no per-test grain to rank at any identity.
    it "serves the unrecorded state, distinguishably, when the anchor wrote no rows" do
      ingest(repository, [], commit_sha: "empty0sha000001", at: 2.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block["state"]).to eq("unrecorded")
      expect(block["rows"]).to eq([])
      expect(block).to include("recorded" => false, "resolved" => false, "recorded_count" => 0,
                               "unresolved_count" => 0)
      # Pre-read on this state too, for the same reason — the candidate step is behind the gate.
      expect(block).to include("resolved_count" => nil, "candidate_count" => nil, "timed_count" => nil)
      expect(block["anchor_run"]).to be_present
    end

    # The fourth state: a named branch with no runs at all. `SlowestTests` returns `:no_runs` before
    # touching the database, so every figure is `nil` and there is no run to name.
    it "serves the no-runs state with a null anchor, over a branch that never ran" do
      window_repository

      _window, block = blocks(query: { branch: "does-not-exist" })

      expect(block["state"]).to eq("no_runs")
      expect(block["rows"]).to eq([])
      expect(block["run_count"]).to eq(0)
      expect(block["anchor_run"]).to be_nil
      expect(block).to include("recorded_count" => nil, "unresolved_count" => nil,
                               "resolved_count" => nil, "candidate_count" => nil,
                               "timed_count" => nil)
      expect(block).to include("recorded" => false, "resolved" => false, "complete" => false,
                               "truncated" => false)
    end

    # ⭐ CRITERION 4, CORRECTED AGAINST THE OBJECT — and the correction is the finding, so it is
    # recorded here rather than silently coded around.
    #
    # The ticket asks for an example serving `rows: []` beside `state: "ranked"` — "we ranked and
    # nothing in this suite is slow" — as a real answer distinct from the three empty states above.
    # THAT PAIR IS STRUCTURALLY UNREACHABLE, and the reason is a property of `SlowestTests.rank`
    # rather than a gap in this fixture. `:ranked` is returned only when `resolved_rows.positive?`;
    # `.slowest_identity_candidates_in` groups over exactly those resolved anchor rows, so a
    # positive count there guarantees at least one candidate; and
    # `.identity_duration_composition_in` is passed `run_ids` INCLUDING the anchor, so every
    # candidate matches at least its own anchor row and comes back as a group. A `:ranked` state
    # therefore always carries at least one row.
    #
    # The asymmetry with `unstable_tests` — where `rows: []` beside `comparable: true` IS a real and
    # ordinary answer — is not an oversight in either object. That block ranks tests whose outcome
    # CHANGED, and a window in which nothing flipped is the healthy case. This one ranks tests by
    # what they COST, and every resolved test has a cost, however small: "nothing is slow" is not a
    # state a duration ranking can be in, because slowness here is an ORDER and not a threshold. So
    # the honest pin is the one below — that the ranked state is distinguishable from the three
    # empty ones — and NOT an assertion about an empty list that no input can produce.
    it "serves the ranked state with rows, never as the empty list the three gating states serve" do
      # A test the anchor did not run — present in the window and excluded by the ⭐ partition, so
      # the ranking is drawn from a genuinely narrowed population rather than from everything.
      ingest(repository,
             [example_spec(name: "Legacy importer parses the old format", duration: 9.0,
                           file_path: "spec/models/legacy_spec.rb")],
             commit_sha: "gone0sha0000001", at: 5.days.ago)
      ingest(repository,
             [example_spec(name: STEADY, duration: 3.0, file_path: "spec/models/ledger_spec.rb")],
             commit_sha: "here0sha0000002", at: 1.day.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block["state"]).to eq("ranked")
      expect(block["rows"].flat_map { |row| row["descriptions"] }).to eq([STEADY])
      expect(block).to include("recorded" => true, "resolved" => true, "resolved_count" => 1)
      # The partition really did exclude the slower test, so the list above is a narrowed answer and
      # not simply everything the window held.
      expect(block["rows"].length).to eq(1)
    end

    # The claim the example above rests on, asserted against the OBJECT rather than left as prose:
    # no input produces `:ranked` with an empty list. Written as a property over the states this
    # file already builds, so a future change to `rank` that made the pair reachable fails HERE —
    # beside the comment explaining why the ticket asked for it — rather than in a client.
    it "never serves a ranked state with an empty list, on any window this file can build" do
      unrecorded = create_repository(user: @user, github_full_name: "acme/empty-anchor")
      ingest(unrecorded, [], commit_sha: "blank1sha000001", at: 2.days.ago)
      unresolved = create_repository(user: @user, github_full_name: "acme/pending")
      ingest(unresolved, window_specs(0), commit_sha: "unres1sha000001", at: 2.days.ago, resolve: false)
      window_repository

      [repository, unrecorded, unresolved, create_repository(user: @user, github_full_name: "acme/bare")]
        .each do |repo|
          _window, block = blocks(repo: repo, query: { branch: "main" })

          expect(block["rows"].empty?).to eq(block["state"] != "ranked"),
                                          "#{repo.github_full_name} served state=#{block["state"]} " \
                                          "with #{block["rows"].length} rows"
        end
    end

    # The states are FOUR, and the pin is that no two of them serialize alike. Read together rather
    # than one at a time, because the failure this guards is a serializer that collapses two of them
    # into the same body.
    it "serves four states that a client can tell apart" do
      no_runs = create_repository(user: @user, github_full_name: "acme/no-runs")
      unrecorded = create_repository(user: @user, github_full_name: "acme/unrecorded")
      ingest(unrecorded, [], commit_sha: "blank0sha000001", at: 2.days.ago)
      unresolved = create_repository(user: @user, github_full_name: "acme/unresolved")
      ingest(unresolved, window_specs(0), commit_sha: "unres0sha000001", at: 2.days.ago, resolve: false)
      window_repository

      states = [no_runs, unrecorded, unresolved, repository].map do |repo|
        _window, block = blocks(repo: repo, query: { branch: "main" })
        block["state"]
      end

      expect(states).to eq(%w[no_runs unrecorded unresolved ranked])
    end
  end

  # ⭐ CRITERION 7 — the cap, disclosed with both operands beside the boolean. A capped list that
  # does not say it stopped is read as the whole story.
  describe "a window whose anchor holds more tests than the ranking examines" do
    it "discloses the cap, with the operands a client checks it against" do
      2.times do |index|
        specs = (1..14).map do |i|
          example_spec(name: "Ledger step #{i} settles the balance", duration: i.to_f,
                       file_path: "spec/models/ledger_spec.rb", line_number: i,
                       id: "./spec/models/ledger_spec.rb[1:#{i}]")
        end
        ingest(repository, specs, commit_sha: "cap#{index}sha#{format("%07d", index)}",
                                  at: (30 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })

      expect(block["state"]).to eq("ranked")
      expect(block["rows"].length).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(block).to include(
        "truncated" => true,
        "candidate_count" => 14,
        "unexamined_count" => 4,
        "limit" => SpecObservation::SLOWEST_LIMIT
      )
      # The boolean is checkable against the operands rather than merely trusted — the endpoint
      # serves what it compared, not only its verdict.
      expect(block["candidate_count"] - block["rows"].length).to eq(block["unexamined_count"])
      expect(block["candidate_count"] > block["rows"].length).to eq(block["truncated"])
    end

    # And the uncapped window says so — a `truncated: false` that is a measurement rather than a
    # constant.
    it "reports no truncation on a window the cap did not bite" do
      window_repository

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("truncated" => false, "unexamined_count" => 0, "candidate_count" => 4)
    end
  end

  # What this block costs the endpoint, ON A RESOLVED WINDOW — the case no other file can pin.
  #
  # ⚠️ THIS EXAMPLE EXISTS BECAUSE THE OTHER TWO CANNOT REACH THE STATE IT MEASURES, and that is a
  # property of their fixtures rather than an oversight in them. `repository_unstable_tests_spec.rb`
  # and `repository_directory_growth_spec.rb` both assert `identity.length == 1`, and both say in
  # their own comments WHY: they ingest through `Ingest::RunRecorder` WITHOUT
  # `Ingest::IdentityResolver`, so every `spec_identity_id` is NULL, `SlowestTests` stops at its
  # presence probe, and the two GROUPED reads are never issued. Between them they pin the `1` of the
  # grain's "0, 1 or 3 and never 2" contract and neither can pin the `3`.
  #
  # That left `ObservationGrainReads::IDENTITY_GROUPING` matched by NO committed example —
  # mutation-verified: replacing it with a pattern that cannot match leaves both of those files
  # green, while breaking `IDENTITY_PRESENCE` fails them both. A grain pattern that silently matches
  # nothing is the exact failure that file's header is an argument against, and it reports zero reads
  # for a grain that fired rather than a red example. This example is the guard for the half of the
  # partition the unresolved fixtures structurally cannot exercise.
  describe "what the block costs the endpoint on a window it can rank" do
    it "issues three identity reads — the presence probe, then the two grouped reads" do
      window_repository

      reads = observation_reads { get_repository(query: { branch: "main" }) }

      # THE SPLIT, not merely the total: asserted per pattern so a read migrating from one statement
      # family to the other cannot hide inside a still-correct `3`.
      expect(reads.grep(ObservationGrainReads::IDENTITY_PRESENCE).length).to eq(1)
      expect(reads.grep(ObservationGrainReads::IDENTITY_GROUPING).length).to eq(2)
      expect(identity_grain_reads { get_repository(query: { branch: "main" }) }.length).to eq(3)
      # And the two patterns are DISJOINT over these statements — the property that lets one grain
      # carry two patterns without double-counting, which `classified_observation_reads` would
      # otherwise catch as parts summing to more than the total.
      expect(reads.grep(ObservationGrainReads::IDENTITY_PRESENCE)
                  .grep(ObservationGrainReads::IDENTITY_GROUPING)).to eq([])
    end

    # The gated half of the same contract, stated here beside the ranked one rather than inferred:
    # unfiltered, `SlowestTests` is never constructed and the grain is EMPTY.
    it "issues none at all when no branch was asked for" do
      window_repository

      expect(identity_grain_reads { get_repository }).to eq([])
    end
  end

  # The block sits BESIDE `unstable_tests` and NOT inside `latest_run`, on that block's own
  # membership rule: `latest_run` is single-run facts by construction, and this is a statement about
  # one test across several runs. Pinned, because a later hand moving it would break every client's
  # path without breaking a single assertion above.
  describe "where the block sits in the body" do
    it "is served beside unstable_tests and never inside latest_run" do
      window_repository

      body = get_repository(query: { branch: "main" })

      expect(body).to have_key("slowest_tests").and have_key("slowest_tests_window")
      expect(body["latest_run"]).not_to have_key("slowest_tests")
      # And its single-run complement is untouched where it has always been: this block is that
      # one's window-grain sibling, not its replacement.
      expect(body["latest_run"]).to have_key("slowest_examples")
    end
  end
end
