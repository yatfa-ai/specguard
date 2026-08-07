# frozen_string_literal: true

require "rails_helper"

# The suite-size delta on the Overview panel — the first figure SpecGuard renders off *two* rows of
# `test_runs` rather than one. Everything else on that panel is a level, and a level cannot say
# whether 20,013 tests is 47 more than yesterday or 400 fewer.
#
# Its own file rather than more examples in the Overview block of spec/requests/repositories_spec.rb
# for the reason spec/requests/repository_runs_spec.rb states for itself: that file is the
# API-keys/Overview file and is edited by sibling slices, and every example here needs the same
# two-runs-on-a-branch setup.
#
# Runs are built directly rather than posted to /ingest wherever the question is only about
# branches and counts: the write side has its own file (spec/requests/api/v1/ingest_spec.rb) and
# this slice does not touch it.
#
# The sharded examples are the exception, and deliberately so. The defect they guard against is a
# shape `Ingest::RunRecorder` produces — `total_specs_count` re-derived as the SUM over the shards
# recorded SO FAR — so those runs are built by driving the recorder rather than by writing the row
# and its shards by hand. A fixture can trivially build a half-delivered run that agrees with
# itself in ways a real one never does, which is the trap `SPGD-91` names: the earlier revision of
# this file created every run with a bare `test_runs.create!`, left `shard_count` at 0 in all
# fourteen examples, and was green while the panel rendered a −14,990 on every in-flight CI run.
RSpec.describe "Repository suite-size growth", type: :request do
  before { @user = sign_in_via_github }

  def overview_panel = Capybara.string(response.body).find("#overview")

  # ELEMENT-scoped, never panel-scoped, and that is load-bearing — the same trap
  # spec/requests/repository_runs_spec.rb:23-30 documents from a verified mutation, one surface
  # over. Five states here produce a no-delta panel and several of them share words ("no earlier
  # run", "reported no tests"); a panel-level `have_text` therefore passes for the wrong state with
  # the deciding check deleted. Every assertion below names the element it means.
  def delta_figure = overview_panel.find("#suite-size-delta")

  def basis_line = overview_panel.find("#suite-size-basis")

  # The "Tests in suite" cell itself, so "the delta rendered" can never be satisfied by the figure
  # having drifted into some other row of the def list.
  def suite_size_cell
    overview_panel.find(:xpath, ".//dt[normalize-space()='Tests in suite']/following-sibling::dd[1]")
  end

  # One shard of one run, through the producer. Every sharded fixture below is a sequence of these,
  # so a run that has delivered 1 of 4 shards is built the way CI builds it: by having posted once.
  def ingest_shard(repository, ci_run_id:, shard_id:, total:, commit_sha:, branch: "main")
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, ci_run_id: ci_run_id,
        total_specs_count: total, annotated_specs_count: total / 4, duration_seconds: 60.0 },
      shard_id: shard_id
    )
  end

  # A complete four-shard run of `4 × per_shard` examples.
  def complete_sharded_run(repository, commit_sha:, per_shard: 5_000, shards: 4)
    shards.times do |i|
      ingest_shard(repository, ci_run_id: "gha-#{commit_sha}", shard_id: i.to_s,
                   total: per_shard, commit_sha: commit_sha)
    end
    repository.test_runs.find_by!(ci_run_id: "gha-#{commit_sha}")
  end

  def grew_by_47(repository)
    repository.test_runs.create!(commit_sha: "a1b2c3d4e5f6", branch: "main", total_specs_count: 1_000,
                                 annotated_specs_count: 100, created_at: 3.hours.ago)
    repository.test_runs.create!(commit_sha: "fedcba987654", branch: "main", total_specs_count: 1_047,
                                 annotated_specs_count: 110, created_at: 1.minute.ago)
  end

  it "reports the suite grew, in the same cell as the size it changed" do
    repository = create_repository(user: @user)
    grew_by_47(repository)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(delta_figure.text).to eq("+47")
    # The level and the change are one statement, not two figures a reader has to relate.
    expect(suite_size_cell.text).to eq("1,047 +47")
  end

  it "names the run the change is measured against, and its age" do
    repository = create_repository(user: @user)
    grew_by_47(repository)

    get repository_path(repository)

    # A change with no stated basis is not a fact a reader can check. The short SHA, the branch it
    # is scoped to, and how old it is — all three on the surface, next to the number.
    expect(basis_line).to have_text("measured against a1b2c3d", normalize_ws: true)
    expect(basis_line).to have_text("the previous run on main", normalize_ws: true)
    expect(basis_line).to have_text("about 3 hours ago", normalize_ws: true)
    expect(basis_line).to have_text("Only runs on the same branch are compared", normalize_ws: true)
  end

  # Criterion 2, and the one that makes the figure a change rather than a magnitude: `400` beside a
  # suite size reads as a second, smaller count of something, not as 400 tests gone.
  it "renders a decrease signed, never as an unsigned magnitude" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "beforedelete", branch: "main", total_specs_count: 1_400,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "afterdeleted", branch: "main", total_specs_count: 1_000,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    expect(delta_figure.text).to eq("−400")
    expect(delta_figure.text).not_to eq("400")
    expect(delta_figure.text).not_to eq("+400")
    expect(suite_size_cell.text).to eq("1,000 −400")
  end

  # "Compared, and it did not move" is an answer, and a different one from "there was nothing to
  # compare against". Suppressing the figure here would make the two identical.
  it "says the suite did not move rather than falling silent" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "steady00000a", branch: "main", total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "steady00000b", branch: "main", total_specs_count: 1_000,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # `±0`, not `+0` — no change has no direction to claim.
    expect(delta_figure.text).to eq("±0")
    expect(basis_line).to have_text("measured against steady", normalize_ws: true)
  end

  # Criterion 3, and the reason the whole thing is branch-scoped. `test_runs` is one interleaved
  # history — the "Recent runs" table below lists it exactly that way — so the row immediately
  # before the latest is routinely another branch entirely.
  it "does not compare across branches, and says why there is no change to show" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "trunkrun0001", branch: "main", total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "featurerun01", branch: "feature/x", total_specs_count: 20,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # No delta at all — not a `−980` taken against a branch that never had those tests.
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(suite_size_cell.text).to eq("20")
    expect(basis_line).to have_text("No earlier run on feature/x", normalize_ws: true)
    # The run it must NOT have reached for. Asserted on the basis line specifically: "main" appears
    # elsewhere on this page in other repositories' fixtures and in the Recent-runs table below.
    expect(basis_line).to have_no_text("main", normalize_ws: true)
    # ...and it must not be reporting the *other* no-delta state instead.
    expect(basis_line).to have_no_text("reported no branch", normalize_ws: true)
  end

  it "says a branch's first run is its first run" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "firstever001", branch: "main", total_specs_count: 42)

    get repository_path(repository)

    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(basis_line).to have_text("No earlier run on main", normalize_ws: true)
    expect(basis_line).to have_text("first run SpecGuard has from that branch", normalize_ws: true)
  end

  # Criterion 4. A live state, not hypothetical: Ingest::Payload writes `branch` through
  # `.presence` and validates a missing one as acceptable. Distinct from "no earlier run on this
  # branch" because it is a different thing to go and fix — a CI client that is not sending a
  # branch, rather than a young branch.
  it "says a run that named no branch cannot be placed in a history" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "earlieranon", branch: nil, total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "latestanon0", branch: nil, total_specs_count: 1_047,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # Every anonymous run pooled under `branch IS NULL` would have made this a confident `+47`
    # across two runs that may have come from anywhere.
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(suite_size_cell.text).to eq("1,047")
    expect(basis_line).to have_text("reported no branch", normalize_ws: true)
    # The state-2 wording, which shares the "no earlier run" idea and must not stand in for this.
    expect(basis_line).to have_no_text("No earlier run on", normalize_ws: true)
  end

  # Criterion 5: the never-ingested empty state is untouched. Neither element exists — a basis line
  # explaining why there is no comparison would be a second, softer answer beside "no run at all".
  it "leaves the never-ingested empty state alone" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(overview_panel).to have_text("No CI run has reported yet", normalize_ws: true)
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(overview_panel).to have_no_css("#suite-size-basis")
  end

  # The tie-break, from the surface. The Overview and the Recent-runs table are read side by side,
  # so the run compared against has to be the row the table prints directly beneath the latest —
  # not an older one a looser `created_at <` would have skipped to.
  it "compares against the same-instant predecessor the runs table prints beneath the latest" do
    repository = create_repository(user: @user)
    at = 1.hour.ago
    repository.test_runs.create!(commit_sha: "olderrun0001", branch: "main", total_specs_count: 5,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "tiedfirst001", branch: "main", total_specs_count: 10,
                                 created_at: at)
    repository.test_runs.create!(commit_sha: "tiedsecond01", branch: "main", total_specs_count: 12,
                                 created_at: at)

    get repository_path(repository)

    expect(overview_panel).to have_text("Measured on tiedsec", normalize_ws: true)
    # +2 against its same-instant twin. Against the two-hours-ago run it would read +7.
    expect(delta_figure.text).to eq("+2")
    expect(basis_line).to have_text("measured against tiedfir", normalize_ws: true)
  end

  # == The coverage of each side of the subtraction
  #
  # A run's `total_specs_count` is not a suite size. `Ingest::RunRecorder#recompute_totals`
  # re-derives it as the SUM over the shards recorded so far after every ingest, so a sharded run
  # reads at a fraction of its own suite until its last shard lands — and `latest_test_run` picks
  # the row up on the FIRST one, because `created_at` is stamped by that POST.
  #
  # A level survives that. A difference does not: it is only worth as much as the weaker of the two
  # rows it is taken across, and this is the only state in this whole file that would produce a
  # wrong NUMBER rather than an honest absence.
  describe "when the two runs are not the same kind of measurement" do
    # The ordinary in-flight window of every sharded CI job — the state the Overview is in for most
    # of the twenty minutes anyone is looking at it during a build.
    it "withholds the change while a sharded run is still arriving" do
      repository = create_repository(user: @user)
      complete_sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_010,
                   commit_sha: "bbbbbbb22222")

      get repository_path(repository)

      # −14,990 is what this rendered before the guard: three quarters of the suite deleted by a
      # commit that deleted nothing, wearing a named SHA and an age.
      expect(overview_panel).to have_no_css("#suite-size-delta")
      expect(suite_size_cell.text).to eq("5,010")
      expect(basis_line).to have_no_text("14,990", normalize_ws: true)
    end

    # Both compositions named, so a reader can see for themselves which side is short rather than
    # being told only that something is wrong.
    it "names how each run was assembled when it declines to compare them" do
      repository = create_repository(user: @user)
      complete_sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_010,
                   commit_sha: "bbbbbbb22222")

      get repository_path(repository)

      expect(basis_line).to have_text("This run was assembled from 1 shard report", normalize_ws: true)
      expect(basis_line).to have_text("aaaaaaa was assembled from 4 shard reports", normalize_ws: true)
      # Not one of the four other no-delta wordings standing in for this one. Each names a
      # different fact and only this one is a build that will finish on its own.
      expect(basis_line).to have_no_text("No earlier run on", normalize_ws: true)
      expect(basis_line).to have_no_text("reported no branch", normalize_ws: true)
      expect(basis_line).to have_no_text("reported no tests", normalize_ws: true)
    end

    # The permanent form: a job cancelled after two of four shards leaves a half-sized row in the
    # history forever, and the next complete run would otherwise read the missing half as growth.
    it "withholds the change against a run that was cancelled part-way through" do
      repository = create_repository(user: @user)
      complete_sharded_run(repository, commit_sha: "ccccccc33333", per_shard: 5_000, shards: 2)
      complete_sharded_run(repository, commit_sha: "ddddddd44444", per_shard: 5_000, shards: 4)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#suite-size-delta")
      expect(suite_size_cell.text).to eq("20,000")
      expect(basis_line).to have_text("ccccccc was assembled from 2 shard reports", normalize_ws: true)
    end

    # The guard withholds, it does not disable. Two complete four-shard runs are the same kind of
    # measurement and the figure is exactly what it always was.
    it "still compares two runs assembled from the same number of shards" do
      repository = create_repository(user: @user)
      complete_sharded_run(repository, commit_sha: "eeeeeee55555", per_shard: 5_000)
      complete_sharded_run(repository, commit_sha: "fffffff66666", per_shard: 5_005)

      get repository_path(repository)

      expect(delta_figure.text).to eq("+20")
      expect(suite_size_cell.text).to eq("20,020 +20")
      # The delta's own coverage, on the surface beside it — the second half of the rule the branch
      # scope is the first half of.
      expect(basis_line).to have_text("only runs assembled from the same 4 shard reports",
                                      normalize_ws: true)
    end

    # The whole unsharded corpus — a laptop `bundle exec rspec`, an unrecognised CI provider. Those
    # rows are written once and never re-derived, so they were always comparable and the guard must
    # not have quietly switched the feature off for them. (Every other example in this file is one
    # of these; this one says so on purpose.)
    it "compares two runs that each arrived whole, as it always did" do
      repository = create_repository(user: @user)
      grew_by_47(repository)

      get repository_path(repository)

      expect(delta_figure.text).to eq("+47")
      # No shard clause: there is no composition to state, and inventing "the same 0 shard reports"
      # would describe the unsharded corpus as a delivery that lost everything.
      expect(basis_line).to have_no_text("shard report", normalize_ws: true)
    end
  end

  # The same question — *is either side of this subtraction a measurement of the whole suite?* —
  # asked of a count rather than of a composition. A run that reported zero tests has a count but
  # not a measurement, and the panel already says so in those words.
  describe "when a run reported no tests at all" do
    it "does not report the suite as having lost everything the latest run did not count" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "hadtests0001", branch: "main", total_specs_count: 1_000,
                                   created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "reportednone", branch: "main", total_specs_count: 0,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      # `0 −1,000` rendered immediately above the panel's own "reported no tests at all… That is a
      # fact about this run, not about the suite" — the page computing a change and then
      # disclaiming the figure it computed it from, in adjacent paragraphs.
      expect(overview_panel).to have_no_css("#suite-size-delta")
      expect(suite_size_cell.text).to eq("0")
      expect(basis_line).to have_text("This run reported no tests", normalize_ws: true)
      expect(overview_panel).to have_text("The latest run reported no tests at all", normalize_ws: true)
    end

    # The mirror, which is the same defect with its sign flipped: the whole suite charged to one
    # commit as growth because the run before it reported nothing.
    it "does not report the whole suite as growth when the previous run counted nothing" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "zeroprev0001", branch: "main", total_specs_count: 0,
                                   created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "hastests0002", branch: "main", total_specs_count: 1_000,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#suite-size-delta")
      expect(suite_size_cell.text).to eq("1,000")
      expect(basis_line).to have_text("previous run on main (zeropre) reported no tests",
                                      normalize_ws: true)
      # The other side's wording, which must not stand in for this one: this run counted 1,000.
      expect(basis_line).to have_no_text("This run reported no tests", normalize_ws: true)
    end

    # `total_specs_count` is nullable (default `0`, no `null: false`). A NULL on the previous run
    # would otherwise render the entire suite as growth.
    it "treats a NULL count as nothing reported rather than as a suite of zero" do
      repository = create_repository(user: @user)
      earlier = repository.test_runs.create!(commit_sha: "nullcount001", branch: "main",
                                             total_specs_count: 0, created_at: 2.hours.ago)
      earlier.update_columns(total_specs_count: nil)
      repository.test_runs.create!(commit_sha: "hastests0003", branch: "main", total_specs_count: 1_000,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#suite-size-delta")
      expect(basis_line).to have_text("reported no tests", normalize_ws: true)
    end
  end

  # The visible figure is three characters of typography doing a sentence's work. Neither half
  # survives being read aloud: the `dd` announces as "1,047 +47" with nothing tying the second
  # number to the first, and U+2212 — chosen precisely because it is not a hyphen — is announced
  # inconsistently across screen readers.
  describe "what the figure reads as aloud" do
    it "spells out an increase" do
      repository = create_repository(user: @user)
      grew_by_47(repository)

      get repository_path(repository)

      expect(delta_figure["aria-label"]).to eq("47 tests more than the previous run on this branch")
    end

    it "spells out a decrease as fewer, never as a bare magnitude" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "beforecut001", branch: "main", total_specs_count: 1_400,
                                   created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "aftercut0001", branch: "main", total_specs_count: 1_399,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      # Singular at one, because the noun is inflected rather than bolted on.
      expect(delta_figure["aria-label"]).to eq("1 test fewer than the previous run on this branch")
    end

    it "says a suite that did not move did not move" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "steadyaria01", branch: "main", total_specs_count: 1_000,
                                   created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "steadyaria02", branch: "main", total_specs_count: 1_000,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      expect(delta_figure["aria-label"]).to eq("unchanged since the previous run on this branch")
    end
  end

  # Criterion 6, from the page. The absolute "exactly one query" is asserted where it can be
  # measured honestly — around the model call itself, in spec/models/repository_spec.rb. It is NOT
  # asserted here, and that is deliberate: a page-versus-page difference has a control that walks
  # the same code path, so an implementation which re-read `latest_test_run` internally would
  # inflate both renders by one and leave the difference at 1. Verified by mutation — that
  # implementation keeps this file green and turns the model-level count red. What these two
  # examples can honestly hold is that the comparison adds no per-row work: it costs the same
  # whether it finds a predecessor or not, and the same however long the branch's history is.
  describe "what the comparison costs the page" do
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

    it "costs one query more when it finds a run to compare against — the coverage check on it" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "firstofbranch", branch: "main", total_specs_count: 10,
                                   created_at: 2.hours.ago)

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(overview_panel).to have_no_css("#suite-size-delta")

      # An earlier run appears on the same branch, so the lookup now returns a row and the page
      # renders the delta. A second lookup — or one per candidate — would show up here.
      repository.test_runs.first.update!(created_at: 3.hours.ago)
      repository.test_runs.create!(commit_sha: "secondofbrnch", branch: "main", total_specs_count: 12,
                                   created_at: 1.minute.ago)
      get repository_path(repository)

      # Exactly one, and it is named rather than absorbed: the shard aggregate on the comparison
      # run, which is what `TestRun#assembled_like?` reads and what stops the panel differencing
      # two rows of unequal coverage. The latest run's own aggregate is not new — the cost rows
      # already paid for it — and this one is bounded by a run's shard count, so the Overview stays
      # O(1) in suite size exactly as before.
      expect(count_queries { get repository_path(repository) }).to eq(baseline + 1)
      expect(delta_figure.text).to eq("+2")
    end

    it "costs the same however long the branch's history is" do
      repository = create_repository(user: @user)
      3.times do |i|
        repository.test_runs.create!(commit_sha: "history0000#{i}", branch: "main",
                                     total_specs_count: 10 + i, created_at: (5 - i).hours.ago)
      end

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }

      # A LIMIT 1 lookup does not care; anything that walked the history would.
      5.times do |i|
        repository.test_runs.create!(commit_sha: "more00000000#{i}", branch: "main",
                                     total_specs_count: 20 + i, created_at: (4 - i).minutes.ago)
      end

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
    end
  end

  # The panel sits outside the `keys.manage` gate — suite telemetry, not credential metadata — so
  # the delta does too. It is the same class of fact as the suite size it modifies.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    grew_by_47(repository)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(delta_figure.text).to eq("+47")
  end
end
