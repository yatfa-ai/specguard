# frozen_string_literal: true

require "rails_helper"

# The drill-in under the "Tests whose outcome changed" panel on repositories#show — ONE test's rows
# across the window that panel ranks, opened with `?unstable_test=`.
#
# The rung below spec/requests/repository_unstable_tests_spec.rb and deliberately its own file, for
# the reason every sibling drill-in spec states for itself: every example here needs the same
# multi-run fixture, and the panel above is edited by a sibling slice.
#
# WHAT THE RANKING ABOVE CANNOT SAY is the whole subject of this file. A row up there reads
# `30 runs, 4 failed, [failed, passed]`, and those three figures are IDENTICAL for two windows that
# call for opposite work: four failures at the newest four runs is a REGRESSION with a commit to
# find, and four failures scattered through thirty is FLAKINESS with none.
# `SpecObservation::UNSTABLE_COMPOSITION` is `COUNT`s and `ARRAY_AGG(DISTINCT …)` under
# `GROUP BY name` and is right to be — that is what keeps it constant in the size of the suite — so
# the run axis is not recovered by changing it. It is recovered here.
#
# The DIRECTION of the list is asserted rather than assumed, and it is the one property of this
# panel a reader could not check for themselves. `SpecObservation.outcome_sequence_in` orders by
# `array_position` over the run ids it is HANDED, so the order is the window's own — and this page's
# window is `Repository#suite_size_trajectory`, which is OLDEST FIRST because it is the window the
# "Suite growth" chart is plotted along. The same method under `GET /api/v1/repository` runs
# newest-first off `recent_test_runs`. One order asserted and the other assumed is how a panel ships
# pointing readers at the wrong end of their own evidence.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: a nil `outcome` is `result&.status` coming back nil on a real client, a run that
# recorded nothing under a description is a test added halfway through a window, and two examples
# sharing a description in one run is an ordinary table-driven loop. A hand-built fixture would
# assert against shapes nothing in production writes.
RSpec.describe "Repository unstable test runs", type: :request do
  before { @user = sign_in_via_github }

  def page = Capybara.string(response.body)

  def panel = page.find("#unstable-test-runs")

  def panel? = page.has_css?("#unstable-test-runs")

  # ELEMENT-scoped, never panel-scoped: the scope sentence, the reading rule and the silence clause
  # share most of their words with the ranking panel's own basis line one panel up, so a
  # page-level `have_text` passes for the wrong paragraph with the deciding branch deleted.
  def basis_line = panel.find("#unstable-test-runs-basis")

  def none_state = panel.find("#unstable-test-runs-none")

  # The cap's own disclosure, ELEMENT-scoped like the basis line and for a sharper version of the
  # same reason: this alert exists precisely because a truncated list renders identically to a
  # complete one, so an assertion that could pass off the basis paragraph beside it would be
  # asserting the thing it is here to distinguish from.
  def cap_alert = panel.find("#unstable-test-runs-cap")

  def cap_alert? = panel.has_css?("#unstable-test-runs-cap")

  def ranking_panel = page.find("#unstable-tests")

  # One row as a reader meets it: which run, where the test was defined in it, on which branch, when
  # it landed, how long it took and what that run said happened. Whitespace-collapsed, because a
  # cell assembled across two ERB tags is one reading on the page whatever the source did with
  # indentation.
  def rows
    panel.all("tbody tr").map do |row|
      commit, definition_site, branch, ingested, duration, outcome =
        row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { commit: commit, definition_site: definition_site, branch: branch, ingested: ingested,
        duration: duration, outcome: outcome }
    end
  end

  # The definition-site cell's LINKS, read as hrefs rather than as text — this panel's whole
  # departure from its siblings lives in the ref inside the href, and the visible coordinate is
  # identical whichever commit the link was pinned to. CELL-scoped by position, because the commit
  # cell beside it is the other place a sha appears on this row.
  def definition_site_hrefs
    panel.all("tbody tr").map { |row| row.all("td")[1].all("a").map { |link| link[:href] } }.flatten
  end

  # The commit cell's LINKS, read the same way and for the same reason: the visible text is seven
  # characters whatever ref the href was built from, so the departure this cell makes lives entirely
  # inside the href. CELL-scoped by position (column 0), because the definition-site cell beside it
  # is the other place this row's sha appears — a panel-wide `all("a")` would read both and pass off
  # the neighbour with this cell's link deleted.
  def commit_hrefs
    panel.all("tbody tr").map { |row| row.all("td")[0].all("a").map { |link| link[:href] } }.flatten
  end

  def commit_links = panel.all("tbody tr").filter_map { |row| row.all("td")[0].first("a") }

  def duration_sequence = rows.map { |row| row[:duration] }

  def definition_site_sequence = rows.map { |row| row[:definition_site] }

  def outcome_sequence = rows.map { |row| row[:outcome] }

  def commit_sequence = rows.map { |row| row[:commit] }

  # One ingested run, through the producer. Every run is stamped back in time so the window — which
  # this panel shares with the chart and the ranking above it — orders them the way CI produced them
  # rather than by whatever order the fixture inserted them in.
  def ingest(repository, specs, commit_sha:, branch: "main", at: nil)
    run = Ingest::RunRecorder.record(
      repository,
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

  # A run's commit, POSITIONAL IN ITS FIRST SEVEN CHARACTERS — which is all the panel prints, and
  # therefore all an assertion about ORDER can read. A fixture whose shas share a seven-character
  # prefix renders one indistinguishable column, and an ordering assertion over it passes in both
  # directions.
  def sha_for(index) = "#{format("%02d", index)}c0ffee0000"

  # The description this file opens, and a second one to be wrong about.
  def flaky = "Invoice finalize locks the line items"

  def stable = "User signs in"

  # A repository whose window holds one run per entry of `outcomes_per_run`, each run reporting the
  # given outcome for the flaky test plus a second test that always passes — so every assertion
  # about "this description's rows" has other rows to be wrong about, and the ranking above has a
  # test it must not list.
  #
  # Commit shas are POSITIONAL (see `#sha_for`) so the ORDER of the list is readable off the commit
  # column: an assertion on the outcome column alone cannot tell an oldest-first sequence from a
  # newest-first one whenever the sequence is a palindrome, and `%w[passed failed passed]` is one.
  def repository_with(outcomes_per_run, name: flaky, github_full_name: "acme/checkout", **attrs)
    repository = create_repository(user: @user, github_full_name: github_full_name)
    outcomes_per_run.each_with_index do |outcome, index|
      ingest(repository,
             [example_spec(name: name, outcome: outcome, line_number: 1, **attrs),
              example_spec(name: stable, outcome: outcome.nil? ? nil : "passed",
                           line_number: 2, file_path: "spec/models/user_spec.rb")],
             commit_sha: sha_for(index), at: (30 - index).days.ago)
    end
    repository
  end

  # Criterion 2 — the way IN. Until this link existed the ranking's rows dead-ended at the one
  # question the panel is read to answer.
  describe "opening a test from the ranking above" do
    it "links each ranked test to its own run-by-run sequence" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      href = ranking_panel.find("a", text: flaky)[:href]

      expect(href).to include("unstable_test=#{CGI.escape(flaky)}")
      expect(href).to include("#unstable-test-runs")
    end

    # A list of choices with one of them taken. The drill-in sits below a long panel, so a reader
    # arriving back at this table has to be told which row they are already looking at.
    it "marks the open test in the panel it was opened from" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository, unstable_test: flaky)

      expect(ranking_panel.find("a", text: flaky)["aria-current"]).to eq("true")
    end

    # And marks nothing when nothing is open — an `aria-current` on every row is the same as one on
    # none, and it is the state the page is in for every reader who has not clicked yet.
    it "marks nothing when no test is open" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      expect(ranking_panel.find("a", text: flaky)["aria-current"]).to be_nil
    end

    # Criterion 5 — the groups below the list stay PLAIN TEXT. Those are descriptions carried by
    # more than one example IN A SINGLE RUN, so the description is not a key there: that run's
    # `failed` and its `passed` are two different examples rather than one test that flipped, and a
    # sequence drawn under one heading would interleave two tests. The panel above says so in as
    # many words, and this is that sentence made falsifiable.
    it "leaves the shared-description groups unlinked" do
      repository = create_repository(user: @user)
      %w[passed failed].each_with_index do |outcome, index|
        ingest(repository,
               [example_spec(name: flaky, outcome: outcome, line_number: 1),
                example_spec(name: flaky, outcome: "passed", line_number: 2),
                example_spec(name: stable, outcome: "passed", line_number: 3,
                             file_path: "spec/models/user_spec.rb")],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository)

      shared = page.find("#unstable-tests-shared")

      expect(shared).to have_text(flaky, normalize_ws: true)
      expect(shared).to have_no_css("a")
    end
  end

  # Criterion 1 — the whole point of the slice. The sequence, in the window's own order, each row
  # naming the run it belongs to.
  describe "a test opened out of the ranking" do
    it "lists that description's rows run by run, naming the commit, branch, arrival and outcome" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository, unstable_test: flaky)

      expect(rows.size).to eq(3)
      expect(rows.first[:commit]).to eq("00c0ffe")
      expect(rows.first[:branch]).to eq("main")
      expect(rows.first[:ingested]).to match(/ago\z/)
      expect(outcome_sequence).to eq(%w[passed failed passed])
    end

    # THE assertion the panel exists for, and the one a palindrome fixture cannot make. The window
    # handed in is oldest-first, so the sequence is oldest-first, so the newest run is the LAST row
    # — and the caption says which end is which rather than leaving a reader to guess at the
    # direction of the evidence they are about to act on.
    it "runs oldest first, in the order of the window the chart above is plotted along" do
      repository = repository_with(%w[passed passed failed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(commit_sequence).to eq(%w[00c0ffe 01c0ffe 02c0ffe 03c0ffe])
      expect(outcome_sequence).to eq(%w[passed passed failed failed])
      expect(basis_line).to have_text("oldest run first", normalize_ws: true)
    end

    # A regression and a flake are the two readings this panel was built to separate, and they are
    # separated by WHERE the failures sit. Both fixtures produce the same row in the ranking above —
    # same run count, same failure count, same outcome words — and different sequences here, which
    # is the claim the whole ticket rests on.
    it "distinguishes a regression from a flake that the ranking above reports identically" do
      regression = repository_with(%w[passed passed failed failed], github_full_name: "acme/regressed")
      flake = repository_with(%w[failed passed failed passed], github_full_name: "acme/flaked")

      get repository_path(regression, unstable_test: flaky)
      regression_sequence = outcome_sequence
      regression_row = ranking_panel.all("tbody tr").first.all("td").map { |cell| cell.text.strip }

      get repository_path(flake, unstable_test: flaky)
      flake_sequence = outcome_sequence
      flake_row = ranking_panel.all("tbody tr").first.all("td").map { |cell| cell.text.strip }

      expect(regression_row).to eq(flake_row)
      expect(regression_sequence).not_to eq(flake_sequence)
      expect(regression_sequence).to eq(%w[passed passed failed failed])
      expect(flake_sequence).to eq(%w[failed passed failed passed])
    end

    # How to read the column, on the panel rather than in the code. Worded by POSITION IN THIS LIST
    # and not by "latest", because this window runs oldest first and a sentence about the top of the
    # list would point at the opposite end of the evidence from the one it means.
    it "states which end of the list is the newest run" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(basis_line).to have_text("Failures bunched at the END of this list — its newest runs " \
                                      "— are a regression", normalize_ws: true)
      expect(basis_line).to have_text("scattered through the list are flakiness", normalize_ws: true)
    end

    # The caption sizes the list in ROWS against a window stated in RUNS, and never mixes them:
    # `rows.length` is neither the window's length nor bounded below by it.
    it "sizes the list in rows and the window in runs" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository, unstable_test: flaky)

      expect(basis_line).to have_text("All 3 rows the last 3 runs of this window recorded under it",
                                      normalize_ws: true)
      expect(basis_line).to have_text(flaky, normalize_ws: true)
    end

    # One row per run is what the data USUALLY is rather than a promise. A test added halfway through
    # the window has fewer rows than the window has runs, and the caption says so rather than leaving
    # a reader to subtract two numbers and conclude a run went missing.
    it "lists no row for a run that recorded nothing under the description" do
      repository = create_repository(user: @user)
      4.times do |index|
        specs = [example_spec(name: stable, outcome: "passed", line_number: 2,
                              file_path: "spec/models/user_spec.rb")]
        specs << example_spec(name: flaky, outcome: index == 3 ? "failed" : "passed") if index >= 2
        ingest(repository, specs, commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(rows.size).to eq(2)
      expect(basis_line).to have_text("All 2 rows the last 4 runs of this window recorded under it",
                                      normalize_ws: true)
      expect(basis_line).to have_text("A run that recorded nothing under this description " \
                                      "contributes no row", normalize_ws: true)
    end

    # And it comes apart in the other direction too: a description carried by two examples in one run
    # contributes two rows to that run.
    it "lists a row per example when one run carried the description twice" do
      repository = create_repository(user: @user)
      %w[passed failed].each_with_index do |outcome, index|
        ingest(repository,
               [example_spec(name: flaky, outcome: outcome, line_number: 1),
                example_spec(name: flaky, outcome: "passed", line_number: 2)],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(rows.size).to eq(4)
      expect(basis_line).to have_text("All 4 rows the last 2 runs of this window recorded under it",
                                      normalize_ws: true)
      expect(basis_line).to have_text("contributes one row per example", normalize_ws: true)
    end

    # The cap, disclosed only when it BIT — and disclosed as WHICH END it kept, which is a property
    # of the WINDOW rather than of the read. `SpecObservation.outcome_sequence_in` orders by
    # `array_position` over the run ids it is handed, so on this page's oldest-first window the
    # `LIMIT` sheds the NEWEST rows, where the same method under `GET /api/v1/repository` sheds the
    # oldest ones off a newest-first window. A caption that said "the most recent N" here would name
    # the rows that are not on the page.
    it "says which end of the sequence the cap kept when it bit" do
      repository = create_repository(user: @user, github_full_name: "acme/looped")
      %w[passed failed].each_with_index do |outcome, index|
        specs = (1..101).map do |i|
          example_spec(name: flaky, outcome: i == 1 ? outcome : "passed", line_number: i)
        end
        ingest(repository, specs, commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(rows.size).to eq(SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
      expect(basis_line).to have_text("The 200 oldest of the 202 rows the last 2 runs of this " \
                                      "window recorded under it", normalize_ws: true)
      # The cap kept the OLDEST end: the older run's 101 rows are all here and the NEWEST run is the
      # one two of its rows fell off, which is the claim the sentence makes and the one a "most
      # recent" wording would invert.
      expect(commit_sequence.tally).to eq("00c0ffe" => 101, "01c0ffe" => 99)
    end

    # THE GEOMETRY THE EXAMPLE ABOVE CANNOT REACH, and the one that made this panel ship a false
    # sentence the first time.
    #
    # 2 runs × 101 rows sheds two rows off the newest run and KEEPS that run, so the end of the list
    # is still the newest run and a sentence claiming so stays true. It is the one truncation shape
    # under which the old unconditional reading rule could not fail. Truncation needs >200 rows over
    # ≤30 runs — more than ~6.7 rows per run — and at 10 rows per run over 25 runs the newest FIVE
    # RUNS are off the page entirely.
    #
    # Ten examples sharing one description in a run is a table-driven loop, not a pathology, and the
    # window here is a textbook regression: passing until run 21, failing from there to the end. The
    # 200 rows that survive the cap are runs 1–20 — every one of them green. Without the disclosure
    # the reader is handed a full-looking table of 200 passes for a test the ranking above lists as
    # unstable, under a rule saying failures at the end mean regression and scattered failures mean
    # flakiness. Neither branch applies, and both available conclusions ("it is fine", "the panel is
    # broken") are wrong.
    def repository_with_loop_regression
      repository = create_repository(user: @user, github_full_name: "acme/looped-regression")
      25.times do |index|
        specs = (1..10).map do |i|
          example_spec(name: flaky, outcome: index >= 20 ? "failed" : "passed", line_number: i)
        end
        ingest(repository, specs, commit_sha: sha_for(index), at: (30 - index).days.ago)
      end
      repository
    end

    it "drops whole runs off the newest end when the description is carried many times per run" do
      get repository_path(repository_with_loop_regression, unstable_test: flaky)

      expect(rows.size).to eq(SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
      # Runs 21-25 — every failing run in the window — are not on the page in any form. Asserted as
      # the absence of their commits rather than as an outcome tally, because the commit column is
      # what a reader would join against and it is the column that proves WHICH runs went missing.
      expect(commit_sequence.uniq).to eq((0..19).map { |index| sha_for(index).first(7) })
      expect(commit_sequence).not_to include("20c0ffe", "24c0ffe")
      # And the consequence, stated as the reader meets it: a live regression rendering as an
      # unbroken column of passes.
      expect(outcome_sequence.uniq).to eq(["passed"])
    end

    # The disclosure, in front of the table rather than inside the paragraph under it. On this panel
    # a truncated list is not a shorter answer, it is a missing one that renders like a negative
    # one — so it is asserted as its own element, with the figure, the commit the list stops at, and
    # the pointer to the window that keeps the other end.
    it "says loudly, above the table, that the newest rows are the ones missing" do
      get repository_path(repository_with_loop_regression, unstable_test: flaky)

      expect(cap_alert).to have_text("This list stops short of the window's newest rows",
                                     normalize_ws: true)
      expect(cap_alert).to have_text("the 50 rows it dropped are the newest ones recorded under " \
                                     "this description", normalize_ws: true)
      # WHERE it stops — the last row's commit and not the window's, which is the comparison that
      # makes the gap visible against the "Recent runs" panel below.
      expect(cap_alert).to have_text("The list ends at 19c0ffe", normalize_ws: true)
      expect(cap_alert).to have_text("its window runs newest first", normalize_ws: true)
    end

    # THE BLOCKING CLAIM: the reading rule withholds the regression branch when the cap took the end
    # it is read from. Pinned from BOTH sides — the same sentence is asserted PRESENT on an
    # untruncated window by "states which end of the list is the newest run" above, so its absence
    # here is a branch that fired rather than a string that never renders.
    it "withholds the regression reading when the cap took the end it is read from" do
      get repository_path(repository_with_loop_regression, unstable_test: flaky)

      expect(basis_line).not_to have_text("Failures bunched at the END of this list — its newest " \
                                          "runs — are a regression", normalize_ws: true)
      expect(basis_line).to have_text("the end of this list is not the end of this window's " \
                                      "evidence", normalize_ws: true)
      # The reading that lets a live regression off the page is named explicitly, because it is the
      # one a reader arrives at by default in front of 200 green rows.
      expect(basis_line).to have_text("no failures sitting there is not evidence that the test is " \
                                      "passing now", normalize_ws: true)
      # The flakiness branch survives the cap and is still stated: scattered failures among the rows
      # that ARE here are still scattered failures.
      expect(basis_line).to have_text("Failures scattered through the rows that ARE here are " \
                                      "still flakiness", normalize_ws: true)
    end

    # The scope sentence, the alert and the reading rule all branch on one predicate, so the panel
    # cannot disclose the truncation in one sentence and deny it two clauses later — which is
    # exactly how it shipped the first time. Asserted as the three agreeing on one page.
    it "does not contradict itself about whether the cap bit" do
      get repository_path(repository_with_loop_regression, unstable_test: flaky)

      expect(basis_line).to have_text("The 200 oldest of the 250 rows the last 25 runs of this " \
                                      "window recorded under it", normalize_ws: true)
      expect(cap_alert?).to be(true)
      expect(basis_line).to have_text("not the end of this window's evidence", normalize_ws: true)
    end

    # And the other side of the branch: an uncapped window gets no alert and keeps the regression
    # reading. Without this the two examples above would pass over a panel that showed the warning
    # unconditionally, which would be the same defect wearing the opposite sign.
    it "shows no cap warning and keeps the regression reading when the list is complete" do
      repository = repository_with(%w[passed passed failed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(cap_alert?).to be(false)
      expect(basis_line).to have_text("Failures bunched at the END of this list — its newest runs " \
                                      "— are a regression", normalize_ws: true)
      expect(basis_line).not_to have_text("not the end of this window's evidence", normalize_ws: true)
    end

    # Silence is not a pass. `outcome` is nullable and nothing validates it, so a client that stopped
    # sending outcomes writes rows that are present and quiet — and a sequence that rendered those as
    # passes would manufacture a flip that looks like a DATE, which is the one wrong answer this
    # panel is read to produce.
    it "renders a run that reported no outcome as silence rather than as a pass" do
      repository = repository_with(["failed", nil, "passed"])

      get repository_path(repository, unstable_test: flaky)

      expect(outcome_sequence).to eq(["failed", "not reported", "passed"])
      expect(basis_line).to have_text("1 of the 3 rows said nothing about how it ended",
                                      normalize_ws: true)
      expect(basis_line).to have_text("Silence is not a pass", normalize_ws: true)
    end

    # The clause is a statement about THIS window and not arithmetic: over a window that reported
    # everything there is no silence to count, and "0 of them said nothing" is a sentence about
    # nothing. Asserted absent as well as present, because a clause only ever asserted present is
    # how the vacuous one ships green.
    it "says nothing about silence over a window that reported every row" do
      repository = repository_with(%w[failed passed])

      get repository_path(repository, unstable_test: flaky)

      expect(basis_line).to have_no_text("said nothing about how it ended", normalize_ws: true)
    end

    # An outcome word nobody recognises is echoed rather than folded into a verdict — nothing
    # platform-side validates this string, so quoting what arrived is the only reading that cannot
    # be wrong.
    it "echoes an outcome word it does not recognise" do
      repository = repository_with(%w[failed flaked])

      get repository_path(repository, unstable_test: flaky)

      expect(outcome_sequence).to eq(%w[failed flaked])
    end

    # The window is the trajectory's window, branch and all — outcomes compared across branches are
    # outcomes of different code, and a sequence read down an interleaved window is the outcomes of
    # different code in run order.
    it "reads only the runs on the branch the page is anchored to" do
      repository = repository_with(%w[passed failed])
      ingest(repository, [example_spec(name: flaky, outcome: "failed")],
             commit_sha: "sidebranch1", branch: "feature/x", at: 40.days.ago)

      get repository_path(repository, unstable_test: flaky)

      expect(rows.size).to eq(2)
      expect(commit_sequence).to eq(%w[00c0ffe 01c0ffe])
      expect(rows.map { |row| row[:branch] }.uniq).to eq(["main"])
    end
  end

  # Criterion 3 — an ask naming nothing the window recorded. An ordinary answer and not an error:
  # the project's identity rule is semantic, so a renamed test starts a new history and every
  # bookmark to the old description goes stale BY DESIGN.
  describe "a description the window recorded nothing under" do
    it "renders the empty state naming the description that was asked for" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository, unstable_test: "Invoice finalise locks the line items")

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(true)
      expect(rows).to be_empty
      expect(none_state).to have_text("Invoice finalise locks the line items", normalize_ws: true)
      expect(none_state).to have_text("None of the last 3 runs of this window recorded an example " \
                                      "described", normalize_ws: true)
    end

    # And it names the RULE that makes this the ordinary case rather than a lost history — a reader
    # who does not know tests are matched by description alone reads an empty panel as a bug.
    it "names the matching rule that makes a stale bookmark ordinary" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: "renamed since")

      expect(none_state).to have_text("a test renamed or reworded since starts a new history",
                                      normalize_ws: true)
    end

    # No caption over an empty list. The scope sentence and the reading rule are both claims about
    # rows, and printed over none of them they would be claims about nothing.
    it "prints no scope sentence and no table over it" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: "renamed since")

      expect(panel).to have_no_css("#unstable-test-runs-basis")
      expect(panel).to have_no_css("tbody tr")
    end
  end

  # The drill-in fires on the ASK and specifically NOT on the ranking above being comparable. A
  # window that ranking has nothing to say about is precisely the one where the raw per-run grain is
  # worth having: "no candidates" and "here is what this test actually did" answer different
  # questions, and gating the second on the first would withhold the grain exactly when the aggregate
  # went silent. `Api::V1::RepositoriesController` makes the same choice for the same reason.
  describe "a window the ranking above cannot rank" do
    it "still serves the sequence over a window where only one run reported an outcome" do
      repository = repository_with([nil, "failed", nil])

      get repository_path(repository, unstable_test: flaky)

      expect(page).to have_css("#unstable-tests-incomparable")
      expect(panel?).to be(true)
      expect(outcome_sequence).to eq(["not reported", "failed", "not reported"])
    end

    # A test that failed in EVERY run is broken rather than unstable and is not in the ranking at
    # all — so it is reachable here only by a typed or bookmarked URL, which is exactly the reader
    # this panel owes an answer to.
    it "serves the sequence for a test the ranking deliberately leaves out" do
      repository = repository_with(%w[failed failed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(page.find("#unstable-tests-none")).to have_text("No test changed its outcome",
                                                             normalize_ws: true)
      expect(outcome_sequence).to eq(%w[failed failed failed])
    end
  end

  # Criterion 4 — the way back OUT, and the one control on this panel whose CORRECT value is an
  # absence.
  describe "closing the test" do
    it "clears only its own ask and leaves every other panel open" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky, branch: "main",
                                      repeated_description: stable)

      href = panel.find("a", text: "Close test", match: :prefer_exact)[:href]
      query = href.split("#").first.to_s.split("?", 2).last.to_s.split("&")

      expect(query).not_to include(a_string_starting_with("unstable_test="))
      expect(query).to include("repeated_description=#{CGI.escape(stable)}")
      expect(query).to include("branch=main")
      expect(href).to include("#unstable-tests")
    end
  end

  # The three shapes a query string can legally parse into that are not a String. This parameter
  # reaches `where(name: …)` on a plain text column, where an Array does not raise — it becomes an
  # `IN` list and interleaves several tests' outcomes into ONE run-ordered sequence under a name
  # restating one, which is the worst of the five to catch by eye: two tests shuffled together look
  # exactly like the alternation this panel exists to show.
  describe "an unstable-test parameter that is not a description" do
    def expect_unstable_test_param_treated_as_no_ask(query)
      get repository_path(repository_with(%w[passed failed]), **query)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end

    it_behaves_like "a surface that treats a malformed unstable-test parameter as no ask"

    # The positive path, beside the group it makes falsifiable: a guard that swallowed every value
    # would answer 200 on all three shapes above and render no panel here either.
    it "honours an unstable-test parameter that IS a description" do
      get repository_path(repository_with(%w[passed failed]), unstable_test: flaky)

      expect(panel?).to be(true)
      expect(rows.size).to eq(2)
    end

    # A blank ask is no ask. `spec_observations.name` is NULLABLE — which is why the ranking counts
    # unnamed rows separately and excludes them from the matching — so without `.presence` an empty
    # ask becomes `WHERE name = ''`, a query for a description no row can carry and therefore a
    # sequence guaranteed to be empty. That is a worse answer than not opening one.
    it "treats a blank unstable-test parameter as no ask" do
      get repository_path(repository_with(%w[passed failed]), unstable_test: "")

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # HOW LONG THE TEST TOOK IN EACH RUN — the column the sequence needs to get past its own verdict.
  # The outcome column separates a regression from a flake; it stops there, and for the largest class
  # of real flakes the next answer is timing. A test that passes at 4s and fails at 31s is hitting a
  # timeout rather than behaving randomly, and no aggregate over the window can show that: the
  # ranking above holds counts and a set of outcome words, and the per-run figure is the whole point.
  describe "how long the test took in each run" do
    # Durations are stamped PER RUN and read back per row. A view that took one figure off the
    # sequence — the first row's, or the window's own `duration_seconds` — renders a plausible
    # column that is constant down the list, which is exactly the shape a fixture with one duration
    # cannot tell from the right answer.
    it "carries each run's own duration rather than one figure repeated down the sequence" do
      repository = create_repository(user: @user)
      [["passed", 4.0], ["failed", 31.0]].each_with_index do |(outcome, duration), index|
        ingest(repository,
               [example_spec(name: flaky, outcome: outcome, duration: duration),
                example_spec(name: stable, outcome: "passed", line_number: 2,
                             file_path: "spec/models/user_spec.rb", duration: 0.01)],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(duration_sequence).to eq(["4.00s", "31.00s"])
    end

    # A run whose client reported no timing says so IN WORDS. `duration_seconds` is nullable —
    # `result&.run_time` comes back nil for an example that never ran — and `%.2f` over a nil is
    # "0.00s", which makes "the client sent no timing" byte-identical to "this test took no time".
    # On a column read for a timeout that is the one wrong answer it must not produce, so it is
    # pinned here rather than left to the model spec that owns the seam: what this asserts is that
    # the view goes THROUGH that seam.
    it "renders a run that reported no timing as not reported rather than as a zero" do
      repository = create_repository(user: @user)
      [0.5, nil].each_with_index do |duration, index|
        ingest(repository, [example_spec(name: flaky, outcome: "passed", duration: duration)],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(duration_sequence).to eq(["0.50s", "not reported"])
    end

    # And the caption says whose measurement it is, because "4.00s" on a dashboard reads as
    # something the dashboard measured. It is the client's own per-example figure, and a row may
    # carry none.
    it "says the durations are the client's own and that a row may carry none" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(basis_line).to have_text("Durations are the client's own per-example timings",
                                      normalize_ws: true)
      expect(basis_line).to have_text("a run whose client reported none says so rather than " \
                                      "reading as a zero", normalize_ws: true)
    end
  end

  # THE COMMIT ITSELF, as a link out to GitHub — the join this panel is read for. It has printed a
  # sha since it shipped and dead-ended there: the reader who has found the first failing row still
  # had to leave the product, find the repository and paste seven characters into it by hand.
  describe "opening the commit that ran each row" do
    # THE assertion that separates per-row pinning from the page-level sha it would be copied from.
    # The visible column is seven characters whatever ref the href carries, and a single-sha fixture
    # renders the two byte-identical — so this reads TWO rows at TWO commits and asserts each href
    # carries its OWN row's sha. Borrowing `@latest_test_run.commit_sha` would send every row to the
    # newest commit and name the wrong culprit on every row but one.
    it "links each row to the commit that ran it rather than to the page's newest" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(commit_hrefs).to eq(
        ["https://github.com/acme/checkout/commit/#{sha_for(0)}",
         "https://github.com/acme/checkout/commit/#{sha_for(1)}"]
      )
      expect(commit_hrefs.uniq.size).to eq(2)
    end

    # The FULL sha goes to GitHub even though seven characters are what the reader sees. The
    # abbreviation is a label for scanning; a link built from it would be a link built from the
    # label, which GitHub can often resolve and is not what this row knows.
    it "links at the full sha while still printing the abbreviation" do
      repository = repository_with(%w[passed])

      get repository_path(repository, unstable_test: flaky)

      expect(commit_sequence).to eq([sha_for(0).first(7)])
      expect(commit_hrefs.first).to end_with("/commit/#{sha_for(0)}")
    end

    # One row must not render two external links two ways: the commit cell and the definition-site
    # cell beside it both leave the product, so they carry the same classes, target and rel. The
    # `rel` is not cosmetic — `target="_blank"` without `noopener` hands the opened tab a handle
    # back to this one.
    it "carries the same external-link treatment as the definition site beside it" do
      repository = repository_with(%w[passed])

      get repository_path(repository, unstable_test: flaky)

      commit_link = commit_links.first
      definition_link = panel.all("tbody tr").first.all("td")[1].first("a")

      expect(commit_link[:target]).to eq("_blank")
      expect(commit_link[:rel]).to eq("noopener noreferrer")
      expect(commit_link[:class]).to eq(definition_link[:class])
    end

    # OUT to GitHub, never IN to the run-anchor drill-in. The Recent runs panel below links its own
    # sha column to `?commit_sha=` and must keep doing so (SPGD-664); this cell answers the other
    # question. Asserted as an absence because the failure mode is silent — a `?commit_sha=` href
    # here renders an identical-looking seven characters.
    it "leaves the product rather than re-opening the run on this page" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(commit_hrefs).to all(start_with("https://github.com/"))
      expect(commit_hrefs).to all(include("/commit/"))
      expect(commit_hrefs.join(" ")).not_to include("commit_sha=")
    end

    # ZERO NEW QUERIES: `row.commit_sha` comes off a run already loaded for the window, `@repository`
    # is loaded long before the partial renders, and `#github_commit_url` is string composition — so
    # a table of many linked rows must cost exactly what a table of one row costs.
    #
    # ROWS ARE VARIED AT A CONSTANT RUN COUNT, and that is the whole design of this example. Varying
    # the number of RUNS would measure the wrong thing: the window is per-run, so a longer history
    # also changes what else the page renders (the cross-run comparison panel, the run-anchor
    # lookup) and the two pages would differ by far more than the rows under test — a difference
    # that reads as a per-row leak and is not one. `UnstableTestRuns#rows` is not one-row-per-run:
    # a description carried by several examples in ONE run contributes one row EACH, which is what
    # lets this hold the run axis still and move only the row axis.
    #
    # `count_queries` rather than a single-table `queries_against`, on the precedent the sibling
    # panels' guards set: the regression this forecloses is a per-ROW reach for `@repository`, which
    # would show up against `repositories` and be invisible to a count scoped to one other table.
    it "adds no query for a table of many linked rows over a table of one" do
      one_per_run = create_repository(user: @user, github_full_name: "acme/one-per-run")
      three_per_run = create_repository(user: @user, github_full_name: "acme/three-per-run")
      3.times do |index|
        ingest(one_per_run, [example_spec(name: flaky, outcome: "passed", line_number: 1)],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
        ingest(three_per_run,
               (1..3).map { |n| example_spec(name: flaky, outcome: "passed", line_number: n) },
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(one_per_run, unstable_test: flaky)
      expect(commit_hrefs.size).to eq(3)
      few_rows = count_queries { get repository_path(one_per_run, unstable_test: flaky) }

      get repository_path(three_per_run, unstable_test: flaky)
      expect(commit_hrefs.size).to eq(9)
      many_rows = count_queries { get repository_path(three_per_run, unstable_test: flaky) }

      expect(many_rows).to eq(few_rows)
    end
  end

  # WHERE THE TEST RAN IN EACH RUN, as a link — the reading the four sibling per-example panels
  # cannot make. They list one run's rows and pin every link to the page-level sha; these rows each
  # carry their own run, and the identity rule is semantic, so the coordinate is allowed to change
  # down the list and each link has to be pinned to the commit that actually ran that example.
  describe "where the test was defined in each run" do
    # THE assertion that separates per-run pinning from the page-level pinning it would be copied
    # from. Both render the same visible coordinate on every row; only the ref inside the href
    # differs, and a single-sha fixture makes the two byte-identical — so this reads TWO rows at TWO
    # commits and asserts each href carries its OWN row's sha.
    it "pins each row's coordinate to the commit that ran it" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(definition_site_sequence).to eq(["spec/models/invoice_spec.rb:1"] * 2)
      expect(definition_site_hrefs).to eq(
        ["https://github.com/acme/checkout/blob/#{sha_for(0)}/spec/models/invoice_spec.rb#L1",
         "https://github.com/acme/checkout/blob/#{sha_for(1)}/spec/models/invoice_spec.rb#L1"]
      )
      expect(definition_site_hrefs.uniq.size).to eq(2)
    end

    # The case the per-run pinning exists FOR: a test that moved. Under the semantic identity rule
    # it is the same test and keeps its history, so the two rows are one sequence — and each of them
    # links to the file it lived in at its own commit. A page-level sha would send the older row's
    # link to a path that did not exist yet at that ref.
    it "follows a test that moved, path and commit together" do
      repository = create_repository(user: @user)
      [["spec/models/invoice_spec.rb", 1], ["spec/models/billing/invoice_spec.rb", 44]]
        .each_with_index do |(file_path, line_number), index|
          ingest(repository,
                 [example_spec(name: flaky, outcome: "passed", file_path: file_path,
                               line_number: line_number)],
                 commit_sha: sha_for(index), at: (30 - index).days.ago)
        end

      get repository_path(repository, unstable_test: flaky)

      expect(definition_site_sequence).to eq(["spec/models/invoice_spec.rb:1",
                                              "spec/models/billing/invoice_spec.rb:44"])
      expect(definition_site_hrefs.first).to end_with("#{sha_for(0)}/spec/models/invoice_spec.rb#L1")
      expect(definition_site_hrefs.last)
        .to end_with("#{sha_for(1)}/spec/models/billing/invoice_spec.rb#L44")
    end

    # The coordinate is `file_path` + `line_number`, NEVER `spec_file_path` + `line_number`.
    # `spec_file_path` is the *including* file and differs from `file_path` only for a shared example
    # group — which is exactly the case where the line number describes a line in the OTHER file, so
    # the forbidden pairing prints a coordinate whose halves come from two files and links at
    # whatever happens to sit on that line of the including one. The two files here disagree in both
    # halves, so a view built from the wrong one cannot pass.
    it "builds the coordinate from the definition site and not from the including file" do
      repository = create_repository(user: @user)
      2.times do |index|
        ingest(repository,
               [example_spec(name: flaky, outcome: "passed",
                             file_path: "spec/support/shared/behaves_like_lockable.rb",
                             line_number: 12, spec_file_path: "spec/models/invoice_spec.rb")],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(definition_site_sequence.uniq)
        .to eq(["spec/support/shared/behaves_like_lockable.rb:12"])
      expect(definition_site_hrefs.first)
        .to end_with("/spec/support/shared/behaves_like_lockable.rb#L12")
      expect(definition_site_hrefs.first).not_to include("invoice_spec")
    end

    # A row whose coordinate has a missing half renders NOTHING — not a bare ":" that reads as a
    # coordinate, and not `…/blob/<sha>/#L1`, which resolves to the repository root and so looks like
    # a link that worked. Asserted BESIDE a row that does have one, so this cannot pass over a
    # column that failed to render at all.
    it "renders no coordinate and no link for a row with no definition site" do
      repository = create_repository(user: @user)
      ["spec/models/invoice_spec.rb", ""].each_with_index do |file_path, index|
        ingest(repository,
               [example_spec(name: flaky, outcome: "passed", file_path: file_path, line_number: 1)],
               commit_sha: sha_for(index), at: (30 - index).days.ago)
      end

      get repository_path(repository, unstable_test: flaky)

      expect(definition_site_sequence).to eq(["spec/models/invoice_spec.rb:1", ""])
      expect(definition_site_hrefs.size).to eq(1)
      expect(panel.all("tbody tr").last.all("td")[1]).to have_no_css("a")
    end

    # And the caption names the rule, because a path that changes down a list of ONE test's runs
    # reads as two tests to anyone who does not know identity here is semantic.
    it "says a coordinate that changes down the list is the identity rule working" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository, unstable_test: flaky)

      expect(basis_line).to have_text("A definition site that CHANGES down this list is the " \
                                      "identity rule working", normalize_ws: true)
      expect(basis_line).to have_text("not two different tests sharing a description",
                                      normalize_ws: true)
    end
  end

  # Criterion 6 — ONE added read when asked and none when not, bounded by ONE DESCRIPTION'S rows over
  # the window rather than by the suite.
  #
  # `queries_against` comes from spec/support/query_capture.rb. A count alone would false-ACCEPT a
  # read that got slower without getting more numerous, so the constancy example beside the budget
  # varies the size of the SUITE — the axis this read must not grow along — and holds the window
  # fixed.
  describe "what the panel costs" do
    def repository_with_suite(example_count, name:)
      repository = create_repository(user: @user, github_full_name: name)
      3.times do |index|
        specs = (1..example_count).map do |i|
          example_spec(name: "example number #{i}", outcome: "passed", line_number: i,
                       file_path: "spec/models/bulk_spec.rb")
        end
        specs << example_spec(name: flaky, outcome: index == 1 ? "failed" : "passed")
        ingest(repository, specs, commit_sha: sha_for(index), at: (30 - index).days.ago)
      end
      repository
    end

    # NAMED BY GRAIN rather than only counted. `unstable_test_runs_grain_reads` classifies a read of
    # `spec_observations` by the SQL only that read can produce (spec/support/observation_grain_reads.rb
    # — written for the API specs, and reusable here because the partition is over statements rather
    # than over endpoints). A bare total cannot tell "this drill-in read once" from "some other panel
    # read twice while this one read none", which is exactly the false accept a count is prone to.
    it "issues exactly one read of its own grain when asked, and none when not" do
      repository = repository_with(%w[passed failed passed])

      expect(unstable_test_runs_grain_reads { get repository_path(repository) }).to be_empty
      expect(unstable_test_runs_grain_reads do
        get repository_path(repository, unstable_test: flaky)
      end.length).to eq(1)
      # And it fires on an ask that matched nothing too — the gate is the ASK, decided before any
      # read, so an empty answer costs the read that established it was empty rather than being
      # skipped by a predicate the page cannot evaluate without asking.
      expect(unstable_test_runs_grain_reads do
        get repository_path(repository, unstable_test: "renamed since")
      end.length).to eq(1)
    end

    # The panel ABOVE is not re-read, and neither is the WINDOW. `UnstableTestRuns` is handed the
    # same `trajectory_runs` local the chart and the ranking are drawn on, and its own invariant
    # says why that matters beyond economy: these rows are read for their POSITION against commits
    # the panels above already printed, so a second fetch would put an off-by-one between the
    # sequence and the commits it is read against — and naming the wrong culprit commit is worse
    # than naming none. Pinned on `test_runs`, the table a re-fetched window would have to touch.
    it "re-reads neither the window nor the ranking it drills out of" do
      repository = repository_with(%w[passed failed passed])

      unopened_runs = queries_against("test_runs") { get repository_path(repository) }
      unopened_flakiness = flakiness_grain_reads { get repository_path(repository) }
      opened_runs = queries_against("test_runs") do
        get repository_path(repository, unstable_test: flaky)
      end
      opened_flakiness = flakiness_grain_reads do
        get repository_path(repository, unstable_test: flaky)
      end

      expect(unopened_flakiness).not_to be_empty
      expect(opened_runs.size).to eq(unopened_runs.size)
      expect(opened_flakiness.length).to eq(unopened_flakiness.length)
    end

    # The whole drill-in is off the default page's budget: a reader who never opens a test pays
    # exactly what they paid before this panel existed.
    it "adds exactly one read when a test is asked for and none when it is not" do
      repository = repository_with(%w[passed failed passed])

      opened = queries_against("spec_observations") do
        get repository_path(repository, unstable_test: flaky)
      end
      # Read BEFORE the second request replaces the response: a budget example whose subject set is
      # empty passes on a page that rendered no panel at all, which is the shape this pair of
      # captures is least able to notice.
      listed = rows
      unopened = queries_against("spec_observations") { get repository_path(repository) }

      expect(listed).not_to be_empty
      expect(panel?).to be(false)
      expect(opened.size).to eq(unopened.size + 1)
    end

    # And that one read does not grow with the suite. A `select` over the window's rows filtered in
    # Ruby is exactly the shape that ships green on a three-row fixture and takes the page down on a
    # real one.
    it "costs the same on a 60-example suite as on a 3-example one" do
      small = repository_with_suite(3, name: "acme/small-suite")
      large = repository_with_suite(60, name: "acme/large-suite")

      small_queries = queries_against("spec_observations") do
        get repository_path(small, unstable_test: flaky)
      end
      large_queries = queries_against("spec_observations") do
        get repository_path(large, unstable_test: flaky)
      end

      expect(rows.size).to eq(3)
      expect(large_queries.size).to eq(small_queries.size)
    end
  end
end
