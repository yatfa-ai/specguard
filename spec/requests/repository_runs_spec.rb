# frozen_string_literal: true

require "rails_helper"

# The "Recent runs" panel on repositories#show — the first read surface over the append-only
# `test_runs` history. Everything the panel renders comes off columns ingestion populates on every
# run, so these examples build runs directly rather than posting to /ingest: the write side has its
# own file (spec/requests/api/v1/ingest_spec.rb) and this slice does not touch it.
#
# Deliberately its own file rather than more examples in spec/requests/repositories_spec.rb, which
# is the API-keys file and is being edited by a sibling slice.
RSpec.describe "Repository recent runs", type: :request do
  before { @user = sign_in_via_github }

  # Scoped to the panel's own anchor: the page renders two tables, and an unscoped `find("table")`
  # is exactly the ambiguity this slice had to fix in the API-keys file.
  def runs_table = Capybara.string(response.body).find("#recent-runs table")

  def run_headers = runs_table.all("thead th").map(&:text)

  def run_row(commit) = runs_table.find("tbody tr", text: commit)

  # Cell-level, not row-level, and that is load-bearing. Several cells share the "not reported"
  # wording, so a row-level `have_text("not reported")` for the duration is satisfied by a nil
  # *branch* in the same row — it passes with the duration column deleted. Verified by mutation:
  # forcing nil duration down the numeric branch leaves the row assertion green and only the
  # indexed one red. Indices follow the header order asserted below.
  COMMIT, BRANCH, TESTS, DURATION, ANNOTATED, AGE = (0..5).to_a

  # Whitespace-collapsed, because the `Tests` cell is now two lines — the figure and the
  # composition sentence beneath it — and ERB indentation would otherwise be part of every
  # assertion on it. `Capybara::Node::Simple#text` does no normalising of its own. Every other cell
  # holds a single token, so collapsing changes nothing about what they assert.
  def run_cells(commit) = run_row(commit).all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

  def runs_panel = Capybara.string(response.body).find("#recent-runs")

  # `count_queries` comes from spec/support/query_capture.rb. Two blocks below hold a query-budget
  # example — the composition sub-line's and the duration coverage's — and they pin the same panel's
  # budget against the same N+1 shape, so they must agree on what a query is.

  it "lists a run's commit, branch, suite size, duration, annotation share and age" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "a1b2c3d4e5f6", branch: "main", total_specs_count: 3,
                                 annotated_specs_count: 2, duration_seconds: 12.5)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(run_headers).to eq(["Commit", "Branch", "Tests", "Duration", "Annotated", "Ingested"])

    cells = run_cells("a1b2c3d")
    expect(cells[COMMIT]).to eq("a1b2c3d")
    expect(cells[BRANCH]).to eq("main")
    # The composition rides INSIDE the `Tests` cell rather than in a seventh column, which is why
    # the header assertion above is untouched and the indices below still mean what they meant.
    # A run that named no `ci_run_id` records no shard rows at all, so this is the whole unsharded
    # corpus and it must not read as a delivery that lost all its parts — `shard_count` is 0 here,
    # not 1, and a hand-rolled "0 shards" is exactly the wording this pins against.
    expect(cells[TESTS]).to eq("3 reported in one piece")
    expect(cells[DURATION]).to eq("12.5s")
    # A reported duration must NOT wear the muted treatment this table gives absent facts.
    expect(run_row("a1b2c3d").all("td")[DURATION]).to have_css("span:not(.text-app-muted)", text: "12.5s")
    # The PERCENTAGE, not the 0–1 fraction /ingest reports. 2/3 is 66.7%, and 0.667 rendered here
    # would be wrong by two orders of magnitude — the exact confusion TestRun's two methods exist
    # to prevent.
    expect(cells[ANNOTATED]).to eq("66.7%")
    expect(cells[AGE]).to match(/ago\z/)
  end

  it "renders the newest run first" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "oldrun0", created_at: 2.days.ago, total_specs_count: 1)
    repository.test_runs.create!(commit_sha: "newrun0", created_at: 1.hour.ago, total_specs_count: 1)

    get repository_path(repository)

    expect(runs_table.all("tbody tr").first).to have_text("newrun0")
  end

  # Honest state 1. "The client sent no timing" and "the run took no time" are different facts, and
  # `0.0s` renders them identically.
  it "says a run reported no duration rather than showing it as 0.0s" do
    repository = create_repository(user: @user)
    # A branch IS set here on purpose: with `branch: nil` the row also prints "not reported" in
    # the branch cell, and a row-level assertion would pass with the duration column deleted.
    repository.test_runs.create!(commit_sha: "notimed", branch: "main", total_specs_count: 4,
                                 annotated_specs_count: 1, duration_seconds: nil)

    get repository_path(repository)

    cells = run_cells("notimed")
    expect(cells[DURATION]).to eq("not reported")
    # Neither `0.0s` nor a silently blank cell: an omitted timing is a fact worth naming.
    expect(cells[DURATION]).not_to eq("0.0s")
    expect(cells[DURATION]).not_to be_empty
    # The wording's other half. Since SPGD-152 both this cell and the Overview panel's runtime
    # figure render through one helper, so the muted tone is now a shared authority — unpinned, a
    # single edit there would strip it from both surfaces silently. Cell-scoped for the reason
    # stated at the top of this file: the branch cell wears the same treatment for the same reason.
    expect(run_row("notimed").all("td")[DURATION]).to have_css("span.text-app-muted", text: "not reported")
    # The rest of the row is unaffected by the missing timing.
    expect(cells[ANNOTATED]).to eq("25.0%")
  end

  # Honest state 3. `TestRun#annotated_ratio` floors at 0.0 by guard when there is no denominator;
  # printed beside real percentages that reads as a suite measured at zero annotations.
  it "does not print 0% for a run that reported no tests at all" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "emptyrn", branch: "main", total_specs_count: 0,
                                 annotated_specs_count: 0, duration_seconds: 2.0)

    get repository_path(repository)

    cells = run_cells("emptyrn")
    expect(cells[ANNOTATED]).to eq("no tests")
    expect(cells[ANNOTATED]).not_to eq("0.0%")
  end

  it "says a run reported no branch rather than leaving the cell blank" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "nobranc", branch: nil, total_specs_count: 2,
                                 annotated_specs_count: 1, duration_seconds: 1.0)

    get repository_path(repository)

    cells = run_cells("nobranc")
    expect(cells[BRANCH]).to eq("not reported")
    expect(cells[DURATION]).to eq("1.0s")
  end

  # Honest state 2. An empty table with a header row would say "we looked and there is nothing",
  # which is true — but a repository that has never ingested has a different thing to be told.
  it "renders an empty state, not an empty table, when nothing has been ingested" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(runs_panel).to have_text("No runs yet")
    expect(runs_panel).to have_no_selector("table")
  end

  it "shows at most ten runs" do
    repository = create_repository(user: @user)
    12.times { |i| repository.test_runs.create!(commit_sha: "sha000#{i}", created_at: i.hours.ago) }

    get repository_path(repository)

    expect(runs_table.all("tbody tr").size).to eq(10)
  end

  # This is the example that makes the `#api-keys` / `#recent-runs` scoping load-bearing, and it
  # is here on purpose. The page now renders two tables, but only for a repository that has BOTH a
  # key and a run — and no example in spec/requests/repositories_spec.rb creates a run, which is
  # why the bare `find("table")` there was still passing when this slice was written. The breakage
  # was latent, not immediate: it was waiting for the first example to hold both. Verified by
  # probe — with an unscoped finder, this exact fixture raises Capybara::Ambiguous.
  it "coexists with the API keys table, each separately addressable" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")
    repository.test_runs.create!(commit_sha: "bothtwo", total_specs_count: 2, annotated_specs_count: 1)

    get repository_path(repository)

    page = Capybara.string(response.body)
    expect(page.all("table").size).to eq(2)
    expect(page.find("#recent-runs table")).to have_text("bothtwo").and have_no_text("CI")
    expect(page.find("#api-keys table")).to have_text("CI").and have_no_text("bothtwo")
  end

  it "does not list another repository's runs" do
    repository = create_repository(user: @user)
    other = create_repository(user: create_user(github_uid: "3003", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    other.test_runs.create!(commit_sha: "foreign", total_specs_count: 5)

    get repository_path(repository)

    expect(response.body).not_to include("foreign")
  end

  # The panel is suite telemetry, not credential metadata and not a control — so it sits outside
  # the `keys.manage` gate, exactly like the connection-health stat above it. For a `view` member
  # the API-keys panel is absent entirely, which makes this the page's only table.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "shared1", branch: "main", total_specs_count: 8,
                                 annotated_specs_count: 4, duration_seconds: 3.0)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(run_row("shared1")).to have_text("50.0%").and have_text("main")
  end

  # Honest state 4, and the one this table got wrong for longest. `total_specs_count` is the SUM
  # over the shards recorded SO FAR — see `TestRun`'s own comment — so on a sharded run it is not a
  # suite size, and this is the one surface that renders it as a column ordered by time.
  describe "how each run was assembled" do
    # The project's canonical fixture shape (spec/requests/api/v1/ingest_spec.rb): a 20,000-example
    # suite delivered four ways. `total_specs_count` is set to what the shards recorded so far,
    # which is what `Ingest::RunRecorder#recompute_totals` would have derived after that many
    # ingests.
    def sharded_run(repository, commit:, shards:, per_shard: 5_000, **attributes)
      run = repository.test_runs.create!(commit_sha: commit, branch: "main", ci_run_id: commit,
                                         total_specs_count: shards * per_shard,
                                         annotated_specs_count: shards * (per_shard / 2),
                                         **attributes)
      shards.times { |i| run.test_run_shards.create!(shard_id: i.to_s, total_specs_count: per_shard) }
      run
    end

    it "says a multi-shard run's figure covers the shards reported so far" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit: "inflig2", shards: 2)

      get repository_path(repository)

      cell = run_cells("inflig2")[TESTS]
      # The figure survives — a level is a true statement about what was reported, and withholding
      # it is not what this asks for.
      expect(cell).to include("10,000")
      # `TestRun#delivery_description`'s wording, reused rather than re-spelled: the Overview panel
      # settles it, and two spellings of one fact is how the two surfaces would drift apart.
      expect(cell).to include("assembled from 2 shard reports")
      # And the qualification that makes it not a whole-suite size. Readable from the row alone.
      # The full literal, not just the tail: the clause inflects now ("covers those" vs "covers
      # that report"), so asserting only "not necessarily the whole suite" would stay green with
      # the ternary swapped and leave this surface's multi-shard wording pinned nowhere.
      expect(cell).to include("the count above covers those, not necessarily the whole suite")
    end

    it "inflects a single shard report rather than printing '1 shard reports'" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit: "one1shd", shards: 1)

      get repository_path(repository)

      expect(run_cells("one1shd")[TESTS]).to include("assembled from 1 shard report")
      # And it still discloses its coverage. A one-shard row is not a whole report — it is the most
      # understated row there is, a four-way split whose first POST has landed, printing a quarter
      # of its suite. The predicate is `shard_count.positive?` for exactly that reason;
      # `multi_shard?` would go silent on a larger gap than the two-shard row it does warn about.
      # The clause inflects with the count: "covers those" would promise more reports than the
      # phrase before it just named.
      expect(run_cells("one1shd")[TESTS]).to include(
        "the count above covers that report, not necessarily the whole suite"
      )
    end

    it "says an unsharded run arrived in one piece, never as '0 shards'" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "laptop0", branch: "main", total_specs_count: 12,
                                   annotated_specs_count: 6)

      get repository_path(repository)

      expect(run_cells("laptop0")[TESTS]).to eq("12 reported in one piece")
      expect(run_cells("laptop0")[TESTS]).not_to include("0 shard")
    end

    it "states the composition of every row, sharded and not, in the same table" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit: "mixshrd", shards: 4, created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "mixwhol", branch: "main", total_specs_count: 20_000,
                                   created_at: 1.hour.ago)

      get repository_path(repository)

      # Both rows print a five-figure count. Without the composition beneath them a reader has no
      # way to tell that only one of the two measured a whole suite.
      expect(run_cells("mixwhol")[TESTS]).to eq("20,000 reported in one piece")
      expect(run_cells("mixshrd")[TESTS]).to include("assembled from 4 shard reports")
    end

    # Criterion 4 from the ticket: the existing honest states are untouched by the addition. A run
    # that reported nothing still says so in the Annotated cell, and it still states its own
    # composition — "no tests" is a fact about the report, and how the report arrived is another.
    it "leaves the 'no tests' treatment alone" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "emptyc0", branch: "main", total_specs_count: 0,
                                   annotated_specs_count: 0, duration_seconds: 2.0)

      get repository_path(repository)

      cells = run_cells("emptyc0")
      expect(cells[ANNOTATED]).to eq("no tests")
      expect(cells[TESTS]).to eq("0 reported in one piece")
    end

    # The N+1 this pins is a ten-query one that would ship green: every route to a run's
    # composition — `shard_count`, `multi_shard?`, `delivery_description` — goes through a memoized
    # per-INSTANCE `pick`, so calling any of them in the row loop costs one query per row. The
    # page's other query-budget example (spec/requests/repositories_spec.rb) is the API-keys one
    # and its fixture creates no runs at all, so nothing caught this before.
    #
    # Verified by mutation: dropping `preload_shard_counts` from the controller — leaving the view
    # to ask each row itself — turns this example red by exactly the four sharded rows added below,
    # and leaves every other example in this file green.
    it "asks how the rows were assembled once for the whole panel, not once per row" do
      repository = create_repository(user: @user)
      # The newest row is a plain run in BOTH measurements, deliberately: the Overview panel above
      # reads `latest_test_run` and its predecessor on the same branch through their own unprimed
      # shard aggregates, so holding those two rows fixed keeps it in an identical state either side
      # of the change and stops it absorbing or masking a difference belonging to this panel.
      3.times do |i|
        repository.test_runs.create!(commit_sha: "plainrun000#{i}", branch: "main",
                                     total_specs_count: 100, created_at: (i + 1).hours.ago)
      end

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(runs_table.all("tbody tr").size).to eq(3)

      # Four sharded runs and sixteen shard rows, all older than the newest plain run.
      4.times { |i| sharded_run(repository, commit: "shrdrn#{i}", shards: 4, created_at: (i + 4).hours.ago) }

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      expect(runs_table.all("tbody tr").size).to eq(7)
      expect(run_cells("shrdrn0")[TESTS]).to include("assembled from 4 shard reports")
    end
  end

  # Honest state 5, and the same defect one column over. `test_runs.duration_seconds` is the MAX
  # over the run's shards (`Ingest::RunRecorder#recompute_totals`), `test_run_shards.duration_seconds`
  # is nullable, and SQL's `MAX` skips NULLs — so a run where a shard went silent prints a maximum
  # over a SUBSET in the same type and the same words as a complete one. The bias runs one way: the
  # silent shard is disproportionately the slow one, because it is the job still running when it is
  # cancelled or times out, so an unqualified column shows a reader a speedup made of telemetry loss.
  describe "what each duration was measured over" do
    # The TIMED sibling of the composition block's `sharded_run` above, and deliberately a second
    # helper rather than an option on it: that one writes shard rows with no `duration_seconds` and
    # passes none to the parent, which is exactly the nil-duration shape the last example here needs
    # left untouched.
    #
    # The parent's `duration_seconds` is DERIVED from the shards written below and never asserted
    # beside them — the MAX over the ones that reported, which is what `#recompute_totals` re-derives
    # after every ingest. A fixture that set it independently could build the one run this column
    # cannot have: a wall clock no shard measured.
    def timed_sharded_run(repository, durations, commit:, per_shard: 5_000, **attributes)
      run = repository.test_runs.create!(commit_sha: commit, branch: "main", ci_run_id: commit,
                                         total_specs_count: durations.length * per_shard,
                                         annotated_specs_count: durations.length * (per_shard / 2),
                                         duration_seconds: durations.compact.max, **attributes)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: index.to_s, total_specs_count: per_shard,
                                    duration_seconds: seconds)
      end
      run
    end

    # The project's canonical four-shard fixture, whole: 74.25s is the MAX and the run's wall clock.
    it "says a complete run's wall clock is the slowest of all its shards" do
      repository = create_repository(user: @user)
      timed_sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit: "allshrd")

      get repository_path(repository)

      # The figure itself is unchanged — the coverage qualifies it, it does not restate it.
      expect(run_cells("allshrd")[DURATION]).to eq("1m 14s slowest of 4 shards")
    end

    # The same run with its slowest shard silent instead of reported would print `1m 1s` here and
    # look like a 13-second improvement. What separates the two rows is this clause and nothing else.
    it "says a run with a silent shard was measured over only the shards that reported" do
      repository = create_repository(user: @user)
      timed_sharded_run(repository, [61.0, 58.5, 74.25, nil], commit: "silentx")

      get repository_path(repository)

      expect(run_cells("silentx")[DURATION]).to eq("1m 14s slowest of the 3 that reported")
      # And the qualifier is a sub-line in the existing cell, not a seventh column: the header set
      # asserted at the top of this file is what a new column would break.
      expect(run_row("silentx").all("td")[DURATION])
        .to have_css("span.text-xs.text-app-muted", text: "slowest of the 3 that reported")
    end

    # The top row of this table IS the run the Overview panel names — `Repository#recent_test_runs`
    # shares `latest_test_run`'s ordering including the tie-break, and the controller loads both off
    # the one repository. So this page renders one float twice, and before this slice it worded it
    # two ways: qualified above, bare below. ONE literal, asserted on both surfaces, so neither can
    # be re-worded without the other.
    it "words the top row's coverage exactly as the Overview panel words the same run" do
      repository = create_repository(user: @user)
      timed_sharded_run(repository, [61.0, 58.5, 74.25, nil], commit: "toprow0")

      get repository_path(repository)

      coverage = "slowest of the 3 that reported"
      expect(runs_table.all("tbody tr").first).to have_text("toprow0")
      expect(run_cells("toprow0")[DURATION]).to eq("1m 14s #{coverage}")
      expect(Capybara.string(response.body).find("#overview"))
        .to have_text("Wall clock (#{coverage}) 1m 14s", normalize_ws: true)
    end

    # Gated on `multi_shard?`, and NOT on the `shard_count.positive?` the Tests cell one column over
    # uses. That predicate is about the gap between the shards recorded and the shards the suite
    # has, which is a fact about a count; this is the MAX-vs-SUM rule, which belongs to durations.
    # One shard's MAX *is* its SUM, so there is no coverage to disclose and nothing to say.
    it "adds no qualifier to a one-shard run" do
      repository = create_repository(user: @user)
      timed_sharded_run(repository, [61.0], commit: "oneshrd")

      get repository_path(repository)

      expect(run_cells("oneshrd")[DURATION]).to eq("1m 1s")
    end

    # The load-bearing half of that gate. `some_shard_untimed?` is vacuously false at
    # `shard_count == 0` (`0 < 0`), so an ungated `wall_clock_coverage` would tell the ENTIRE
    # unsharded corpus — every run that named no `ci_run_id`, which is every laptop `rspec` — that
    # its wall clock was the "slowest of 0 shards".
    it "adds no qualifier to an unsharded run, and never says 'slowest of 0 shards'" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "laptop9", branch: "main", total_specs_count: 12,
                                   annotated_specs_count: 6, duration_seconds: 12.5)

      get repository_path(repository)

      expect(run_cells("laptop9")[DURATION]).to eq("12.5s")
      expect(run_cells("laptop9")[DURATION]).not_to include("shard")
    end

    # `duration_seconds` is nullable independently of the shard rows, so the two conditions are
    # separate: this run is sharded — it has a coverage to state — and has no figure to state it
    # about. A denominator printed beside "not reported" is worse than neither, and the string it
    # would print here is `0 of 4 reported`.
    it "prints no coverage beside a duration that does not exist" do
      repository = create_repository(user: @user)
      timed_sharded_run(repository, [nil, nil, nil, nil], commit: "notimd0")

      get repository_path(repository)

      expect(run_cells("notimd0")[DURATION]).to eq("not reported")
      # Named as the literal that branch would print, so this stays red for the right reason if the
      # gate is dropped rather than merely for the cell being longer than expected.
      expect(run_cells("notimd0")[DURATION]).not_to include("0 of 4 reported")
      # And the absent figure keeps the muted treatment this table gives absent facts.
      expect(run_row("notimd0").all("td")[DURATION]).to have_css("span.text-app-muted", text: "not reported")
    end

    # The mechanical proof the qualifier is free. Its sibling in the block above pins the same
    # budget against the composition sub-line, and cannot see this one: its fixture's shards carry
    # no `duration_seconds` and its parents carry none either, so `duration_reported?` is false on
    # every row and `wall_clock_coverage` — the only reader of `timed_shard_count` here — is never
    # called at all. This fixture is timed, so it is.
    #
    # Verified by mutation: dropping `.preload_timed_shard_count(timed_count)` from
    # `ShardCountPreloading#preload_shard_counts` turns this example red by exactly the four sharded
    # rows added below, and leaves the composition block's budget example green.
    it "asks what each duration covered once for the whole panel, not once per row" do
      repository = create_repository(user: @user)
      # The newest row is a plain run in BOTH measurements, for the reason its sibling states: the
      # Overview panel reads `latest_test_run` and its predecessor through their own unprimed shard
      # aggregates, so holding those rows fixed keeps it identical either side of the change.
      3.times do |i|
        repository.test_runs.create!(commit_sha: "plainrun000#{i}", branch: "main",
                                     total_specs_count: 100, duration_seconds: 9.0,
                                     created_at: (i + 1).hours.ago)
      end

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(runs_table.all("tbody tr").size).to eq(3)

      4.times do |i|
        timed_sharded_run(repository, [61.0, 58.5, 74.25, nil], commit: "timdrn#{i}",
                          created_at: (i + 4).hours.ago)
      end

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      expect(runs_table.all("tbody tr").size).to eq(7)
      expect(run_cells("timdrn0")[DURATION]).to eq("1m 14s slowest of the 3 that reported")
    end
  end

  # The panel's own shape is what a time-ordered column of numbers misleads a reader about, and the
  # codebase has written the argument down twice — `Repository#previous_test_run_on_branch` exists
  # so the Overview never differences two rows of this history. This panel prints the operands, so
  # it says what they are.
  describe "what the list is" do
    def caption = Capybara.string(response.body).find("#recent-runs-basis")

    it "says the list is every branch interleaved and not a series" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "capshown", branch: "main", total_specs_count: 5)

      get repository_path(repository)

      # Three claims, each load-bearing on its own: what the rows are drawn from, what order they
      # are in, and — the point of the other two — that subtracting one from another measures
      # nothing.
      expect(caption).to have_text("every branch CI reports from")
      expect(caption).to have_text("newest first")
      expect(caption.text).to include("not a change in the suite")
    end

    # The caption is only a precondition for readers who meet it on the way to the rows. This pins
    # the association that carries it to a reader who arrives at the table directly — without it
    # the paragraph above is, for them, not on the page at all.
    #
    # The other half of the seam's contract — that a table with no caption to point at emits no
    # attribute AT ALL, rather than `aria-describedby=""` — is pinned at the component, in
    # spec/components/ui/table_component_spec.rb: both branches are reachable there without
    # dragging the API-keys panel's fixtures into this file.
    it "points the table at the caption, so a reader landing on the rows still gets it" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "wiredup", branch: "main", total_specs_count: 5)

      get repository_path(repository)

      table = runs_panel.find("table")
      expect(table[:"aria-describedby"]).to eq("recent-runs-basis")
      # The id has to resolve, or the attribute is a reference to nothing — which announces exactly
      # as much as having no attribute while looking, in the markup, like the defect is fixed.
      expect(caption[:id]).to eq(table[:"aria-describedby"])
    end

    it "does not caption an empty state, which has no rows to explain" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(runs_panel).to have_text("No runs yet")
      expect(runs_panel).to have_no_selector("#recent-runs-basis")
    end
  end
end
