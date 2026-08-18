# frozen_string_literal: true

require "rails_helper"

# The `unstable_tests` block on `GET /api/v1/repository` — the agent-readable half of the "Tests
# whose outcome changed" panel `repositories#show` has rendered since SPGD-282, and the roadmap's
# fourth axis ("a human sees … where it is flaky … an agent pulls the same facts"), which is the
# only one of the four the endpoint had never been given.
#
# Its own file, beside `repository_latest_run_spec.rb`, on the precedent the human side already
# set with `repository_unstable_tests_spec.rb`: every example here needs the same multi-RUN
# fixture, while every block in that file is a fact about ONE run and builds a one-run repository
# to say so. The grain is the difference — this is the endpoint's first cross-run test-level key —
# and it is what makes the fixtures unshareable rather than merely inconvenient to share.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule `repository_unstable_tests_spec.rb` states for itself and for the
# same reason: every state this block turns on is a state the RECORDER produces from what a real
# client sends. A nil `outcome` is `result&.status` coming back nil, a nil `name` is a producer
# that sends no description, and two examples sharing a description in one run is an ordinary
# table-driven loop. A hand-built fixture would be asserting against shapes nothing in production
# writes.
RSpec.describe "GET /api/v1/repository — unstable_tests", type: :request do
  # Signed in as well as keyed, because one example here reads the HTML panel and the JSON block
  # off the same data and compares them field for field. The owner is the same user in both, so
  # the two surfaces cannot be looking at two repositories.
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(repo: repository, key: nil, query: {})
    token = (key || repo.api_keys.create!).raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  # The two keys under test, always read together: the window block explains the rows block, and
  # reading either alone is how a `null` gets asserted without its reason.
  def blocks(**)
    body = get_repository(**)
    [body["unstable_tests_window"], body["unstable_tests"]]
  end

  # One ingested CI run, through the producer. `specs` are the wire hashes a client POSTs; the
  # recorder reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
  # Every run is stamped back in time so the window orders them the way CI produced them rather
  # than by whatever order the fixture inserted them in.
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

  # One example on the wire. `outcome:` and `name:` are passed at every call site, nils included —
  # an unreported outcome and an unnamed example are both states this file turns on, and the shared
  # builder substitutes a default for a nil `name:`, so both are merged in rather than passed
  # through.
  def example_spec(name:, outcome:, line_number: 1, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: 0.1)
      .merge({ name: name, outcome: outcome }.merge(attrs))
  end

  FLIPPING_TEST = "Invoice finalize locks the line items"

  # A repository whose window holds one run per entry of `outcomes_per_run`, each run reporting the
  # given outcome for the named test plus a second test that reports the same way — so a window of
  # nils is a window that reported NOTHING, which is the state half this file turns on, and a
  # window of words is comparable by construction. Lifted verbatim in shape from
  # `repository_unstable_tests_spec.rb`, on the ticket's own instruction to reuse the fixtures that
  # are already known to produce these states rather than re-derive them.
  def repository_with(outcomes_per_run, name: FLIPPING_TEST, branch: "main", repo: repository, **attrs)
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

  def row_named(block, name) = block["rows"].find { |row| row["name"] == name }

  describe "a branch-scoped window holding a test that failed in some runs and not others" do
    before { repository_with(%w[passed failed passed passed failed]) }

    # Criterion 1, at the row grain. Every counter the panel words as a sentence, served as the
    # integers those sentences are built from — and the outcome words echoed rather than folded
    # into a verdict.
    it "names the test and serves every figure the panel words, as counts" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].map { |row| row["name"] }).to eq([FLIPPING_TEST])
      expect(row_named(block, FLIPPING_TEST)).to eq(
        "name" => FLIPPING_TEST,
        "recorded_count" => 5,
        "run_count" => 5,
        "reported_outcome_count" => 5,
        "unreported_outcome_count" => 0,
        "failed_count" => 2,
        "failed_run_count" => 2,
        "outcome_words" => %w[failed passed],
        "files_seen" => ["spec/models/invoice_spec.rb"],
        "multi_file" => false,
        "shared_description" => false
      )
    end

    # The test that never varied is not on the list — the block names what CHANGED, and a stable
    # test served beside a flaky one is the signal buried in the population it was drawn from.
    it "leaves out the test that reported the same outcome in every run" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].map { |row| row["name"] }).not_to include("User signs in")
    end

    # The body is the whole feature here — there is no prose copy for an agent to read the shape
    # off — so both blocks are pinned EXACTLY rather than key by key, on the rule the sibling
    # file's top-level contract states: a key added without a line in this list fails here, and a
    # listed key quietly dropped fails here too.
    it "serves exactly the keys this contract pins, on the window and on the rows block" do
      window, block = blocks(query: { branch: "main" })

      expect(window.keys)
        .to contain_exactly("order", "tie_break_served", "branch_scope", "branch", "grouped")
      expect(block.keys).to contain_exactly(
        "rows", "shared_description_rows", "run_count", "runs_with_rows",
        "runs_reporting_outcomes", "recorded", "comparable", "candidate_count", "examined_count",
        "truncated", "unexamined_count", "unnamed_count", "limit",
        # The drill-in below this block, nested inside it exactly as the three sibling drill-ins are
        # nested inside the rankings they open. Present on EVERY request and `null` unless
        # `?unstable_test=` named a test — the key-always-present rule this endpoint states in full
        # on `serialized_unstable_tests_window`, so a client tests one thing rather than
        # distinguishing an absent key from a null one. Its own contract is
        # `spec/requests/api/v1/repository_unstable_test_runs_spec.rb`; what is pinned HERE is that
        # it did not displace or rename anything above it.
        "unstable_test_runs"
      )
    end

    # The other half of that pin, and the half a `contain_exactly` cannot make: the twelve keys
    # above are the SAME VALUES whether or not the drill-in was asked for. A drill-in that reached
    # back into the block it sits in — re-querying the window, re-sorting the rows, spending the
    # candidate cap — would go red here rather than in a client.
    it "serves those keys identically whether or not the drill-in was asked for" do
      _window, asked = blocks(query: { branch: "main", unstable_test: FLIPPING_TEST })
      _window, unasked = blocks(query: { branch: "main" })

      expect(asked.except("unstable_test_runs")).to eq(unasked.except("unstable_test_runs"))
      expect(unasked["unstable_test_runs"]).to be_nil
      expect(asked["unstable_test_runs"]).not_to be_nil
    end

    it "states the window it was drawn over, as counts and booleans and no prose" do
      window, block = blocks(query: { branch: "main" })

      expect(window).to eq(
        "order" => "failed_run_count_desc,run_count_desc,name_asc",
        # TRUE here, and it is the only `true` on this endpoint. The three sort keys are
        # `failed_run_count`, `run_count` and `name`, and every one of them is served on the row —
        # unlike `history`, whose tie-break is an ingest sequence no row carries.
        "tie_break_served" => true,
        "branch_scope" => "single_branch",
        "branch" => "main",
        "grouped" => true
      )
      expect(block).to include(
        "run_count" => 5, "runs_with_rows" => 5, "runs_reporting_outcomes" => 5,
        "recorded" => true, "comparable" => true,
        "candidate_count" => 1, "examined_count" => 1, "truncated" => false,
        "unexamined_count" => 0, "unnamed_count" => 0,
        "limit" => SpecObservation::UNSTABLE_CANDIDATE_LIMIT
      )
      # No value anywhere in either block is a sentence. The twelve `unstable_tests_*` helpers that
      # word this same coverage for the panel produce strings with spaces in them ("3 of the last
      # 30 runs on main reported outcomes"); the only strings here are a test's own description,
      # the outcome words CI sent, file paths, and the two fixed vocabularies above.
      expect(block.values_at("run_count", "runs_with_rows", "runs_reporting_outcomes",
                             "candidate_count", "examined_count", "unexamined_count",
                             "unnamed_count", "limit")).to all(be_an(Integer))
      expect(block.values_at("recorded", "comparable", "truncated")).to all(be_in([true, false]))
    end

    # The order is the presenter's own and is NOT re-sorted here. Asserted on a fixture where the
    # ranking and the alphabet disagree, because any single-row fixture — and any fixture whose
    # rows happen to be alphabetical — passes under a serializer that sorts by name.
    it "serves the presenter's order, most-failing first, without re-sorting it" do
      3.times do |index|
        ingest(repository,
               [example_spec(name: "Aardvark waits for the queue", outcome: index.zero? ? "failed" : "passed",
                             line_number: 7, file_path: "spec/models/queue_spec.rb")],
               commit_sha: "extra#{format("%07d", index)}", at: (10 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })
      names = block["rows"].map { |row| row["name"] }

      # `Invoice…` failed in 2 runs, `Aardvark…` in 1, so most-failing-first puts the alphabetically
      # LATER name first — which a name sort could not produce.
      expect(names).to eq([FLIPPING_TEST, "Aardvark waits for the queue"])
      expect(names).not_to eq(names.sort)
      # And the order a client would compute from the fields served is the order it received, which
      # is what `tie_break_served: true` claims.
      expect(block["rows"].sort_by { |row| [-row["failed_run_count"], -row["run_count"], row["name"]] })
        .to eq(block["rows"])
    end
  end

  # Criterion 1, stated the way the ticket words it: the figures must equal, FIELD FOR FIELD, what
  # `repositories#show` prints for that branch on the same data. Read off the rendered page rather
  # than off a second call to `UnstableTests`, which would compare the endpoint against itself.
  describe "against what repositories#show prints for the same branch" do
    def panel_rows
      panel = Capybara.string(response.body).find("#unstable-tests")
      panel.all("tbody tr").map do |row|
        name_cell, seen_cell, failed_cell, outcome_cell = row.all("td")
        files = name_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }.first
        name = name_cell.text.gsub(/\s+/, " ").strip
        name = name.delete_suffix(files).strip if files

        { "name" => name, "seen" => seen_cell.text.strip, "failed" => failed_cell.text.strip,
          "outcome_words" => outcome_cell.all("span span").map { |badge| badge.text.strip } }
      end
    end

    it "names the same tests, with the same fractions and the same words" do
      repository_with(%w[passed failed passed passed failed])
      # A second flaky description, so the comparison below is over a LIST rather than over a
      # single row — the shape where an off-by-one in either surface's ordering or denominators
      # actually shows.
      %w[failed passed].each_with_index do |outcome, index|
        ingest(repository,
               [example_spec(name: "Ledger posts twice", outcome: outcome, line_number: 4,
                             file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "ledger00000#{index}", at: (2 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })
      get repository_path(repository, branch: "main")

      # The page renders the two fractions the helper builds; the block serves the operands. Both
      # readings are assembled here so a drift in either surface is a red example rather than two
      # numbers nobody compared.
      served = block["rows"].map do |row|
        { "name" => row["name"],
          "seen" => "#{row["run_count"]} of #{block["run_count"]}",
          "failed" => "#{row["failed_run_count"]} of #{row["run_count"]}",
          "outcome_words" => row["outcome_words"] }
      end

      expect(panel_rows).to eq(served)
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(served.length).to eq(2)
    end
  end

  # Criterion 3 — the one real design decision, and the one this block would be a false-positive
  # generator without. `UnstableTests`' own rule: outcomes compared across branches are outcomes of
  # different code.
  describe "an unfiltered window whose newest runs interleave two branches" do
    # Alternating `main` and `feature/x`, newest first, with ONE description that passes on every
    # `main` run and fails on every `feature/x` run. Grouped over the interleaved window that
    # description has both a failure and a pass and is therefore a flip; grouped per branch it is
    # uniform on each side and is not. So this fixture is a falsifier rather than a smoke test: an
    # endpoint that grouped the unfiltered window serves a row here, and only one that refuses does
    # not.
    def interleaved_repository
      6.times do |index|
        branch = index.even? ? "main" : "feature/x"
        ingest(repository,
               [example_spec(name: FLIPPING_TEST, outcome: index.even? ? "passed" : "failed")],
               commit_sha: "mixed#{format("%07d", index)}", branch: branch,
               at: (30 - index).days.ago)
      end
      repository
    end

    it "serves null rows and a window that says why, rather than an empty list" do
      interleaved_repository

      window, block = blocks

      expect(block).to be_nil
      expect(window).to eq(
        "order" => "failed_run_count_desc,run_count_desc,name_asc",
        "tie_break_served" => true,
        "branch_scope" => "all_branches",
        "branch" => nil,
        "grouped" => false
      )
      # The key is PRESENT and null — never absent — so a client tests one thing rather than
      # distinguishing an absent key from a null one.
      expect(get_repository).to have_key("unstable_tests")
    end

    # The refusal, made non-vacuous. The same window under `?branch=` DOES reach the comparison and
    # DOES report the branch honestly, so the null above is a decision about scope rather than a
    # fixture with nothing in it.
    it "compares the same window once a branch is named, and finds no flip on either branch" do
      interleaved_repository

      _main_window, main_block = blocks(query: { branch: "main" })
      feature_window, feature_block = blocks(query: { branch: "feature/x" })

      expect(main_block["comparable"]).to be(true)
      expect(main_block["run_count"]).to eq(3)
      # Uniform on this branch: three passes, so nothing failed and nothing is a candidate.
      expect(main_block["rows"]).to be_empty
      expect(main_block["candidate_count"]).to eq(0)

      expect(feature_window["branch"]).to eq("feature/x")
      expect(feature_block["comparable"]).to be(true)
      # Uniform on that branch too — it failed in all three — so it is broken there, not unstable.
      expect(feature_block["rows"]).to be_empty
      expect(feature_block["candidate_count"]).to eq(1)
    end

    # And the row the cross-branch grouping WOULD have manufactured is nameable, so the two
    # examples above are not both passing for want of any flip anywhere in the data.
    it "would have produced a flip had the interleaved window been grouped" do
      interleaved_repository
      runs = repository.recent_test_runs(limit: 30).to_a

      grouped = UnstableTests.for(repository, runs, branch: nil)

      expect(grouped.rows.map(&:name)).to eq([FLIPPING_TEST])
      expect(grouped.rows.first.outcome_words).to eq(%w[failed passed])
    end
  end

  # Criterion 4 — the Vacuous Green gate. `outcome` is nullable and nothing validates it, so a
  # window whose client sends none produces exactly the empty list a perfectly stable window does.
  describe "a branch-scoped window that cannot be compared" do
    it "serves the flag beside the empty list, over a window that reported nothing at all" do
      repository_with([nil, nil, nil])

      window, block = blocks(query: { branch: "main" })

      expect(window["grouped"]).to be(true)
      expect(block["comparable"]).to be(false)
      expect(block["rows"]).to eq([])
      expect(block["shared_description_rows"]).to eq([])
      # The window HAS per-example rows — it simply said nothing about how they ended. The two
      # facts are separate and both are served, because only the first distinguishes "nobody told
      # us" from "this repository has no per-example grain at all".
      expect(block["recorded"]).to be(true)
      expect(block["runs_with_rows"]).to eq(3)
      expect(block["runs_reporting_outcomes"]).to eq(0)
      # The OUTCOME counts behind the gate are real zeros of a population nothing was read from —
      # served, so a client cannot mistake the silence for an examined-and-clean window.
      expect(block).to include("candidate_count" => 0, "examined_count" => 0,
                               "truncated" => false, "unexamined_count" => 0)
      # `unnamed_count` is NOT one of them. It counts ROWS with no outcome predicate anywhere in
      # it, so its population was never counted here rather than never read from — null, because a
      # zero would be an exclusion figure nothing measured. This fixture has no unnamed rows, so
      # this line alone cannot tell a fabricated zero from a true one; the example below can.
      expect(block).to include("unnamed_count" => nil)
    end

    # THE example for `unnamed_count`, and the only one in this file that can fail if the gate
    # fabricates the zero: the window holds unnamed rows and reported no outcome over any of them,
    # so `0` and `null` are two different claims about it rather than the same number twice.
    it "declines to count the exclusion it never counted, over a window that holds unnamed rows" do
      3.times do |index|
        ingest(repository,
               [example_spec(name: FLIPPING_TEST, outcome: nil),
                example_spec(name: nil, outcome: nil, line_number: 9,
                             file_path: "spec/models/ledger_spec.rb"),
                example_spec(name: nil, outcome: nil, line_number: 14,
                             file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })

      # Six unnamed rows are really there — the same window served as comparable would count them.
      expect(SpecObservation.where(repository_id: repository.id, name: nil).count).to eq(6)
      expect(block["comparable"]).to be(false)
      expect(block["runs_reporting_outcomes"]).to eq(0)
      # And the key states absence rather than reporting six real exclusions as none. Asserted
      # through `include` rather than on the fetched value, so this pins the key PRESENT-and-null:
      # a payload that dropped the key entirely would satisfy `be_nil` and is a different bug.
      expect(block).to include("unnamed_count" => nil)
      # The outcome counts beside it are untouched by this: their zeros are true here.
      expect(block).to include("candidate_count" => 0, "examined_count" => 0,
                               "truncated" => false, "unexamined_count" => 0)
    end

    # The gate is false in two states, not one, and the second is not silence: the window reported,
    # and holds exactly one run to have reported it. One run's outcome cannot have changed from
    # anything, which is arithmetic rather than a nullability detail.
    it "serves it again where exactly one run reported" do
      repository_with([nil, "failed", nil])

      _window, block = blocks(query: { branch: "main" })

      expect(block["comparable"]).to be(false)
      expect(block["runs_reporting_outcomes"]).to eq(1)
      expect(block["rows"]).to eq([])
    end

    # The falsifier for both examples above: a window that reported and holds two such runs serves
    # `comparable: true` with the same empty list. If the flag did not move, the two examples above
    # would be asserting a constant.
    it "flips the flag to true, with the same empty list, once two runs report" do
      repository_with(%w[passed passed])

      _window, block = blocks(query: { branch: "main" })

      expect(block["comparable"]).to be(true)
      expect(block["rows"]).to eq([])
    end

    # A window with no per-example rows at all is a third state again — a repository whose CI has
    # never sent per-example detail has no cross-run test history to discuss, and `recorded` is
    # what says so rather than a `comparable` that would read as "nobody told us".
    it "serves recorded false for a window that recorded no examples" do
      2.times do |index|
        create_test_run(repository: repository, commit_sha: "bare#{format("%08d", index)}",
                        branch: "main", total_specs_count: 10, created_at: (10 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })

      expect(block["recorded"]).to be(false)
      expect(block["runs_with_rows"]).to eq(0)
      expect(block["comparable"]).to be(false)
      expect(block["rows"]).to eq([])
      # The window is NOT empty — two runs are in it — so `recorded: false` is a fact about the
      # grain those runs carry rather than about how many rows the window selected. The empty-window
      # state below is the one that would otherwise be indistinguishable.
      expect(block["run_count"]).to eq(2)
    end

    # An unknown `?branch=` is the fourth state, and the one where `grouped: true` says the least:
    # the window selects zero runs, so the presenter groups over an empty set. It is served as a
    # populated block of honest zeroes rather than as the `null` an unfiltered request gets, because
    # the two mean different things — "we refused to compare across branches" and "we compared the
    # branch you named, which has no runs" — and `serialized_history` makes exactly this argument
    # for `history: []` two blocks up: a client that asked for `main` and could not tell those apart
    # would have nothing in the body to detect the difference with.
    it "groups over an empty window for a branch with no runs, and reads nothing to do it" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)

      window, block = blocks(key: api_key, query: { branch: "does-not-exist" })

      expect(window).to include("branch_scope" => "single_branch", "branch" => "does-not-exist",
                                "grouped" => true)
      expect(block).to include("run_count" => 0, "runs_with_rows" => 0,
                               "runs_reporting_outcomes" => 0, "recorded" => false,
                               "comparable" => false, "rows" => [], "shared_description_rows" => [])
      # Zero runs is zero run ids, and every one of the four reads returns early on an empty window
      # rather than issuing a statement against no rows.
      expect(flakiness_grain_reads { get_repository(key: api_key, query: { branch: "does-not-exist" }) })
        .to be_empty
      # And the same request really did serve the block — `null` here would be the unfiltered
      # answer given to a filtered ask.
      expect(get_repository(key: api_key, query: { branch: "does-not-exist" })["unstable_tests"])
        .not_to be_nil
    end
  end

  # Criterion 5 — a description carried by more than one example in a single run is not a key for
  # that run, so its `failed` and its `passed` are two tests rather than one that flipped.
  describe "a description carried by more than one example in a single run" do
    before do
      3.times do |index|
        ingest(repository,
               [example_spec(name: "Order total sums the lines", outcome: "failed", line_number: 1),
                example_spec(name: "Order total sums the lines", outcome: "passed", line_number: 2),
                example_spec(name: "User signs in", outcome: "passed", line_number: 3,
                             file_path: "spec/models/user_spec.rb")],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end
    end

    it "serves it as its own list and never among the flaky rows" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"]).to eq([])
      expect(block["shared_description_rows"].map { |row| row["name"] })
        .to eq(["Order total sums the lines"])
      # The counts are what say WHY the rule could not rule on it: six rows across three runs, so
      # the description was carried by two examples per run and is not a key for any of them.
      expect(block["shared_description_rows"].first)
        .to include("recorded_count" => 6, "run_count" => 3, "shared_description" => true)
    end

    # The flag rides on every row of both lists, so a client can read a row's classification off
    # the row rather than off the list it arrived in — the rule `serialized_history_row`'s per-row
    # `branch` follows. Asserted with a window that populates BOTH lists, which is the only shape
    # where a serializer hard-coding the flag per list would be indistinguishable from one reading
    # the row.
    it "carries the flag on rows of both lists, on a window that holds each" do
      repository_with(%w[passed failed passed])

      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].map { |row| row["name"] }).to eq([FLIPPING_TEST])
      expect(block["rows"]).to all(include("shared_description" => false))
      expect(block["shared_description_rows"].map { |row| row["name"] })
        .to eq(["Order total sums the lines"])
      expect(block["shared_description_rows"]).to all(include("shared_description" => true))
    end
  end

  # The candidate cap is a catastrophe valve, and a cap that does not disclose itself turns "we
  # looked at everything" and "we looked at the first two hundred" into the same block.
  describe "a window in which more descriptions failed than the block examines" do
    # Two runs, each reporting a failure for `limit + 2` distinct descriptions, of which exactly one
    # ALSO passes in the second run. The fewest-failures-first ordering keeps that one — the
    # property that ordering exists for. Lifted from the human-side spec rather than re-derived.
    def truncated_window(limit)
      2.times do |run_index|
        specs = (0..(limit + 1)).map do |i|
          outcome = (i.zero? && run_index == 1) ? "passed" : "failed"
          example_spec(name: "candidate #{format("%04d", i)}", outcome: outcome, line_number: i + 1)
        end
        ingest(repository, specs, commit_sha: "run#{format("%010d", run_index)}",
                                  at: (30 - run_index).days.ago)
      end
      repository
    end

    it "discloses the cap, both operands of it, and the bound that produced it" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)
      truncated_window(5)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include(
        "candidate_count" => 7, "examined_count" => 5, "truncated" => true,
        "unexamined_count" => 2, "limit" => 5
      )
      # The boolean is derivable from the two operands beside it, which is the point: the block
      # ships the operands as well as the comparison, so a client can check rather than take it.
      expect(block["candidate_count"] - block["examined_count"]).to eq(block["unexamined_count"])
      # And the kept end is the end a change could still be found in.
      expect(block["rows"].map { |row| row["name"] }).to eq(["candidate 0000"])
    end

    # The falsifier: the same window under a cap it does not reach serves `truncated: false` and a
    # zero remainder. Without it the example above pins a pair of constants.
    it "serves the cap as untripped where the window stayed under it" do
      truncated_window(5)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include(
        "candidate_count" => 7, "examined_count" => 7, "truncated" => false, "unexamined_count" => 0,
        "limit" => SpecObservation::UNSTABLE_CANDIDATE_LIMIT
      )
    end
  end

  # A null description cannot be matched to itself across runs — two nulls are not known to be one
  # example — so those rows are dropped from the matching before anything is grouped, and the
  # exclusion is counted. Dropping them silently is the reading this must not produce.
  describe "rows that carried no description" do
    it "counts the excluded rows and never pools them into a test of their own" do
      3.times do |index|
        ingest(repository,
               [example_spec(name: FLIPPING_TEST, outcome: index == 1 ? "failed" : "passed"),
                example_spec(name: nil, outcome: "failed", line_number: 9,
                             file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })

      # Counted in ROWS and never in tests — an unnamed row is precisely a row this block cannot
      # say is a test.
      expect(block["unnamed_count"]).to eq(3)
      expect(block["rows"].map { |row| row["name"] }).to eq([FLIPPING_TEST])
      expect(block["rows"].map { |row| row["name"] }).not_to include(nil)
      # Three unnamed rows failed in every run of the window, and not one of them became a
      # candidate: the exclusion happens before the grouping rather than after it.
      expect(block["candidate_count"]).to eq(1)
    end

    it "serves a real zero where every row carried a description" do
      repository_with(%w[passed failed])

      _window, block = blocks(query: { branch: "main" })

      expect(block["unnamed_count"]).to eq(0)
    end
  end

  # Per the project's semantic-identity rule a test that MOVED is the same test and keeps its
  # history, so a group spanning two files is a DISCLOSURE rather than an error — and a reader
  # looking for a flaky test in one file needs to know the history spans two.
  describe "a test recorded under more than one spec file" do
    it "serves every file the history spans, sorted, beside the flag" do
      [["spec/models/invoice_spec.rb", "passed"],
       ["spec/models/invoice_spec.rb", "failed"],
       ["spec/billing/invoice_spec.rb", "passed"]].each_with_index do |(file_path, outcome), index|
        ingest(repository,
               [example_spec(name: FLIPPING_TEST, outcome: outcome, file_path: file_path)],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      _window, block = blocks(query: { branch: "main" })

      expect(row_named(block, FLIPPING_TEST)).to include(
        "multi_file" => true,
        "files_seen" => ["spec/billing/invoice_spec.rb", "spec/models/invoice_spec.rb"]
      )
    end

    # Read through `Row#files_seen` and `#outcome_words` rather than off the struct members, which
    # is what the ticket's implementer note asks for: both aggregates are `ARRAY_AGG(…) FILTER (…)`,
    # which is SQL NULL rather than an empty array for a group with nothing to collect.
    #
    # AND THAT NULL IS NOT REACHABLE THROUGH THE PRODUCER TODAY, which is worth saying rather than
    # implying otherwise with an example that cannot fail for it. A row only reaches this list by
    # being a CANDIDATE, and a candidate is a description that FAILED somewhere in the window — so
    # its `outcomes` group always has at least one non-null member. `spec_file_path` is likewise
    # never null off `Ingest::ObservationRecorder#attributes`, which falls back to `file_path`
    # precisely so no row drops out of a by-file total. So the accessors guard a producer path that
    # does not exist yet, and swapping them for the raw members is INVISIBLE here — verified by
    # mutation rather than assumed.
    #
    # What this example does pin is the reading a client gets: two sorted lists of strings, and a
    # run that recorded the description while saying nothing about how it ended counted as silence
    # rather than as a pass. `#changed?` compares against `reported_outcome_count` and never against
    # `recorded_count` for exactly that reason.
    it "serves sorted lists, and counts the silence as silence" do
      repository_with(["failed", "passed", nil, nil])

      _window, block = blocks(query: { branch: "main" })
      row = row_named(block, FLIPPING_TEST)

      expect(row["outcome_words"]).to eq(%w[failed passed])
      expect(row["files_seen"]).to eq(["spec/models/invoice_spec.rb"])
      # Silence is not a pass and is counted as neither outcome: four runs recorded it, two said
      # how it ended.
      expect(row).to include("recorded_count" => 4, "reported_outcome_count" => 2,
                             "unreported_outcome_count" => 2, "failed_count" => 1)
    end

    # The words are echoed, never reworded and never folded into a verdict — nothing platform-side
    # validates that string, so quoting what arrived is the only reading that cannot be wrong.
    it "echoes an outcome word it does not recognise rather than reading it as a pass" do
      repository_with(%w[failed flaked])

      _window, block = blocks(query: { branch: "main" })

      expect(row_named(block, FLIPPING_TEST)["outcome_words"]).to eq(%w[failed flaked])
    end
  end

  # Criterion 7. `flakiness_grain_reads` and the partition it belongs to come from
  # spec/support/observation_grain_reads.rb, which is also where the argument for matching every
  # grain POSITIVELY lives. The four patterns are `UnstableTests.for`'s four reads in the order it
  # issues them, so a block below can say WHICH of the four fired rather than only how many — the
  # difference between "one read" and "the gating probe, and then it stopped".
  describe "what the flakiness block costs the endpoint" do
    def flakiness_reads_matched(&)
      reads = observation_reads(&)
      flakiness_grain_patterns.map { |pattern| reads.grep(pattern).length }
    end

    # ZERO, and it is the whole branch-scope decision expressed as a cost: unfiltered, the object
    # is not constructed, so there is nothing to read. A gate placed AFTER the reads would serve
    # the same `null` and cost four.
    it "reads spec_observations not at all on an unfiltered window" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)

      expect(flakiness_grain_reads { get_repository(key: api_key) }).to be_empty
      # And the endpoint's other grains are untouched at their own established count, so the zero
      # above is this grain declining to read rather than the table going quiet. EIGHT and not six:
      # the six single-run reads, plus the ONE `directory_run_growth` adds and the ONE
      # `directory_runtime_growth` adds — both pairs compare the latest run against the previous one
      # on its branch and are served UNCONDITIONALLY, so they read on an unfiltered window where both
      # branch-gated blocks decline. They are counted here rather than excluded, because the point of
      # this line is that a read belonging to another grain cannot disappear into this one's zero.
      # ⭐ ONE MORE SINCE SPGD-711 — `latest_run.intent_readings`, an aggregate over the anchored
      # run's rows splitting them into authored, derived and unreadable. It is the only UNGATED
      # addition this endpoint has taken: every drill-in here costs nothing until a client asks, and
      # this is served on every response, because a correction a client has to opt into leaves it
      # reading `total_specs - annotated_specs` as the count of what SpecGuard cannot see. It lands
      # in its own grain (`AS run_authored_count`) and touches none of the figures above.
      expect(observation_reads { get_repository(key: api_key) }.length).to eq(9)
      expect(get_repository(key: api_key)["unstable_tests"]).to be_nil
    end

    # ONE, and specifically the FIRST of the four. `UnstableTests.for` asks the gating question on
    # its own and returns before the other three, so an incomparable window costs one probe — which
    # a bare count of one cannot distinguish from any other single read.
    it "reads it exactly once, and only the gating probe, on an incomparable window" do
      repository_with([nil, nil, nil])
      get_repository(key: api_key)

      expect(flakiness_reads_matched { get_repository(key: api_key, query: { branch: "main" }) })
        .to eq([1, 0, 0, 0])
      expect(get_repository(key: api_key, query: { branch: "main" })
               .dig("unstable_tests", "comparable")).to be(false)
    end

    # FOUR AT MOST, and here exactly four — one per read, each fired once. Pinned as four
    # positively-matched statements rather than as a total, so a read that stopped being issued and
    # a different one that started cannot cancel out into a passing number.
    #
    # THIS IS ALSO THE MEMOIZATION GUARD, and it is the only form of one this endpoint can have.
    # `show` reads the presenter twice — once for the window block's `grouped`, once for the rows —
    # so an unmemoized `unstable_tests` builds it twice and every count below doubles. There is no
    # separate example for that: a per-read count of one IS the statement that it was built once,
    # and an example that only re-asserted it over the incomparable window would be pinning the
    # gating probe a second time rather than the memo.
    it "reads it exactly four times on a branch-scoped comparable window, one per read" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)

      expect(flakiness_reads_matched { get_repository(key: api_key, query: { branch: "main" }) })
        .to eq([1, 1, 1, 1])
      expect(flakiness_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(4)
    end

    # And the four are ALL of the reads this window adds — the assertion the per-grain count cannot
    # make, because a read matching no grain's pattern is invisible to every one of them. Thirteen is
    # the endpoint's six single-run reads, plus these four, plus the TWO the growth-by-area grain
    # adds on the same branch-scoped window — one for `directory_growth` (the branch window's two
    # endpoints) and one for `directory_run_growth` (the latest run against the previous one on its
    # branch) — plus the ONE the RUNTIME grain adds, which is `directory_runtime_growth` ranking the
    # same two runs' areas by summed duration rather than by example count. Those three are counted
    # here rather than folded into the four, because the whole point of this example is that a read
    # belonging to no grain is caught by the total:
    # `spec/requests/api/v1/repository_directory_growth_spec.rb` and its two run-over-run siblings
    # bound them, this line only refuses to let them disappear.
    it "adds exactly those four to the table's total, and no fifth" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)

      area, file, example, description, flakiness, growth =
        observation_reads_by_grain { get_repository(key: api_key, query: { branch: "main" }) }
      runtime_growth =
        runtime_growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }

      expect([area.length, file.length, example.length, description.length, flakiness.length])
        .to eq([1, 1, 2, 2, 4])
      expect(growth.length).to eq(2)
      expect(runtime_growth.length).to eq(1)
      expect(observation_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key, query: { branch: "main" }) })
      expect(observation_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(14)
    end

    # NO RUN-WINDOW QUERY. The block is drawn on `history_runs`, which is materialized once and
    # already read twice by `show`, so a second `recent_test_runs` would be invisible to every
    # count above and would read as one more branch-scoped SELECT here.
    #
    # `directory_run_growth`'s previous-run lookup ALSO carries a branch predicate, and is excluded
    # on the ROW-VALUE predicate `Repository#previous_test_run_on_branch` emits and
    # `recent_test_runs` does not — so this still pins the window at one statement rather than
    # absorbing a regression into a widened total.
    it "adds no query against test_runs, whatever the window holds" do
      repository_with(Array.new(12) { |index| index == 3 ? "failed" : "passed" })
      get_repository(key: api_key)

      statements = executed_sql { get_repository(key: api_key, query: { branch: "main" }) }
      window_selects = statements.grep(/FROM "test_runs"/).grep(/"branch" = /)
                                 .grep_v(/\(test_runs\.created_at, test_runs\.id\) < /)

      expect(window_selects.length).to eq(1)
      expect(window_selects.first).to include("LIMIT")
      # The block really was served over that one window, so the count above is not one because
      # nothing asked.
      expect(get_repository(key: api_key, query: { branch: "main" }).dig("unstable_tests", "run_count"))
        .to eq(12)
    end

    # CONSTANT IN THE LENGTH OF THE WINDOW. The gating probe is one lateral over the run ids and
    # the composition is one grouped aggregate over the window — never one read per run, which is
    # the N+1 a three-run fixture cannot distinguish from none.
    it "costs the same at 3 runs and at the full 30-run bound" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key, query: { branch: "main" }) }

      27.times do |index|
        ingest(repository,
               [example_spec(name: FLIPPING_TEST, outcome: index == 5 ? "failed" : "passed")],
               commit_sha: "grow#{format("%08d", index)}", at: (20 - (index / 3.0)).days.ago)
      end

      expect(repository.test_runs.where(branch: "main").count).to eq(30)
      expect(flakiness_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(4)
      expect(count_queries { get_repository(key: api_key, query: { branch: "main" }) }).to eq(baseline)
      # The window really did grow to the bound, so the invariance above is over an axis that
      # moved rather than one that never left three.
      expect(get_repository(key: api_key, query: { branch: "main" }).dig("unstable_tests", "run_count"))
        .to eq(Repository::TRAJECTORY_LIMIT)
    end

    # CONSTANT IN THE SIZE OF THE SUITE. Two orders of magnitude of examples per run cost the same
    # four reads — the property that makes the block affordable at the roadmap's design point.
    it "costs the same four reads as the suite grows" do
      repository_with(%w[passed failed passed])
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key, query: { branch: "main" }) }

      2.times do |run_index|
        specs = (0..300).map do |i|
          example_spec(name: "stable #{format("%04d", i)}", outcome: "passed", line_number: i + 10,
                       file_path: "spec/models/big_#{i % 20}_spec.rb")
        end
        specs << example_spec(name: FLIPPING_TEST, outcome: run_index.zero? ? "failed" : "passed")
        ingest(repository, specs, commit_sha: "big#{format("%09d", run_index)}",
                                  at: (2 - run_index).days.ago)
      end

      expect(repository.spec_observations.count).to be > 600
      expect(flakiness_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(4)
      expect(count_queries { get_repository(key: api_key, query: { branch: "main" }) }).to eq(baseline)
    end

    # `show` reads the presenter twice — once for the window block's `grouped`, once for the rows —
    # and must not build it twice. That claim is pinned by the per-read counts above rather than
    # here; see the note on "reads it exactly four times", which is where an unmemoized presenter
    # actually shows up.
  end
end
