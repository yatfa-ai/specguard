# frozen_string_literal: true

require "rails_helper"

# The `unstable_tests.unstable_test_runs` block on `GET /api/v1/repository` — ONE unstable test,
# opened, run by run, and the fourth drill-in on this endpoint's own ladder:
#
#   latest_run.spec_directories      → spec_directory_files          ?spec_directory=
#   latest_run.spec_files            → spec_file_examples            ?spec_file=
#   latest_run.repeated_descriptions → repeated_description_examples ?repeated_description=
#   unstable_tests                   → unstable_test_runs            ?unstable_test=
#
# THE ONE QUESTION THE RANKING ABOVE CANNOT ANSWER, and the reason this file exists. A row of
# `unstable_tests` says `run_count: 30`, `failed_run_count: 4`, `outcome_words: ["failed",
# "passed"]`. Those three figures are IDENTICAL for two windows that call for opposite work — four
# failures in the last four runs is a regression with a culprit commit to find, four failures
# scattered through the window is flakiness with none — and an agent told to "fix the flaky tests"
# treats the first as the second and hunts nondeterminism in a test that fails deterministically.
# `SpecObservation::UNSTABLE_COMPOSITION` is every column a `COUNT` or an `ARRAY_AGG(DISTINCT …)`
# under `GROUP BY name`, which is exactly right for a ranking; the run axis is gone before the row is
# built. The example marked ⭐ below is that pair, asserted as a pair.
#
# Its own file, beside `repository_unstable_tests_spec.rb`, on the precedent its three sibling
# drill-in files set: every example here needs a multi-RUN fixture built to a SHAPE — a failing tail
# against a scattered middle — under a query parameter no other block on this endpoint reads, where
# the file next door builds windows to exercise the ranking's gates.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never inserted
# by hand — the rule every sibling here states, and for the same reason: a nil `outcome` is a real
# client's `result&.status` coming back nil, and two examples sharing a description in one run is
# what the recorder produces from a table-driven loop. A hand-built fixture would be asserting
# against shapes nothing in production writes.
RSpec.describe "GET /api/v1/repository — unstable_tests.unstable_test_runs", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  # `repo:` names a SECOND repository — the discriminating example below needs two windows side by
  # side — and defaults to the memoized key of the first, so the cost examples are not counting an
  # API key being created inside the block they are measuring.
  def get_repository(repo: nil, key: nil, query: {})
    token = (key || (repo ? repo.api_keys.create! : api_key)).raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  # The parent block and the drill-in inside it, always available together: the drill-in is nested,
  # so reading it without its parent is how a `null` gets asserted without its reason.
  def parent(**) = get_repository(**)["unstable_tests"]

  def block(**) = parent(**)&.dig("unstable_test_runs")

  def rows(**) = block(**)["rows"]

  # One ingested CI run, through the producer. Every run is stamped back in time so the window orders
  # them the way CI produced them rather than by whatever order the fixture inserted them in.
  def ingest(repo, specs, commit_sha:, branch: "main", at: nil)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    # Resolved inline: the ranking this drill-in sits under groups on the durable identity
    # (SPGD-758), so an unresolved row never reaches it.
    Ingest::IdentityResolver.resolve(run)
    run
  end

  # One example on the wire. `outcome:` and `name:` are passed at every call site, nils included — an
  # unreported outcome is a state this file turns on, and the shared builder substitutes a default
  # for a nil `name:`, so both are merged in rather than passed through.
  def example_spec(name:, outcome:, line_number: 1, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: 0.1)
      .merge({ name: name, outcome: outcome }.merge(attrs))
  end

  # METHODS and deliberately not constants, on the rule
  # `repository_repeated_description_examples_spec.rb` states: a constant assigned inside an
  # `RSpec.describe` block opens no constant scope and lands on `Object`, where the sibling file
  # `repository_unstable_tests_spec.rb` — which names the same test the same way, because it is the
  # same fixture one rung up — would be deciding the value BOTH files read at run time.
  def flipping_test = "Invoice finalize locks the line items"

  def invoice_spec = "spec/models/invoice_spec.rb"

  # A repository whose window holds one run per entry of `outcomes_per_run`, IN THAT ORDER — index 0
  # is the OLDEST run and the last entry is the newest, which is the order CI produced them in and
  # the reverse of the order the window is read in. Every list in this file is therefore written the
  # way a reader would describe their own history ("it went green, green, then red, red") and
  # asserted against the reversal of itself, which is the whole subject here.
  #
  # Each run also carries a second, stable test, so a window of nils is a window that reported
  # NOTHING rather than one test going quiet.
  def repository_with(outcomes_per_run, name: flipping_test, branch: "main", repo: repository, **attrs)
    outcomes_per_run.each_with_index do |outcome, index|
      ingest(repo,
             [example_spec(name: name, outcome: outcome, line_number: 1, **attrs),
              example_spec(name: "User signs in", outcome: outcome.nil? ? nil : "passed",
                           line_number: 2, file_path: "spec/models/user_spec.rb")],
             commit_sha: "run#{format("%010d", index)}", branch: branch,
             at: (30 - index).days.ago)
    end
    repo
  end

  def sha_for(index) = "run#{format("%010d", index)}"

  def run_for(index) = TestRun.find_by!(commit_sha: sha_for(index))

  describe "the sequence itself" do
    # Chronologically: passed, failed, passed, passed, failed. Read newest-first, that is
    # failed, passed, passed, failed, passed.
    before { repository_with(%w[passed failed passed passed failed]) }

    # The block's own contract, pinned EXACTLY on the precedent its parent block's shape pin sets:
    # a key added without a line here fails, and a listed key quietly dropped fails too. The two
    # computed readings ride the same rule as everything above them — present on every asked
    # request, in every state the block can hold (the empty answer pins them withheld in the
    # examples below headed "the ways this key can be empty").
    # @intent: { entity: "unstable_test_runs", action: "pin the block shape", behavior: "exactly the contracted keys appear on the drill-in block, including the onset and duration-step readings", layer: "request" }
    it "serves exactly the keys this contract pins on the block" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served.keys).to contain_exactly(
        "name", "rows", "recorded_count", "reported_outcome_count", "unreported_outcome_count",
        "run_count", "limit",
        # SPGD-2007, the panel's two computed readings served as operands. `onset` answers the
        # boundary the console's line names; `duration_step` answers the pace jump, for every
        # origin — the console's `?unstable_test_from=` gate has no API counterpart to honour.
        "onset", "duration_step"
      )
    end

    # AC1 at the row grain. Run identity BESIDE the test's own fields, because either half alone is
    # useless: an outcome with no commit cannot be attributed and a commit with no outcome is the
    # `history` row that already exists.
    # @intent: { entity: "unstable_test_runs", action: "attach run identity to each row", behavior: "every served row pairs the outcome with its test_run_id, commit_sha, branch and ingested_at so a failure can be attributed to the exact CI run that recorded it", layer: "request" }
    it "carries the run's identity beside that run's record of the test" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.first).to eq(
        "test_run_id" => run_for(4).id,
        "commit_sha" => sha_for(4),
        "branch" => "main",
        "ingested_at" => run_for(4).created_at.iso8601,
        "outcome" => "failed",
        "duration_seconds" => 0.1,
        "spec_file_path" => invoice_spec,
        "line_number" => 1
      )
    end

    # AC1. One row per run of the window, in WINDOW ORDER — which is the endpoint's own newest-first
    # order and not ingest order. The sequence is the point of the block; a set would be the ranking
    # above.
    # @intent: { entity: "unstable_test_runs", action: "order the rows newest run first", behavior: "the sequence mirrors the endpoint window order rather than ingest order, one row per run that recorded the test", layer: "request" }
    it "serves one row per run of the window, newest run first" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { it["commit_sha"] }).to eq((0..4).to_a.reverse.map { sha_for(it) })
      expect(served.map { it["outcome"] }).to eq(%w[failed passed passed failed passed])
    end

    # THE JOIN THIS BLOCK EXISTS TO MAKE POSSIBLE, asserted rather than described. `history` rows
    # carry `commit_sha` and these rows carry `commit_sha`, so an agent holding both can name the
    # commit a test started failing at — and both are served from the same already-loaded window
    # rather than from two fetches of "the last thirty runs" that agree today, so the two lists share
    # that window and read in the same direction.
    #
    # THE INDICES MATCHING HERE IS A PROPERTY OF THIS FIXTURE, NOT OF THE BLOCK. `repository_with`
    # puts the test in every run exactly once, which is the one shape where a row count equals a run
    # count; the join key is the `commit_sha` on the row, and the example below headed "a window the
    # description is absent from some runs of" is the same query with a hole in it, where these two
    # lists are different lengths and the positions no longer correspond.
    # @intent: { entity: "unstable_test_runs", action: "align with the history block", behavior: "the drill-in and the history rows share one loaded window and one reading direction so their commit_sha lists join without a second fetch or a reversal", layer: "request" }
    it "shares the window and its ordering with the history rows it is meant to be joined against" do
      body = get_repository(query: { branch: "main", unstable_test: flipping_test })
      shas = body.dig("unstable_tests", "unstable_test_runs", "rows").map { it["commit_sha"] }

      expect(shas).to eq(body["history"].map { it["commit_sha"] })
    end

    # AC3, said as the sentence the reader acts on: the run a failure began at is reachable by
    # walking this list from its old end, with no arithmetic over anything else in the body.
    # @intent: { entity: "unstable_test_runs", action: "expose the first failure in the window", behavior: "walking the newest-first list to its old end names the earliest run that failed, with no arithmetic over the rest of the body", layer: "request" }
    it "names the earliest run of the window that recorded a failure" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })
      first_failure = served.reverse.find { it["outcome"] == "failed" }

      expect(first_failure["commit_sha"]).to eq(sha_for(1))
    end
  end

  # ⭐ AC3. THE WHOLE POINT, and the one assertion no other key on this endpoint can make. Two windows
  # the ranking cannot tell apart, told apart. Both terms are asserted — the ranking's figures
  # IDENTICAL, the sequences DIFFERENT — so the example cannot be satisfied by the two repositories
  # merely differing somewhere.
  describe "two windows the ranking above cannot tell apart" do
    # One user, two repositories: `create_repository`'s default builds a user, and `github_uid` is
    # unique, so a second default call would be a second user claiming the first one's identity.
    def second_repository(name) = create_repository(user: repository.user, github_full_name: name)

    # @intent: { entity: "unstable_test_runs", action: "tell a regression from flakiness", behavior: "two windows whose ranking figures are identical get different run-ordered outcome sequences, so a failing tail reads differently from a scattered alternation", layer: "request" }
    it "distinguishes a regression from flakiness" do
      regressed = repository_with(%w[passed passed passed passed passed passed failed failed failed failed],
                                  repo: second_repository("acme/regressed"))
      flaky = repository_with(%w[passed failed passed failed passed failed passed failed passed passed],
                              repo: second_repository("acme/flaky"))

      query = { branch: "main", unstable_test: flipping_test }
      regressed_block = parent(repo: regressed, query: query)
      flaky_block = parent(repo: flaky, query: query)

      # The ranking is blind to the difference, and that is not a defect in it: a `COUNT` of failures
      # over a window is the same integer whichever runs they landed in. `spec_identity_id` is
      # excluded because it names the ROW's own identity — two repositories resolve their
      # descriptions to two different identity rows, and the sameness being asserted here is in
      # every figure ABOUT the window, not in which database row holds the test.
      expect(regressed_block["rows"].map { |row| row.except("spec_identity_id") })
        .to eq(flaky_block["rows"].map { |row| row.except("spec_identity_id") })
      expect(regressed_block.dig("rows", 0)).to include(
        "run_count" => 10, "failed_run_count" => 4, "outcome_words" => %w[failed passed]
      )

      # The drill-in is not. Read newest-first: four failures then six passes, against an alternation.
      expect(regressed_block.dig("unstable_test_runs", "rows").map { it["outcome"] })
        .to eq(%w[failed failed failed failed passed passed passed passed passed passed])
      expect(flaky_block.dig("unstable_test_runs", "rows").map { it["outcome"] })
        .to eq(%w[passed passed failed passed failed passed failed passed failed passed])
    end
  end

  # SPGD-2007 — THE COMPUTED READINGS, and the panel's answer to the pair the block above
  # distinguishes by hand. The console panel names the boundary in words
  # (`UnstableTestRunOnset`) and the pace jump in one more line (`UnstableTestRunDurationStep`);
  # this block pins the API's copy of both readings, served as operand keys beside the sequence
  # they were computed from — same presenters, same withhold arms, no prose. The origin gate the
  # console puts on the step line (`?unstable_test_from=slowest-examples`) has NO API counterpart
  # to honour, so the step is served for every ask.
  #
  # ⭐ THE ORIENTATION EVERY EXAMPLE HERE GUARDS. The presenters walk `rows` from the window's
  # newest end, and the rows on THIS endpoint arrive newest FIRST — the opposite of the
  # oldest-first window the panel renders beside. Handed as-is, a trailing regression reads
  # `newest_not_failed` (the window's oldest run, its far row, is the newest row of the reversed
  # list) and the block serves a withhold over exactly the window the panel offers an onset for.
  # Every offered assertion below names the boundary at OLDEST-FIRST indices, which the served
  # rows' own order inverts — so a serializer that skipped the re-orientation fails these
  # examples rather than passing them with a different shape.
  describe "naming the regression onset and the duration step, as the panel does" do
    # Chronologically: passed, passed, failed, failed — a textbook trailing regression whose
    # boundary sits at oldest-first runs 1 → 2, which is rows 1 → 2 of the SERVED list reversed.
    # The default fixture every onset example below reads.
    before { repository_with(%w[passed passed failed failed]) }

    # The run operands the readings name their ends by, resolved against ONE repository — sha
    # values repeat across repositories, so the run is looked up through the repo's own runs and
    # never globally.
    def run_operand(repo, index)
      run = repo.test_runs.find_by!(commit_sha: sha_for(index))

      { "test_run_id" => run.id, "commit_sha" => run.commit_sha, "branch" => run.branch,
        "ingested_at" => run.created_at.iso8601 }
    end

    def second_repository(name) = create_repository(user: repository.user, github_full_name: name)

    # One repository whose window holds one run per entry of `durations_per_run`, every run
    # passing unless `outcomes:` says otherwise — the step reading's input in the shape the
    # console's own fixture file uses, and, with a trailing failure passed in, the fixture whose
    # BOTH readings are offered at once (the cost example's).
    def repository_with_durations(durations_per_run, outcomes: nil, repo: repository)
      outcomes ||= Array.new(durations_per_run.length, "passed")
      durations_per_run.each_with_index do |duration, index|
        outcome = outcomes[index]
        ingest(repo,
               [example_spec(name: flipping_test, outcome: outcome, line_number: 1, duration: duration),
                example_spec(name: "User signs in", outcome: outcome.nil? ? nil : "passed", line_number: 2,
                             file_path: "spec/models/user_spec.rb")],
               commit_sha: sha_for(index), branch: "main", at: (30 - index).days.ago)
      end
      repo
    end

    # AC: the correct pair DESPITE the newest-first rows — the whole point of the orientation
    # guard above. The pair is also pinned EXACTLY, so a fourth key on an operand fails here.
    # @intent: { entity: "unstable_test_runs.onset", action: "serve the offered boundary pair", behavior: "a trailing regression serves the last passing and first failing run at their oldest-first positions, with the compare range between their shas, while the rows themselves keep the window's newest-first direction", layer: "request" }
    it "serves the pass→fail boundary pair despite the rows arriving newest-first" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["onset"]).to eq(
        "state" => "offered", "reason" => nil,
        "last_pass" => run_operand(repository, 1),
        "first_fail" => run_operand(repository, 2),
        "compare" => repository.github_compare_url(sha_for(1), sha_for(2))
      )
      # The sequence the readings were computed over is NOT the one served: the rows keep the
      # window's own newest-first direction, and the reversal the presenters need happens beside
      # them, not under them.
      expect(served["rows"].map { it["commit_sha"] })
        .to eq([sha_for(3), sha_for(2), sha_for(1), sha_for(0)])
    end

    # The window OPENS inside the regression: every run that reported an outcome failed, so the
    # last pass this window saw is none. An answer, not a withhold — with no operands and no
    # range, because a range needs a passing run on this side of the window and there is none.
    # @intent: { entity: "unstable_test_runs.onset", action: "answer failing since window start", behavior: "a window whose every reported run failed serves state failing_since_window_start with no operands and no compare", layer: "request" }
    it "answers failing_since_window_start when every reported run failed" do
      predates = repository_with(%w[failed failed failed], repo: second_repository("acme/onset-predates"))

      onset = parent(repo: predates, query: { branch: "main", unstable_test: flipping_test })
              .dig("unstable_test_runs", "onset")

      expect(onset).to eq("state" => "failing_since_window_start", "reason" => nil,
                          "last_pass" => nil, "first_fail" => nil, "compare" => nil)
    end

    # THE FLAKINESS SHAPE — failures scattered through the window, the newest one included. The
    # newest run FAILED (otherwise the reading stops one arm earlier, at `newest_not_failed`) and
    # a failure sits OLDER than the last passing run, which is the arm the flakiness shape is:
    # the trailing block and its boundary are perfectly clean and the onset is still refused,
    # because the newest failure of a scattered window is the latest failure and not the first
    # one.
    # @intent: { entity: "unstable_test_runs.onset", action: "withhold on scattered failures", behavior: "a failed newest run with an older failure before the last pass serves withheld with reason scattered, no operands and no compare", layer: "request" }
    it "withholds with the scattered reason over the flakiness shape" do
      flaky_repo = repository_with(%w[passed failed passed failed failed],
                                   repo: second_repository("acme/onset-scattered"))

      onset = parent(repo: flaky_repo, query: { branch: "main", unstable_test: flipping_test })
              .dig("unstable_test_runs", "onset")

      expect(onset).to eq("state" => "withheld", "reason" => "scattered", "last_pass" => nil,
                          "first_fail" => nil, "compare" => nil)
    end

    # THE CAP, for both readings at once — the arm each presenter checks FIRST, so the two
    # cannot disagree with each other or with the block's own `recorded_count > rows.length`
    # comparison about whether the cap bit.
    # @intent: { entity: "unstable_test_runs", action: "withhold both readings when capped", behavior: "a capped sequence serves withheld with reason capped on both the onset and the duration step, keeping the readings in agreement with the cap operands", layer: "request" }
    it "withholds both readings with the capped reason when the cap took the newest rows" do
      stub_const("SpecObservation::UNSTABLE_TEST_RUNS_LIMIT", 2)

      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["recorded_count"]).to eq(4)
      expect(served["rows"].length).to eq(2)
      expect(served["onset"]).to include("state" => "withheld", "reason" => "capped",
                                         "compare" => nil)
      expect(served["duration_step"]).to include("state" => "withheld", "reason" => "capped",
                                                 "compare" => nil)
    end

    # THE STEP, offered: a green, steadily passing window whose pace jumped from one second to
    # four. The ends carry the SUMMED run durations (one example per run here, so sum and
    # per-row agree — the multi-example reduction is the presenter's own spec's to pin), and the
    # compare range is between the two ends' shas.
    # @intent: { entity: "unstable_test_runs.duration_step", action: "serve the offered step", behavior: "a passing window with a pace jump serves the largest run-over-run rise with both ends as run operands carrying the summed durations, and the compare range between their shas", layer: "request" }
    it "serves the largest run-over-run rise with both ends and their summed durations" do
      slowed = repository_with_durations([1.0, 1.1, 1.0, 4.2, 4.3],
                                         repo: second_repository("acme/onset-slowed"))

      step = parent(repo: slowed, query: { branch: "main", unstable_test: flipping_test })
             .dig("unstable_test_runs", "duration_step")

      expect(step).to eq(
        "state" => "offered", "reason" => nil,
        "from" => run_operand(slowed, 2).merge("seconds" => 1.0),
        "to" => run_operand(slowed, 3).merge("seconds" => 4.2),
        "compare" => slowed.github_compare_url(sha_for(2), sha_for(3))
      )
    end

    # Two withhold arms beside the cap above, each on its own shape: a window that only ever got
    # faster has no rise to name, and a genuine fourfold rise across only TWO timed runs still
    # refuses because one interval cannot be told apart from the test simply being that slow.
    # @intent: { entity: "unstable_test_runs.duration_step", action: "withhold the step", behavior: "a window with no rising pair serves withheld no_rise, and a genuine rise across only two timed runs serves withheld too_few_timed_runs", layer: "request" }
    it "withholds the step with no_rise and with too_few_timed_runs" do
      slowing = repository_with_durations([4.3, 4.2, 4.1], repo: second_repository("acme/onset-faster"))
      step = parent(repo: slowing, query: { branch: "main", unstable_test: flipping_test })
             .dig("unstable_test_runs", "duration_step")
      expect(step).to eq("state" => "withheld", "reason" => "no_rise", "from" => nil,
                         "to" => nil, "compare" => nil)

      two = repository_with_durations([1.0, 4.2], repo: second_repository("acme/onset-two-runs"))
      step = parent(repo: two, query: { branch: "main", unstable_test: flipping_test })
             .dig("unstable_test_runs", "duration_step")
      expect(step).to include("state" => "withheld", "reason" => "too_few_timed_runs")
    end

    # THE COST — both readings OFFERED on one window (a trailing failure beside the pace jump),
    # the busiest path the readings have: both presenters run, the reversed window is built and
    # memoized, two compare ranges are composed — and the request still issues exactly one read
    # of the drill-in grain and nothing besides.
    # @intent: { entity: "unstable_test_runs", action: "compute the readings for free", behavior: "the request whose onset and duration step are both offered still issues exactly one read of the drill-in grain and none besides", layer: "request" }
    it "costs no query of its own when both readings are offered" do
      both = repository_with_durations([1.0, 1.1, 4.2, 4.3], outcomes: %w[passed passed failed failed],
                                       repo: second_repository("acme/onset-both-offered"))
      ask = { branch: "main", unstable_test: flipping_test }
      get_repository(repo: both, query: ask)

      served = parent(repo: both, query: ask).dig("unstable_test_runs")
      expect(served["onset"]["state"]).to eq("offered")
      expect(served["duration_step"]["state"]).to eq("offered")

      expect(unstable_test_runs_grain_reads { get_repository(repo: both, query: ask) }.length)
        .to eq(1)
    end
  end

  # AC4. A run that recorded the test and said NOTHING about how it ended is not evidence that it
  # passed. `UnstableTests::Row#changed?` refuses that reading one rung up by comparing against
  # `reported_outcome_count` rather than `recorded_count`, precisely so a client that stopped sending
  # outcomes cannot manufacture a flip — and down here the same silence would manufacture a DATE,
  # which is worse: it would put a green run between two red ones and turn a regression back into
  # flakiness.
  describe "a run that recorded the test and reported no outcome" do
    before { repository_with(["passed", nil, "failed", "passed", "failed"]) }

    # @intent: { entity: "unstable_test_runs", action: "serialize an unreported outcome as null", behavior: "a run that recorded the test but sent no status contributes outcome null rather than a manufactured pass, keeping silent runs from rewriting the story", layer: "request" }
    it "serializes the silent run as a null outcome rather than as a pass" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { it["outcome"] }).to eq(["failed", "passed", "failed", nil, "passed"])
      expect(served.find { it["commit_sha"] == sha_for(1) }).to include("outcome" => nil)
    end

    # The same separation as a COUNT, so a client reading a truncated list can still see how much of
    # the window said nothing — counted over the window, before the cap, rather than off the rows.
    # @intent: { entity: "unstable_test_runs", action: "count unreported outcomes separately", behavior: "the block reports recorded_count, reported_outcome_count and unreported_outcome_count so a client sees how much of the window said nothing", layer: "request" }
    it "counts the silence separately from the reports" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served).to include("recorded_count" => 5, "reported_outcome_count" => 4,
                                "unreported_outcome_count" => 1)
    end
  end

  # A description carried by more than one example in a run is not a key for that run — the state
  # `UnstableTests::Row#shared_description?` names one rung up, where the two rows' differing
  # outcomes are two tests rather than one test that flipped. The drill-in SHOWS them rather than
  # collapsing them: "one row per run" is what the data usually is, not a promise this block makes,
  # and folding two examples into one row would be the block deciding which of them the reader meant.
  describe "a description carried by two examples in the same run" do
    before do
      2.times do |index|
        ingest(repository,
               [example_spec(name: flipping_test, outcome: "passed", line_number: 1),
                example_spec(name: flipping_test, outcome: "failed", line_number: 9),
                example_spec(name: "User signs in", outcome: "passed", line_number: 2,
                             file_path: "spec/models/user_spec.rb")],
               commit_sha: sha_for(index), branch: "main", at: (30 - index).days.ago)
      end
    end

    # @intent: { entity: "unstable_test_runs", action: "keep both rows of a shared description", behavior: "when one run holds two examples under the same description both rows are served in a stable line order instead of being collapsed into one", layer: "request" }
    it "serves both of the run's rows, in a stable order within the run" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { [it["commit_sha"], it["line_number"], it["outcome"]] }).to eq(
        [[sha_for(1), 1, "passed"], [sha_for(1), 9, "failed"],
         [sha_for(0), 1, "passed"], [sha_for(0), 9, "failed"]]
      )
    end

    # And the run count is still the WINDOW's, not the row count — two figures a reader would
    # otherwise have to assume were the same one.
    # @intent: { entity: "unstable_test_runs", action: "separate run count from row count", behavior: "the window run_count stays the count of runs while rows and recorded_count reflect examples, so duplicated descriptions do not inflate the run figure", layer: "request" }
    it "keeps the window's run count distinct from the number of rows" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["run_count"]).to eq(2)
      expect(served["rows"].length).to eq(4)
      expect(served["recorded_count"]).to eq(4)
    end
  end

  # THE SHAPE A POSITIONAL READ GETS WRONG, and the most ordinary one a sequence reader meets: the
  # description is present in SOME runs of the window and absent from others. A test added halfway
  # through the window, renamed into this name, quarantined for a fortnight, or living in a file one
  # shard did not run — every one of those leaves a HOLE in the sequence, and not one of them is an
  # error.
  #
  # The runs that recorded nothing contribute no row, so this list is SHORTER than the window and its
  # indices stop corresponding to `history`'s. With the hole in the MIDDLE — where it moves every row
  # under it, rather than at an end where it only shortens the list — an agent reading the run off
  # the POSITION names the wrong commit, and naming the wrong culprit commit is the one error this
  # drill-in cannot survive. That is what the `test_run_id` and `commit_sha` on every row are for.
  describe "a window the description is absent from some runs of" do
    # A `nil` here means the run did not record the description AT ALL — deliberately absent rather
    # than recorded with a nil outcome, which is a DIFFERENT state asserted separately above: silence
    # about a test that ran is not the same fact as no record that it ran, and this file keeps the
    # two apart everywhere else.
    def ingest_window(outcomes)
      outcomes.each_with_index do |outcome, index|
        specs = [example_spec(name: "User signs in", outcome: "passed", line_number: 2,
                              file_path: "spec/models/user_spec.rb")]
        specs.unshift(example_spec(name: flipping_test, outcome: outcome, line_number: 1)) if outcome
        ingest(repository, specs, commit_sha: sha_for(index), branch: "main",
                                  at: (30 - index).days.ago)
      end
    end

    # Chronologically: passed, ABSENT, failed, failed.
    before { ingest_window(["passed", nil, "failed", "failed"]) }

    # @intent: { entity: "unstable_test_runs", action: "omit rows for absent runs", behavior: "runs that never recorded the description contribute no row, and the surviving rows stay newest-first with no gap-filling", layer: "request" }
    it "contributes no row for the runs that recorded nothing, keeping the rest newest-first" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { [it["commit_sha"], it["outcome"]] }).to eq(
        [[sha_for(3), "failed"], [sha_for(2), "failed"], [sha_for(0), "passed"]]
      )
      expect(served.map { it["commit_sha"] }).not_to include(sha_for(1))
    end

    # `rows.length < run_count`, with both figures served, so the hole is countable rather than
    # merely survivable. And it is NOT a truncation: the cap did not bite, so `recorded_count` agrees
    # with the listed rows and the gap shows up as `run_count > recorded_count` instead.
    # @intent: { entity: "unstable_test_runs", action: "disclose the hole in the counts", behavior: "rows length falls below run_count while recorded_count matches the rows, showing the gap as missing runs rather than as truncation", layer: "request" }
    it "is shorter than the window it was drawn from, and serves both figures" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["rows"].length).to eq(3)
      expect(served["run_count"]).to eq(4)
      expect(served["rows"].length).to be < served["run_count"]
      expect(served["recorded_count"]).to eq(3)
      expect(served["limit"]).to eq(SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
    end

    # The property the docs above now state, pinned: the two lists share a window and a direction but
    # NOT an index, and the run each row belongs to is still recoverable — off its `commit_sha`, off
    # its `test_run_id`, never off its position. The third assertion is the damage itself: at the
    # last index of this list, a positional read answers `sha_for(1)` — the run that never recorded
    # the test — when the row's own run is `sha_for(0)`.
    # @intent: { entity: "unstable_test_runs", action: "keep run identity off the position", behavior: "the shortened list no longer matches history index-for-index, and each row still carries test_run_id and commit_sha so its run stays recoverable", layer: "request" }
    it "no longer lines up index-for-index with history, so the run is read off the commit_sha" do
      body = get_repository(query: { branch: "main", unstable_test: flipping_test })
      served = body.dig("unstable_tests", "unstable_test_runs", "rows")
      history = body["history"].map { it["commit_sha"] }

      expect(served.length).not_to eq(history.length)
      expect(served.last["commit_sha"]).to eq(sha_for(0))
      expect(history[served.length - 1]).to eq(sha_for(1))

      expect(history).to include(*served.map { it["commit_sha"] })
      expect(served.map { it["test_run_id"] }).to eq([run_for(3).id, run_for(2).id, run_for(0).id])
    end
  end

  # AC5. A capped list that does not disclose its cap is read as the whole story — the lie by
  # omission every capped block on this endpoint refuses. And the cap takes the OLD end: a truncated
  # sequence keeps the recent runs, because "it has failed since before this list starts" still names
  # a regression while a list truncated the other way answers "how is it doing lately" with the state
  # of a month ago.
  describe "the cap and the window it was drawn from" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # @intent: { entity: "unstable_test_runs", action: "disclose the cap and keep the recent end", behavior: "a truncated list serves limit, run_count and recorded_count and retains the newest runs so late failures survive the cut", layer: "request" }
    it "discloses its own cap and the window, and keeps the recent end of the sequence" do
      stub_const("SpecObservation::UNSTABLE_TEST_RUNS_LIMIT", 2)

      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["limit"]).to eq(2)
      expect(served["run_count"]).to eq(5)
      # The operand, not the predicate: `recorded_count > rows.length` is the client's comparison to
      # make, on this endpoint's standing rule for every drill-in.
      expect(served["recorded_count"]).to eq(5)
      expect(served["rows"].map { it["commit_sha"] }).to eq([sha_for(4), sha_for(3)])
    end

    # Uncapped, the two figures agree — which is what makes the pair readable as a cap indicator at
    # all rather than as two numbers that are always different.
    # @intent: { entity: "unstable_test_runs", action: "agree when the cap did not bite", behavior: "below the limit the recorded_count equals the served row count and limit restates the constant, making the pair usable as a cap indicator", layer: "request" }
    it "reports the same two counts when the cap did not bite" do
      served = block(query: { branch: "main", unstable_test: flipping_test })

      expect(served["recorded_count"]).to eq(5)
      expect(served["rows"].length).to eq(5)
      expect(served["limit"]).to eq(SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
    end
  end

  # AC2. The two ways this key can be empty, which must not wear the same spelling: "you did not ask"
  # and "the test you asked about has no rows in this window" are different facts, and a client that
  # could not tell them apart would read a stale bookmark as a parameter the server ignores.
  describe "the ways this key can be empty" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # @intent: { entity: "unstable_test_runs", action: "spell an unasked drill-in as null", behavior: "the key is present but null when no unstable_test parameter was sent, distinguishing no ask from an asked-about test with no rows", layer: "request" }
    it "is null — with the key present — when no test was asked for" do
      served = parent(query: { branch: "main" })

      expect(response).to have_http_status(:ok)
      expect(served).to have_key("unstable_test_runs")
      expect(served["unstable_test_runs"]).to be_nil
    end

    # A renamed test is the ORDINARY way to arrive here rather than the exotic one: the project's
    # identity rule is semantic, so a rename starts a new history and every bookmark to the old name
    # goes stale by design. 200, never a 404.
    #
    # The onset and the duration step are the presenters' OWN answers over a sequence with no rows —
    # `nothing_reported` and `too_few_timed_runs` — which keeps the block's key set identical in
    # every state: a client reads `onset` without first asking whether rows came back. Pinned here
    # because this is the state where a `rows.any?` gate (the console's, which renders no line
    # over an empty panel) would have made the keys conditional.
    # @intent: { entity: "unstable_test_runs", action: "answer an unknown test with an empty block", behavior: "a renamed or never-recorded description yields a present block with zero rows, its counts and the asked name, never a 404", layer: "request" }
    it "is a present block with no rows, naming the test, when the window recorded none" do
      served = block(query: { branch: "main", unstable_test: "Invoice finalize locks the line-items" })

      expect(response).to have_http_status(:ok)
      expect(served).to eq(
        "name" => "Invoice finalize locks the line-items", "rows" => [],
        "recorded_count" => 0, "reported_outcome_count" => 0,
        "unreported_outcome_count" => 0, "run_count" => 5,
        "limit" => SpecObservation::UNSTABLE_TEST_RUNS_LIMIT,
        "onset" => { "state" => "withheld", "reason" => "nothing_reported", "last_pass" => nil,
                     "first_fail" => nil, "compare" => nil },
        "duration_step" => { "state" => "withheld", "reason" => "too_few_timed_runs", "from" => nil,
                             "to" => nil, "compare" => nil }
      )
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent.
    # @intent: { entity: "unstable_test_runs", action: "distinguish the two empty answers", behavior: "the no-ask reading is null while the asked-but-empty reading is a present block naming the test, so a client needs no memory of its request", layer: "request" }
    it "spells the two differently, so a client can tell which one it got" do
      expect(block(query: { branch: "main" })).to be_nil
      expect(block(query: { branch: "main", unstable_test: "no such test" })).not_to be_nil
      expect(block(query: { branch: "main", unstable_test: "no such test" })["name"])
        .to eq("no such test")
    end

    # The drill-in is gated behind the same `?branch=` the block it sits in is gated behind, and it
    # has to be: an unfiltered window is interleaved across branches, so a sequence read down it
    # would be the outcomes of DIFFERENT CODE in run order — the one reading of these rows that is
    # worse than not serving them.
    # @intent: { entity: "unstable_test_runs", action: "gate on the branch parameter", behavior: "without a branch narrowing the whole unstable_tests block is null, preventing an interleaved cross-branch sequence read", layer: "request" }
    it "serves no block at all when the window was not narrowed to a branch" do
      body = get_repository(query: { unstable_test: flipping_test })

      expect(response).to have_http_status(:ok)
      expect(body).to have_key("unstable_tests")
      expect(body["unstable_tests"]).to be_nil
    end
  end

  # AC6, the half that protects everything already shipped: adding a key must not move one. The
  # ranking's own keys are compared VALUE FOR VALUE between an unfiltered and an asked request, so a
  # drill-in that reached back into the block it sits in — re-querying the window, re-sorting the
  # rows, spending the candidate cap — goes red here rather than in a client.
  describe "what the ask does to the block it sits in" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # @intent: { entity: "unstable_tests", action: "leave the ranking byte-identical", behavior: "adding the unstable_test ask changes no key or value of the parent block beyond the new drill-in, so prior readers are unaffected", layer: "request" }
    it "leaves every existing unstable_tests key byte-identical" do
      without = parent(query: { branch: "main" })
      with = parent(query: { branch: "main", unstable_test: flipping_test })

      expect(with.except("unstable_test_runs")).to eq(without.except("unstable_test_runs"))
      expect(without.keys).to eq(with.keys)
      expect(with["unstable_test_runs"]).not_to be_nil
    end

    # And the window block beside it, which is where a second fetch of "the last thirty runs" would
    # show up first.
    # @intent: { entity: "unstable_tests_window", action: "leave the window block untouched", behavior: "the drill-in reuses the window the block already loaded and does not re-query or re-sort the window served beside it", layer: "request" }
    it "leaves the window block it is read against untouched" do
      without = get_repository(query: { branch: "main" })["unstable_tests_window"]
      with = get_repository(query: { branch: "main", unstable_test: flipping_test })["unstable_tests_window"]

      expect(with).to eq(without)
    end
  end

  # AC6, the cost half. The gate is the ASK and it is decided before any read is issued, so a client
  # that never sends the parameter pays nothing for the key's existence — the rule all three sibling
  # drill-ins state and the property that lets a fifth read hang off a block advertised as four.
  describe "what the drill-in costs the endpoint" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # @intent: { entity: "unstable_test_runs", action: "cost one query only when asked", behavior: "the parameter gates exactly one extra query over baseline, the empty answer costs the same one, and a malformed shape costs none", layer: "request" }
    it "adds exactly one query when asked, and none when not" do
      # Warmed first, on the precedent the sibling cost blocks set: the very first request of an
      # example pays for state a second one does not — an API key's first use is recorded — and a
      # baseline taken over it would be measuring the warm-up rather than the block.
      get_repository(query: { branch: "main" })
      baseline = count_queries { get_repository(query: { branch: "main" }) }

      expect(count_queries { get_repository(query: { branch: "main", unstable_test: flipping_test }) })
        .to eq(baseline + 1)
      # The empty answer costs the same one: the read is what DISCOVERS that the window recorded
      # nothing under the description, so there is no cheaper way to ask.
      expect(count_queries { get_repository(query: { branch: "main", unstable_test: "no such test" }) })
        .to eq(baseline + 1)
      # A malformed shape is no ask, which means it is also no query — the guard sits in front of the
      # read rather than inside it.
      expect(count_queries { get_repository(query: { branch: "main", unstable_test: [flipping_test] }) })
        .to eq(baseline)
    end

    # The same bound CLASSIFIED rather than counted, so "one more query" cannot be satisfied by a
    # different grain reading twice while this one reads none — see
    # spec/support/observation_grain_reads.rb, which is also where the argument for matching every
    # grain positively is made.
    # @intent: { entity: "unstable_test_runs", action: "issue the sequence read only on a valid ask", behavior: "the grain-classified read fires once for a sent description, never without a branch, and not at all for a non-ask shape", layer: "request" }
    it "issues the sequence read only when the parameter was sent" do
      expect(unstable_test_runs_grain_reads { get_repository(query: { branch: "main" }) }).to be_empty
      expect(unstable_test_runs_grain_reads do
        get_repository(query: { branch: "main", unstable_test: flipping_test })
      end.length).to eq(1)
      # No branch, no block, and therefore no read — the gate in front of the gate.
      expect(unstable_test_runs_grain_reads do
        get_repository(query: { unstable_test: flipping_test })
      end).to be_empty
    end

    # The flakiness grain is unmoved by the ask, which is the read-side half of the byte-identical
    # assertion above: the drill-in reuses the window the block already loaded rather than asking for
    # it again.
    # @intent: { entity: "unstable_tests ranking", action: "leave the ranking reads unchanged", behavior: "the flakiness grain issues the same number of reads with the ask as without it, showing the drill-in borrowed the loaded window", layer: "request" }
    it "leaves the ranking's own four reads exactly as they were" do
      without = flakiness_grain_reads { get_repository(query: { branch: "main" }) }
      with = flakiness_grain_reads do
        get_repository(query: { branch: "main", unstable_test: flipping_test })
      end

      expect(with.length).to eq(without.length)
    end
  end

  # AC: the shapes a query string can legally parse into that are NOT a description, pinned once for
  # every surface in `spec/support/shared_examples/malformed_unstable_test_param.rb`. This one
  # reaches `where(name: …)` on a plain text column, where an Array does not raise at all: it becomes
  # an `IN` list, and two tests' sequences interleaved into one run-ordered list look exactly like
  # the alternation this block exists to show.
  describe "an unstable-test parameter that is not a description" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # The NO-ASK answer specifically, and not merely a 200 — the shared example's own comment
    # requires it, because a guard that swallowed every value would answer 200 on all three shapes
    # too.
    def expect_unstable_test_param_treated_as_no_ask(query)
      expect(block(query: query.merge(branch: "main"))).to be_nil
      expect(response).to have_http_status(:ok)
    end

    it_behaves_like "a surface that treats a malformed unstable-test parameter as no ask"

    # THE positive path, beside the group, which is what separates "the guard read the parameter"
    # from "the endpoint ignores this parameter entirely".
    # @intent: { entity: "unstable_test_runs", action: "honour a well-formed description", behavior: "a genuine string parameter serves the test run rows, proving the guard reads the value rather than ignoring the parameter outright", layer: "request" }
    it "honours an unstable_test that IS a description" do
      expect(rows(query: { branch: "main", unstable_test: flipping_test }).length).to eq(5)
    end

    # The silent wrong answer the guard exists for, made visible: an Array would merge a test that
    # never varied into the sequence of one that did, and the merged list is a picture of flakiness
    # nothing in the suite is doing.
    # @intent: { entity: "unstable_test_runs", action: "refuse an array parameter as no ask", behavior: "an Array value does not become an IN list merging two tests sequences into one; the guard drops it and serves null", layer: "request" }
    it "does not merge two tests' sequences into one when handed an array" do
      served = block(query: { branch: "main", unstable_test: [flipping_test, "User signs in"] })

      expect(served).to be_nil
    end

    # An empty ask is no ask, not a comparison against the empty string. `spec_observations.name` is
    # NULLABLE — which is why the ranking above counts unnamed rows separately and excludes them from
    # the matching — so without `.presence` an empty ask would become `WHERE name = ''`, a query for
    # a description no row can carry and therefore a block guaranteed to be empty.
    # @intent: { entity: "unstable_test_runs", action: "treat an empty parameter as no ask", behavior: "an empty unstable_test string is stripped to no ask rather than compared against the empty string or a blank description", layer: "request" }
    it "treats an empty unstable_test as no ask" do
      expect(block(query: { branch: "main", unstable_test: "" })).to be_nil
    end
  end
end
