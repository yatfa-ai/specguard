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

    # AC1 at the row grain. Run identity BESIDE the test's own fields, because either half alone is
    # useless: an outcome with no commit cannot be attributed and a commit with no outcome is the
    # `history` row that already exists.
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
    it "shares the window and its ordering with the history rows it is meant to be joined against" do
      body = get_repository(query: { branch: "main", unstable_test: flipping_test })
      shas = body.dig("unstable_tests", "unstable_test_runs", "rows").map { it["commit_sha"] }

      expect(shas).to eq(body["history"].map { it["commit_sha"] })
    end

    # AC3, said as the sentence the reader acts on: the run a failure began at is reachable by
    # walking this list from its old end, with no arithmetic over anything else in the body.
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

    it "distinguishes a regression from flakiness" do
      regressed = repository_with(%w[passed passed passed passed passed passed failed failed failed failed],
                                  repo: second_repository("acme/regressed"))
      flaky = repository_with(%w[passed failed passed failed passed failed passed failed passed passed],
                              repo: second_repository("acme/flaky"))

      query = { branch: "main", unstable_test: flipping_test }
      regressed_block = parent(repo: regressed, query: query)
      flaky_block = parent(repo: flaky, query: query)

      # The ranking is blind to the difference, and that is not a defect in it: a `COUNT` of failures
      # over a window is the same integer whichever runs they landed in.
      expect(regressed_block["rows"]).to eq(flaky_block["rows"])
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

  # AC4. A run that recorded the test and said NOTHING about how it ended is not evidence that it
  # passed. `UnstableTests::Row#changed?` refuses that reading one rung up by comparing against
  # `reported_outcome_count` rather than `recorded_count`, precisely so a client that stopped sending
  # outcomes cannot manufacture a flip — and down here the same silence would manufacture a DATE,
  # which is worse: it would put a green run between two red ones and turn a regression back into
  # flakiness.
  describe "a run that recorded the test and reported no outcome" do
    before { repository_with(["passed", nil, "failed", "passed", "failed"]) }

    it "serializes the silent run as a null outcome rather than as a pass" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { it["outcome"] }).to eq(["failed", "passed", "failed", nil, "passed"])
      expect(served.find { it["commit_sha"] == sha_for(1) }).to include("outcome" => nil)
    end

    # The same separation as a COUNT, so a client reading a truncated list can still see how much of
    # the window said nothing — counted over the window, before the cap, rather than off the rows.
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

    it "serves both of the run's rows, in a stable order within the run" do
      served = rows(query: { branch: "main", unstable_test: flipping_test })

      expect(served.map { [it["commit_sha"], it["line_number"], it["outcome"]] }).to eq(
        [[sha_for(1), 1, "passed"], [sha_for(1), 9, "failed"],
         [sha_for(0), 1, "passed"], [sha_for(0), 9, "failed"]]
      )
    end

    # And the run count is still the WINDOW's, not the row count — two figures a reader would
    # otherwise have to assume were the same one.
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

    it "is null — with the key present — when no test was asked for" do
      served = parent(query: { branch: "main" })

      expect(response).to have_http_status(:ok)
      expect(served).to have_key("unstable_test_runs")
      expect(served["unstable_test_runs"]).to be_nil
    end

    # A renamed test is the ORDINARY way to arrive here rather than the exotic one: the project's
    # identity rule is semantic, so a rename starts a new history and every bookmark to the old name
    # goes stale by design. 200, never a 404.
    it "is a present block with no rows, naming the test, when the window recorded none" do
      served = block(query: { branch: "main", unstable_test: "Invoice finalize locks the line-items" })

      expect(response).to have_http_status(:ok)
      expect(served).to eq("name" => "Invoice finalize locks the line-items", "rows" => [],
                           "recorded_count" => 0, "reported_outcome_count" => 0,
                           "unreported_outcome_count" => 0, "run_count" => 5,
                           "limit" => SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
    end

    # The pair, side by side, which is the assertion neither example above can make on its own: a
    # client can tell the two apart WITHOUT knowing what it sent.
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

    it "leaves every existing unstable_tests key byte-identical" do
      without = parent(query: { branch: "main" })
      with = parent(query: { branch: "main", unstable_test: flipping_test })

      expect(with.except("unstable_test_runs")).to eq(without.except("unstable_test_runs"))
      expect(without.keys).to eq(with.keys)
      expect(with["unstable_test_runs"]).not_to be_nil
    end

    # And the window block beside it, which is where a second fetch of "the last thirty runs" would
    # show up first.
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
    it "honours an unstable_test that IS a description" do
      expect(rows(query: { branch: "main", unstable_test: flipping_test }).length).to eq(5)
    end

    # The silent wrong answer the guard exists for, made visible: an Array would merge a test that
    # never varied into the sequence of one that did, and the merged list is a picture of flakiness
    # nothing in the suite is doing.
    it "does not merge two tests' sequences into one when handed an array" do
      served = block(query: { branch: "main", unstable_test: [flipping_test, "User signs in"] })

      expect(served).to be_nil
    end

    # An empty ask is no ask, not a comparison against the empty string. `spec_observations.name` is
    # NULLABLE — which is why the ranking above counts unnamed rows separately and excludes them from
    # the matching — so without `.presence` an empty ask would become `WHERE name = ''`, a query for
    # a description no row can carry and therefore a block guaranteed to be empty.
    it "treats an empty unstable_test as no ask" do
      expect(block(query: { branch: "main", unstable_test: "" })).to be_nil
    end
  end
end
