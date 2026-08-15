# frozen_string_literal: true

require "rails_helper"

# The "Suite growth" panel on repositories#show — the first surface SpecGuard renders off MANY rows
# of `test_runs` rather than one or two. The Overview above it can say "+47 since the last run"; it
# cannot say what the suite has done over the last month, and `test_runs` has held that answer
# since Phase 2.
#
# Its own file, for the reason spec/requests/repository_runs_spec.rb and
# spec/requests/repository_suite_growth_spec.rb each state for themselves: the Overview/API-keys
# file is edited by sibling slices, and every example here needs the same history-on-a-branch
# setup.
#
# The sharded examples drive `Ingest::RunRecorder` rather than writing rows and shards by hand,
# exactly as the suite-growth file does and for the same reason: the defect this panel exists to
# refuse is a shape the RECORDER produces — `total_specs_count` re-derived as the SUM over the
# shards recorded so far — and a hand-built fixture can trivially agree with itself in ways a real
# half-delivered run never does.
RSpec.describe "Repository suite-size trajectory", type: :request do
  before { @user = sign_in_via_github }

  def trajectory_panel = Capybara.string(response.body).find("#suite-trajectory")

  # ELEMENT-scoped, never panel-scoped — the trap spec/requests/repository_runs_spec.rb documents
  # from a verified mutation. Several states of this panel share words ("runs on main", "shard
  # reports"), so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted.
  def basis_line = trajectory_panel.find("#suite-trajectory-basis")

  # The SHAs in the basis line, named as ELEMENTS. This page renders an inline SHA monospaced
  # without exception, and that is what makes it legible as a SHA rather than as a word. Every
  # other assertion here goes through `have_text`, which discards markup — so a SHA that lost the
  # class would read identically green. Nothing else catches it either: `DesignSystemLint` counts
  # headings, raw palette colours and raw `btn`, not this.
  def basis_line_shas = basis_line.all("span.font-mono").map(&:text)

  def chart = trajectory_panel.find("#suite-trajectory-chart")

  def chart_summary = trajectory_panel.find("#suite-trajectory-chart-summary")

  # The plotted figures as the text alternative states them. `visible: :all` because they sit in a
  # collapsed `<details>` — a native disclosure, which Capybara treats as hidden exactly as a
  # browser does.
  def plotted_rows
    chart.all("details table tbody tr", visible: :all).map do |row|
      row.all("td", visible: :all).map { |cell| cell.text(:all).strip }
    end
  end

  def plotted_labels = plotted_rows.map(&:first)

  def run(repository, commit, branch: "main", total: 1_000, at: 1.hour.ago)
    repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                 annotated_specs_count: total / 4, created_at: at)
  end

  # One shard of one run, through the producer — the same seam the suite-growth file uses.
  #
  # `seconds` is a parameter and nil is a real value for it: `Ingest::Payload#validate_duration_seconds`
  # accepts nil explicitly, so a shard that was cancelled before it reported its clock is an ordinary
  # live state, and it is the state `duration_seconds` — a MAX over the shards that REPORTED —
  # silently reads as a faster build.
  def ingest_shard(repository, ci_run_id:, shard_id:, total:, commit_sha:, branch: "main", seconds: 60.0)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, ci_run_id: ci_run_id,
        total_specs_count: total, annotated_specs_count: total / 4, duration_seconds: seconds },
      shard_id: shard_id
    )
  end

  def sharded_run(repository, commit_sha:, per_shard: 5_000, shards: 4, seconds: 60.0, timed_shards: shards)
    shards.times do |i|
      ingest_shard(repository, ci_run_id: "gha-#{commit_sha}", shard_id: i.to_s,
                   total: per_shard, commit_sha: commit_sha,
                   seconds: (i < timed_shards ? seconds : nil))
    end
    repository.test_runs.find_by!(ci_run_id: "gha-#{commit_sha}")
  end

  # Criterion 1: a repository with two or more comparable runs on one branch renders a trajectory
  # that can be read without SQL.
  describe "a branch with a history" do
    it "draws the suite's size across the branch's runs" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 20.days.ago)
      run(repository, "bbbbbbb2222", total: 1_020, at: 10.days.ago)
      run(repository, "ccccccc3333", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(chart).to have_css("svg circle", count: 3, visible: :all)
      expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb ccccccc])
    end

    # Oldest first. A trajectory read right-to-left would show every growing suite shrinking.
    it "runs oldest to newest, so growth reads as growth" do
      repository = create_repository(user: @user)
      run(repository, "oldest00000", total: 1_000, at: 20.days.ago)
      run(repository, "newest00000", total: 1_500, at: 1.hour.ago)

      get repository_path(repository)

      expect(plotted_rows.map { |cells| cells[1] }).to eq(["1,000", "1,500"])
    end

    # Criterion 5's first half: the label carries its own denominator, on the rule
    # `TestRun#machine_seconds_coverage` states. "3 runs" over a line through 2 is an overclaim that
    # a caption further down does not undo.
    it "states its own coverage beside the label, and only says every when it means it" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 2.days.ago)
      run(repository, "bbbbbbb2222", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(chart).to have_text("every one of the last 2 runs plotted", normalize_ws: true)
      expect(chart).to have_text("Tests in suite on main", normalize_ws: true)
    end

    # Criterion 5's second half: which branch, how many plotted, and the window covered.
    it "names the branch, the counts and the window the line covers" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 30.days.ago)
      run(repository, "bbbbbbb2222", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(basis_line).to have_text("Drawn through 2 of the last 2 runs on main", normalize_ws: true)
      expect(basis_line).to have_text("covering 30 days", normalize_ws: true)
      expect(basis_line).to have_text("Only runs on the same branch are plotted", normalize_ws: true)
    end

    # The axis does not start at zero — a suite of 20,000 that grew by 47 would be a flat line if it
    # did, which is the change this panel exists to show rendered as no change. So both bounds are
    # printed and the summary says what the slope therefore is and is not.
    it "prints the range it scaled to and disclaims the slope's meaning" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 20_000, at: 2.days.ago)
      run(repository, "bbbbbbb2222", total: 20_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(chart).to have_text("20,047", normalize_ws: true)
      expect(chart).to have_text("20,000", normalize_ws: true)
      expect(chart_summary).to have_text("does not start at zero", normalize_ws: true)
      expect(chart_summary).to have_text("the slope is the size of the change and not its share",
                                         normalize_ws: true)
    end

    # A real flat line: measured repeatedly across comparable runs, and it did not move. Distinct
    # from the thin-history state below, which refuses to draw one.
    it "says a suite that did not move did not move, rather than leaving a flat line unexplained" do
      repository = create_repository(user: @user)
      run(repository, "steady00001", total: 1_000, at: 2.days.ago)
      run(repository, "steady00002", total: 1_000, at: 1.hour.ago)

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of them measured 1,000 tests", normalize_ws: true)
      expect(basis_line).to have_text("which is a measurement and not an absence of one",
                                      normalize_ws: true)
    end

    # The panel below is one interleaved history across every branch and says so in its own words.
    # A line drawn through it would join a trunk run to a feature branch's and call the gap growth.
    it "never reaches across branches" do
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 3.days.ago)
      run(repository, "featurebbbb", branch: "feature/x", total: 20, at: 2.days.ago)
      run(repository, "trunkcccccc", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[trunkaa trunkcc])
      expect(basis_line).to have_text("Drawn through 2 of the last 2 runs on main", normalize_ws: true)
      expect(chart).to have_no_text("featureb", normalize_ws: true)
    end

    # Bounded at thirty rows, so the panel costs the same on a repository CI has reported to for a
    # year as on one it reported to last week.
    it "bounds the window at the model's limit" do
      repository = create_repository(user: @user)
      40.times { |i| run(repository, "sha#{i.to_s.rjust(4, "0")}000", total: 1_000 + i, at: (40 - i).days.ago) }

      get repository_path(repository)

      expect(chart).to have_css("svg circle", count: Repository::TRAJECTORY_LIMIT, visible: :all)
      expect(basis_line).to have_text("Drawn through 30 of the last 30 runs on main", normalize_ws: true)
      expect(plotted_labels.first).to eq("sha0010")
      expect(plotted_labels.last).to eq("sha0039")
    end
  end

  # == Criterion 2: no cliff
  #
  # A run's `total_specs_count` is the SUM over the shards recorded SO FAR. Plotted naively, every
  # in-flight or cancelled sharded run is a drop to a quarter of the suite and a recovery — a mass
  # test deletion and restoration, neither of which any commit made, both wearing real SHAs.
  describe "a history containing a run that was assembled differently" do
    it "withholds an in-flight sharded run instead of drawing it as a deletion" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      sharded_run(repository, commit_sha: "bbbbbbb22222", per_shard: 5_010)
      # A third run, one of four shards delivered. This is the ordinary state of the page for most
      # of the twenty minutes a CI build takes.
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                   commit_sha: "ccccccc33333")

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb])
      # 5,020 must not reach the axis either: a floor there is the cliff drawn as a scale even with
      # the point itself gone.
      expect(chart).to have_no_text("5,020", normalize_ws: true)
      expect(chart).to have_text("20,000", normalize_ws: true)
      expect(chart).to have_text("20,040", normalize_ws: true)
    end

    # The permanent form. A job cancelled after two of four shards leaves the half-sized row in the
    # history forever — this is not a window that closes on its own.
    it "withholds a job cancelled part-way through, permanently" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      sharded_run(repository, commit_sha: "cancelled222", per_shard: 5_000, shards: 2)
      sharded_run(repository, commit_sha: "bbbbbbb33333", per_shard: 5_010)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb])
      expect(chart).to have_no_text("10,000", normalize_ws: true)
    end

    # Counted in the caption and given its reason, not silently dropped. A line through 2 of 3 runs
    # that says nothing about the third is a chart claiming a completeness it does not have.
    it "counts the withheld run in the caption and says why it was withheld" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      sharded_run(repository, commit_sha: "bbbbbbb22222", per_shard: 5_010)
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                   commit_sha: "ccccccc33333")

      get repository_path(repository)

      expect(chart).to have_text("2 of 3 runs plotted", normalize_ws: true)
      expect(basis_line).to have_text("Drawn through 2 of the last 3 runs on main", normalize_ws: true)
      expect(basis_line).to have_text("all assembled from 4 shard reports", normalize_ws: true)
      # The withheld run holds ONE of the cohort's four parts, so this is the direction the
      # fraction-of-its-own-suite sentence is actually true about.
      expect(basis_line).to have_text(
        "1 run is withheld for having reported only some of the parts the plotted runs reported",
        normalize_ws: true
      )
      expect(basis_line).to have_text("the sum of the shards it has reported so far",
                                      normalize_ws: true)
    end

    # == The other direction of the same mismatch
    #
    # `assembled_like?` is symmetric, so a run is withheld whether it holds FEWER of the cohort's
    # parts or MORE. The fraction-of-its-own-suite explanation is true only of the first. These
    # three sharded runs each measured their whole suite across all four shards; the caption used to
    # tell their reader they were builds "still arriving — or one cancelled part-way", sitting "at a
    # fraction of [their] own suite", which is false in every clause. The count was right and the
    # reason was invented, and no example rendered the sentence to catch it.
    it "does not call a complete sharded run a fragment when the cohort arrived whole" do
      repository = create_repository(user: @user)
      5.times { |i| run(repository, "plain#{i}000000", total: 1_000 + i, at: (30 - i).days.ago) }
      3.times { |i| sharded_run(repository, commit_sha: "whole#{i}0000000", per_shard: 5_000) }

      get repository_path(repository)

      # The five that arrived whole are the cohort; the three complete sharded runs are withheld.
      expect(plotted_labels).to eq(%w[plain00 plain10 plain20 plain30 plain40])
      expect(basis_line).to have_text(
        "3 runs are withheld for having arrived differently from the runs the line is drawn " \
        "through — assembled from 4 shard reports, where the line is drawn through runs reported " \
        "in one piece",
        normalize_ws: true
      )
      expect(basis_line).to have_text("not a claim that these ones measured less than they should have",
                                      normalize_ws: true)
      # Every clause of the in-flight explanation is false about all three.
      expect(basis_line).to have_no_text("only some of the parts", normalize_ws: true)
      expect(basis_line).to have_no_text("cancelled part-way", normalize_ws: true)
      expect(basis_line).to have_no_text("a fraction of its own suite", normalize_ws: true)
    end

    # Both directions at once, each getting the sentence that is true of it — and never one
    # combined figure, for the reason the two withholding *reasons* are never combined: a number
    # that merges two causes describes neither.
    it "explains each direction of the mismatch separately when both are in the window" do
      repository = create_repository(user: @user)
      3.times { |i| sharded_run(repository, commit_sha: "whole#{i}0000000", per_shard: 5_000 + i) }
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                   commit_sha: "inflight9999")
      sharded_run(repository, commit_sha: "eightsh00000", per_shard: 2_500, shards: 8)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[whole00 whole10 whole20])
      expect(basis_line).to have_text(
        "1 run is withheld for having reported only some of the parts the plotted runs reported",
        normalize_ws: true
      )
      expect(basis_line).to have_text(
        "1 run is withheld for having arrived differently from the runs the line is drawn " \
        "through — assembled from 8 shard reports, where the line is drawn through runs assembled " \
        "from 4 shard reports",
        normalize_ws: true
      )
    end

    # A phrase for a group is only available when the group shares one — generalising one member's
    # composition to a mixed set is this panel's own overclaim in miniature.
    it "names no composition for a withheld group that did not all arrive the same way" do
      repository = create_repository(user: @user)
      4.times { |i| run(repository, "plain#{i}000000", total: 1_000 + i, at: (30 - i).days.ago) }
      sharded_run(repository, commit_sha: "fourshard000", per_shard: 5_000)
      sharded_run(repository, commit_sha: "eightsh00000", per_shard: 2_500, shards: 8)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[plain00 plain10 plain20 plain30])
      expect(basis_line).to have_text(
        "2 runs are withheld for having arrived differently from the runs the line is drawn through.",
        normalize_ws: true
      )
      expect(basis_line).to have_no_text("where the line is drawn through runs", normalize_ws: true)
    end

    # A growth chart's unstated premise is that its right-hand end is "now". During a shard-layout
    # migration it is not: the cohort is the older, larger group, so the line stops before the SHA
    # the Overview names directly above. The counts disclose it arithmetically; nothing said it.
    it "says out loud when the most recent run is not on the line" do
      repository = create_repository(user: @user)
      4.times { |i| sharded_run(repository, commit_sha: "oldwy#{i}0000000", per_shard: 5_000 + i) }
      TestRun.where.not(ci_run_id: nil).update_all(created_at: 20.days.ago)
      sharded_run(repository, commit_sha: "newwy00000000", per_shard: 2_500, shards: 8)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[oldwy00 oldwy10 oldwy20 oldwy30])
      expect(basis_line).to have_text("The most recent run on main is not on this line: newwy00",
                                      normalize_ws: true)
      expect(basis_line).to have_text("is one of the withheld runs, so the line ends at oldwy30",
                                      normalize_ws: true)
      # Both SHAs in the sentence, not just the one. They sit in a single clause, so one of them in
      # the body font does not read as a second convention — it reads as a fault in the sentence.
      expect(basis_line_shas).to include("newwy00", "oldwy30")
    end

    # The ordinary case must not carry the caveat — a sentence that appears every time is a sentence
    # nobody reads the one time it matters.
    it "says nothing about a missing newest run when the newest run is plotted" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 2.days.ago)
      run(repository, "bbbbbbb2222", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(basis_line).to have_no_text("is not on this line", normalize_ws: true)
    end

    # The reading that first suggests itself — anchor on the latest run, as the Overview's delta
    # does — is wrong in exactly this state and wrong in the worst direction: it would withhold the
    # complete runs and plot the fragment alone.
    it "keeps the complete runs when the LATEST run is the one still arriving" do
      repository = create_repository(user: @user)
      3.times { |i| sharded_run(repository, commit_sha: "whole#{i}0000000", per_shard: 5_000 + i) }
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                   commit_sha: "inflight9999")

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[whole00 whole10 whole20])
      expect(chart).to have_text("3 of 4 runs plotted", normalize_ws: true)
    end

    # The whole existing corpus — a laptop `bundle exec rspec`, an unrecognised CI provider. Those
    # rows record no shards, were written once and never re-derived, so they were always comparable
    # and the guard must not have quietly switched the panel off for them.
    it "plots the unsharded corpus and states how it arrived in the words that fit it" do
      repository = create_repository(user: @user)
      run(repository, "plainaaaaaa", total: 1_000, at: 2.days.ago)
      run(repository, "plainbbbbbb", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[plainaa plainbb])
      # Through `TestRun#delivery_description`, which is the point: "the same 0 shard reports" —
      # which is what an inflected count renders here — would describe a run that arrived whole as a
      # delivery that lost everything.
      expect(basis_line).to have_text("all reported in one piece", normalize_ws: true)
      expect(basis_line).to have_no_text("shard report", normalize_ws: true)
    end
  end

  # The other half of the same question, asked of a count rather than of a composition: a run that
  # reported zero has a count but not a measurement.
  describe "a run that reported no tests" do
    it "withholds it and says a zero describes the report, not the suite" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 3.days.ago)
      run(repository, "zeroooo2222", total: 0, at: 2.days.ago)
      run(repository, "bbbbbbb3333", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb])
      expect(basis_line).to have_text("1 run is withheld for having reported no tests at all",
                                      normalize_ws: true)
      expect(basis_line).to have_text("a zero there describes the report, not the suite",
                                      normalize_ws: true)
      # The composition wording must not stand in for this one: nothing here was sharded.
      expect(basis_line).to have_no_text("arrived differently", normalize_ws: true)
      expect(basis_line).to have_no_text("only some of the parts", normalize_ws: true)
    end

    it "keeps the two reasons apart when both occur" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      sharded_run(repository, commit_sha: "bbbbbbb22222", per_shard: 5_010)
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                   commit_sha: "ccccccc33333")
      run(repository, "zeroooo4444", total: 0, at: 1.minute.ago)

      get repository_path(repository)

      # Never one total. "2 withheld" hides an in-flight build inside the same figure as a client
      # reporting nothing, and only one of those is a fault.
      expect(basis_line).to have_text("1 run is withheld for having reported no tests at all",
                                      normalize_ws: true)
      expect(basis_line).to have_text(
        "1 run is withheld for having reported only some of the parts the plotted runs reported",
        normalize_ws: true
      )
      expect(chart).to have_text("2 of 4 runs plotted", normalize_ws: true)
    end
  end

  # Criterion 6: fewer than two comparable points is an honest sentence, never a flat line — which
  # would say the suite is stable, the one thing a history this thin cannot say.
  describe "when there is not enough to draw" do
    it "refuses to draw a line through a branch's first run" do
      repository = create_repository(user: @user)
      run(repository, "firstever01", total: 1_000)

      get repository_path(repository)

      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      expect(trajectory_panel).to have_text("Not enough comparable runs yet", normalize_ws: true)
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on main so far", normalize_ws: true)
      expect(trajectory_panel).to have_text("A single measurement drawn as a line is a flat line",
                                            normalize_ws: true)
    end

    # "One run so far" and "three runs, none of them comparable" are different things to go and
    # look at, and they must not share a sentence.
    it "says how many runs there were and why none of them could be compared" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaaaaa11111", per_shard: 5_000)
      run(repository, "zeroooo2222", total: 0, at: 1.minute.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      expect(trajectory_panel).to have_text("SpecGuard has 2 runs on main", normalize_ws: true)
      expect(trajectory_panel).to have_text("only 1 of them can be compared with each other",
                                            normalize_ws: true)
      expect(trajectory_panel).to have_text("1 reported no tests at all", normalize_ws: true)
    end

    # The thin state was the second site of the same defect the basis line carried: it worded every
    # composition mismatch as "assembled from a different number of shard reports than the rest",
    # which for a whole delivery means "0 shard reports" — the exact phrasing
    # `TestRun#delivery_description`'s comment exists to forbid — and its closing sentence called
    # every withheld run a "less complete report". Here the withheld run really is one.
    it "says a run had reported only some of its parts when that is the direction it missed by" do
      repository = create_repository(user: @user)
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_000,
                   commit_sha: "inflight9999")
      sharded_run(repository, commit_sha: "whole00000000", per_shard: 5_000)

      get repository_path(repository)

      expect(trajectory_panel).to have_text("SpecGuard has 2 runs on main", normalize_ws: true)
      expect(trajectory_panel).to have_text("1 had reported only some of its parts", normalize_ws: true)
      expect(trajectory_panel).to have_no_text("shard reports than the rest", normalize_ws: true)
    end

    # ...and here it is the opposite: the withheld run arrived whole in a single POST, which is not
    # a partial delivery of anything and is not "0 shard reports" either.
    it "does not call a whole delivery a partial one when it is the odd run out" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "whole00000000", per_shard: 5_000)
      run(repository, "laptop00000", total: 12, at: 1.minute.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_text(
        "1 was assembled from more parts than the rest, or arrived whole where the rest were sharded",
        normalize_ws: true
      )
      expect(trajectory_panel).to have_no_text("only some of its parts", normalize_ws: true)
      # The closing sentence claims only what the rule establishes. "less complete reports" was
      # false about exactly this run.
      expect(trajectory_panel).to have_text("None of those is a smaller suite", normalize_ws: true)
      expect(trajectory_panel).to have_no_text("less complete reports", normalize_ws: true)
    end

    # `0` gets its own wording. "only 0 of them are comparable" is a sentence about a number.
    it "says none rather than zero when nothing could be plotted" do
      repository = create_repository(user: @user)
      run(repository, "zeroooo1111", total: 0, at: 2.days.ago)
      run(repository, "zeroooo2222", total: 0, at: 1.hour.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_text("none of them can be plotted", normalize_ws: true)
      expect(trajectory_panel).to have_no_text("only 0 of them", normalize_ws: true)
    end

    # A different fact from a young branch, and a different thing to fix: a CI client that is not
    # sending a branch will not start on its own. Same distinction the Overview's basis line draws.
    it "says a run that named no branch cannot be placed in a history" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "anonymous01", branch: nil, total_specs_count: 1_000,
                                   created_at: 2.days.ago)
      repository.test_runs.create!(commit_sha: "anonymous02", branch: nil, total_specs_count: 1_047,
                                   created_at: 1.hour.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_text("No branch to plot a history on", normalize_ws: true)
      # Every anonymous run pooled under `branch IS NULL` would have drawn one confident line
      # through runs that may have come from anywhere.
      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      # ...and it must not be answering with the young-branch wording instead.
      expect(trajectory_panel).to have_no_text("Not enough comparable runs yet", normalize_ws: true)
    end

    # The Overview's "No CI run has reported yet" is the page's one never-ingested empty state. A
    # second dashed box saying a quieter version of it would read as a different, milder fact.
    it "does not render at all when CI has never reported" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(Capybara.string(response.body)).to have_no_css("#suite-trajectory")
      expect(Capybara.string(response.body).find("#overview"))
        .to have_text("No CI run has reported yet", normalize_ws: true)
    end
  end

  # == Choosing the branch (`?branch=`)
  #
  # The state this whole surface was dark for, and which NO example above can observe: the newest
  # run in the repository is a feature branch's FIRST run, so the panel re-anchors to it and has
  # one point to draw, while `main` holds a month of comparable history in the same table. The two
  # mixed-branch examples above cannot reach it — "never reaches across branches" puts its
  # `feature/x` run BETWEEN two `main` runs, and the sharded budget example puts its feature run
  # OLDER than the anchor. Both leave `main` as the anchor, which is the case that was never broken.
  describe "choosing the branch the panel is drawn on" do
    # Newest run in the repository is `feature/x`'s first and only one; `main` has two comparable
    # runs behind it. On a busy repository whose CI reports on every PR, this is the normal state.
    def repository_anchored_on_a_feature_branch
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 3.days.ago)
      run(repository, "trunkbbbbbb", total: 1_047, at: 2.days.ago)
      run(repository, "feat1111111", branch: "feature/x", total: 12, at: 1.minute.ago)
      repository
    end

    def branch_choices
      trajectory_panel.all("#suite-trajectory-branches nav a").map(&:text)
    end

    # The OVERFLOW control, and deliberately a different accessor from `branch_choices`.
    #
    # That one is scoped to `nav a` — the eight-item primary row — so it would go on reporting eight
    # names however many the menu reached, and every criterion about reaching PAST the row asserted
    # through it would be green by construction. The two selectors are disjoint on purpose: the menu
    # is rendered outside the `<nav>`, which is also why the row's size, order and `30+` wording are
    # unchanged by this control existing.
    #
    # `visible: :all` because the control is a CLOSED `<details>` and Capybara is right to call its
    # contents hidden — that is the disclosure working, not the links missing. What these accessors
    # assert is that the names are in the document the server sent, which is what makes them
    # reachable from the keyboard and with no JavaScript at all.
    def branch_menu_links
      trajectory_panel.all("#suite-trajectory-branch-menu a", visible: :all)
    end

    def branch_menu_choices
      branch_menu_links.map(&:text)
    end

    # The branch each menu link actually asks for, read off the rendered `href` rather than assumed
    # from its label — an href carrying the wrong name, or no `branch=` at all, is the failure this
    # is here to catch and a label assertion cannot see it.
    def branch_menu_targets
      branch_menu_links.map { |link| Rack::Utils.parse_query(URI.parse(link[:href]).query)["branch"] }
    end

    # `main` plus ten feature branches: three more than the row can carry, which is the fixture
    # shape the cut-and-say-so example above already pins the row's half of.
    def repository_with_eleven_branches
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 30.days.ago)
      run(repository, "trunkbbbbbb", total: 1_047, at: 29.days.ago)
      10.times { |i| run(repository, "feat#{i}0000000", branch: "feature/#{i}", total: 10, at: (20 - i).days.ago) }
      repository
    end

    def every_branch_in_the_eleven
      ["main", *0.upto(9).map { |i| "feature/#{i}" }]
    end

    it "draws the branch that was asked for, where the default anchor has nothing to draw" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository)

      # Today's behaviour, unchanged: the panel is dark because the newest run is a first run.
      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/x so far", normalize_ws: true)

      get repository_path(repository, branch: "main")

      expect(response).to have_http_status(:ok)
      expect(chart).to have_css("svg circle", count: 2, visible: :all)
      expect(plotted_labels).to eq(%w[trunkaa trunkbb])
      expect(chart).to have_text("Tests in suite on main", normalize_ws: true)
      expect(basis_line).to have_text("Drawn through 2 of the last 2 runs on main", normalize_ws: true)
    end

    # The selected branch anchors THIS panel and nothing else. `@latest_test_run` is untouched, so
    # the Overview's suite size and the Recent-runs panel go on naming the repository's latest run —
    # and a reader can never end up with a headline figure about one run above a chart about another.
    it "moves this panel only, leaving the rest of the page naming the latest run" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository, branch: "main")

      page = Capybara.string(response.body)
      expect(page.find("#overview")).to have_text("Measured on feat111 (feature/x)", normalize_ws: true)
      expect(page.find("#recent-runs")).to have_text("feat111", normalize_ws: true)
    end

    # Criterion 2: a dark panel discloses that another branch has history. Without this the reader
    # of a dark panel has no way to learn that `main` is one click away — nothing else on the page
    # mentions a branch they are not already looking at.
    it "names the branches that have runs and how many each has" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository)

      # Most history first, and the branch being drawn is the one marked current — not the one
      # moved to the front, so the list does not reshuffle as the reader clicks along it.
      expect(branch_choices).to eq(["main (2 runs)", "feature/x (1 run)"])
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["feature/x (1 run)"])
    end

    it "marks the branch it is drawing as the current one" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository, branch: "main")

      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["main (2 runs)"])
    end

    # A count that STOPPED is not a count that finished. The query walks one row past the window and
    # no further, so a trunk with thousands of runs is never counted to answer a question the chart
    # does not ask — and the label says "30+" rather than publishing the row it stopped at.
    it "words a history longer than the window it counts as 30+" do
      repository = create_repository(user: @user)
      (Repository::TRAJECTORY_LIMIT + 1).times do |i|
        run(repository, "sha#{i.to_s.rjust(4, "0")}000", total: 1_000 + i, at: (40 - i).days.ago)
      end

      get repository_path(repository)

      expect(branch_choices).to eq(["main (30+ runs)"])
      expect(trajectory_panel.find("#suite-trajectory-branches-basis"))
        .to have_text("means the branch holds more history than the chart reaches", normalize_ws: true)
    end

    # A truncated list of branches with nothing said about it reads as the complete set. The ones
    # shown are the ones with the most history, so `main` survives a cut that an alphabetical list
    # would have dropped it out of.
    it "lists the branches with the most history and says how many it left out" do
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 30.days.ago)
      run(repository, "trunkbbbbbb", total: 1_047, at: 29.days.ago)
      10.times { |i| run(repository, "feat#{i}0000000", branch: "feature/#{i}", total: 10, at: (20 - i).days.ago) }

      get repository_path(repository)

      expect(branch_choices.size).to eq(RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES)
      # `main` has twice the history of any feature branch and leads on that; the feature branches
      # follow newest-pushed first, which is where the cut falls.
      expect(branch_choices.first(2)).to eq(["main (2 runs)", "feature/9 (1 run)"])
      expect(trajectory_panel.find("#suite-trajectory-branches-basis")).to have_text(
        "3 further branches have runs and are not in the row above. The branch menu names all 11.",
        normalize_ws: true
      )
    end

    # The one case the display order bends for. A reader can arrive by URL on a branch holding a
    # single run with a dozen busier branches ahead of it — and a selector that cannot show the
    # branch it is drawing is a selector that has lost the reader.
    it "shows the branch it is drawing even when the cut would have left it out" do
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 30.days.ago)
      run(repository, "trunkbbbbbb", total: 1_047, at: 29.days.ago)
      10.times { |i| run(repository, "feat#{i}0000000", branch: "feature/#{i}", total: 10, at: (20 - i).days.ago) }

      # The thinnest, least recently pushed branch there is: last in the order, well past the cut.
      get repository_path(repository, branch: "feature/0")

      expect(branch_choices.size).to eq(RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES)
      expect(branch_choices.first).to eq("feature/0 (1 run)")
      expect(branch_choices).to include("main (2 runs)")
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["feature/0 (1 run)"])
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/0 so far", normalize_ws: true)
      # …and the sentence describing the order says so, rather than claiming a most-history-first
      # list the reader can see the first entry is not the head of.
      expect(trajectory_panel.find("#suite-trajectory-branches-basis")).to have_text(
        "The branch being drawn is listed first, then the branches with the most history",
        normalize_ws: true
      )
    end

    # == Reaching the branches the row does not carry
    #
    # The row is cut to eight and the page said so — a COUNT, and nothing that turns it into names.
    # `?branch=` is a mechanism nothing rendered on this page mentioned, so the only route to a
    # branch behind the cut was to type the URL, and a reader cannot type a name they were never
    # shown. Every step past the click already shipped: the controller honours `?branch=`, the panel
    # re-anchors, and `trajectory_shown_branches` pulls the asked-for branch into the row and marks
    # it current. What was missing was the first step.

    # Criterion 1. Eleven branches are loaded out of one query; before this, three of them existed
    # on the page only as the number 3.
    #
    # Asserted through `branch_menu_*` and never `branch_choices` — see that accessor's note.
    it "names every branch it loaded, not only the eight the row lists" do
      repository = repository_with_eleven_branches

      get repository_path(repository)

      # The row is untouched: still eight, and still the eight with the most history.
      expect(branch_choices.size).to eq(RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES)

      expect(branch_menu_choices).to match_array(
        ["main (2 runs)", *0.upto(9).map { |i| "feature/#{i} (1 run)" }]
      )
      # Every one of them is a link that ASKS for that branch, not merely a name printed on a page.
      expect(branch_menu_links.map { |link| link[:href] }).to all(include("branch="))
      expect(branch_menu_targets).to match_array(every_branch_in_the_eleven)
      # The three the row left out are the whole point, and they are the ones an assertion over the
      # union of both controls would not notice going missing.
      expect(branch_menu_choices - branch_choices).to contain_exactly(
        "feature/0 (1 run)", "feature/1 (1 run)", "feature/2 (1 run)"
      )
    end

    # Criterion 2. The URL is taken off the page rather than written here: a spec that composes
    # `repository_path(repository, branch: "feature/0")` itself would pass against the very page
    # this ticket describes, where the reader has no way to compose it.
    it "draws a branch from behind the cut by following a link the page itself rendered" do
      repository = repository_with_eleven_branches

      get repository_path(repository)

      # Thinnest and least recently pushed: last in the order, well past the cut.
      expect(branch_choices).not_to include("feature/0 (1 run)")

      href = trajectory_panel.find("#suite-trajectory-branch-menu a", exact_text: "feature/0 (1 run)",
                                    visible: :all)[:href]
      get href

      expect(response).to have_http_status(:ok)
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/0 so far", normalize_ws: true)
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["feature/0 (1 run)"])
    end

    # Criterion 7. The disclosure is `details`/`summary`, so it opens from the keyboard and closes on
    # Escape with no JavaScript — and its links are in the document whether it is open or not, which
    # is what makes the criterion-1 assertion above a statement about the page rather than about a
    # widget's default state.
    it "opens from the keyboard, with no script and nothing hidden from a non-visual reader" do
      repository = repository_with_eleven_branches

      get repository_path(repository)

      menu = trajectory_panel.find("#suite-trajectory-branch-menu")
      expect(menu).to have_css("details > summary")
      expect(menu.find("summary").text.squish).to eq("All 11 branches")
      expect(menu.all("details a", visible: :all).size).to eq(11)
    end

    # Criterion 7's other half. The drawn branch is named TWICE on this page — pulled into the row
    # by `trajectory_shown_branches` and listed in the menu, which omits nothing — so both have to
    # say it is the current one. A menu that marked none of its entries would tell a screen reader
    # the opposite of what the row says about the same branch.
    it "marks the branch it is drawing as current in the menu as well as in the row" do
      repository = repository_with_eleven_branches

      get repository_path(repository, branch: "feature/0")

      expect(trajectory_panel.all("#suite-trajectory-branch-menu a[aria-current='page']", visible: :all).map(&:text))
        .to eq(["feature/0 (1 run)"])
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["feature/0 (1 run)"])
      # Twice, and only the two: one control marking a branch the other does not is a reader being
      # told two different things about which branch they are looking at.
      expect(trajectory_panel.all("#suite-trajectory-branches [aria-current='page']", visible: :all).map(&:text))
        .to eq(["feature/0 (1 run)", "feature/0 (1 run)"])
    end

    # The menu and the hidden-branches sentence are two halves of one disclosure — what the row left
    # out, and where it is — so neither may appear without the other. A menu on a page whose row
    # already names every branch is a control with nothing behind it, and the sentence with no menu
    # under it is the state this ticket exists to end.
    it "renders no menu on a page whose row already names every branch" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository)

      expect(branch_choices).to match_array(["main (2 runs)", "feature/x (1 run)"])
      expect(trajectory_panel).to have_no_css("#suite-trajectory-branch-menu")
      expect(trajectory_panel.find("#suite-trajectory-branches-basis")).to have_no_text("further branch")
    end

    # Criterion 2 in the shape the ticket was written for, and the composed case nothing reached
    # before: the newest run is a feature branch's FIRST, `main` holds the history, and there are
    # more branches than the selector shows. `:163` puts its `feature/x` run BETWEEN two `main` runs
    # and `:565` puts it OLDER than the anchor, so both keep `main` as the anchor and neither can
    # observe this.
    #
    # The walk that finds the branches is alphabetical, so `main` sorts behind every `feature/*`
    # here — a walk bounded near the display size would offer eight unrelated one-run branches on
    # the one page whose reason for existing is that `main` has the runs, and mark none of them
    # current. A dark panel that lists only branches with nothing behind them tells the reader the
    # opposite of the thing it is here to disclose. Sixty of them, deliberately: that is where a
    # bound set for a display list rather than for branch cardinality drops the trunk.
    it "names the branch that holds the history, on a dark panel drawn on another one" do
      repository = create_repository(user: @user)
      5.times { |i| run(repository, "trunk#{i}000000", total: 1_000 + i, at: (40 - i).days.ago) }
      60.times do |i|
        run(repository, "old#{i.to_s.rjust(8, "0")}", branch: "feature/#{i.to_s.rjust(3, "0")}",
                        total: 10, at: (30 - (i * 0.4)).days.ago)
      end
      run(repository, "newest000000", branch: "feature/999", total: 12, at: 1.minute.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/999 so far", normalize_ws: true)
      expect(branch_choices.first).to eq("main (5 runs)")
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["feature/999 (1 run)"])

      # …and the way out of it. The chart draws `main`, and the selector says that is what it drew.
      get repository_path(repository, branch: "main")

      expect(basis_line).to have_text("Drawn through 5 of the last 5 runs on main", normalize_ws: true)
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["main (5 runs)"])
    end

    # What the panel may still claim once the walk STOPPED rather than finished. The ordering is a
    # property of the branches SpecGuard walked and the walk is alphabetical, so past its bound the
    # head of this list is the busiest of a prefix and not of the repository — and a sentence
    # promising otherwise tells a reader who cannot find `main` that `main` has no history.
    #
    # The branch being drawn is in the list whatever the walk did: it is pinned, not walked to.
    # Here `main` sorts behind every `feature/*`, so the walk never reaches it.
    it "stops claiming an ordering over every branch once the walk was cut, and still offers the one it drew" do
      stub_const("Repository::BRANCH_HISTORY_LIMIT", 10)
      repository = create_repository(user: @user)
      2.times { |i| run(repository, "trunk#{i}000000", total: 1_000 + i, at: (40 - i).days.ago) }
      12.times do |i|
        run(repository, "side#{i.to_s.rjust(7, "0")}", branch: "feature/#{i.to_s.rjust(3, "0")}",
                        total: 10, at: (30 - i).days.ago)
      end

      get repository_path(repository, branch: "main")

      expect(branch_choices.first).to eq("main (2 runs)")
      expect(trajectory_panel.all("#suite-trajectory-branches nav a[aria-current='page']").map(&:text))
        .to eq(["main (2 runs)"])
      # NOTE: the sentence says "these 11" and NOT "the 11 SpecGuard walked to". The walk reached
      # TEN here — `BRANCH_HISTORY_LIMIT` is stubbed to 10 and the walk is alphabetical, so it gets
      # `feature/000`…`feature/009` and stops. `main` is the eleventh and it is in this list because
      # it was PINNED, outside `:branch_limit` (`app/models/repository.rb:255-259`) — i.e. it is here
      # precisely because the walk never reached it, which is the same fact `trajectory_walk_cut?`
      # needs `>=` for. A provenance claim over this count is off by the pins in exactly the branch
      # written to not overclaim; the bare count is true however a row arrived. Do not reach for
      # "walked to" when rewording this again.
      expect(trajectory_panel.find("#suite-trajectory-branches-basis")).to have_text(
        "At least 3 further branches have runs and are not in the row above. The branch menu names " \
        "these 11, and cannot offer one the walk never reached. The branches with " \
        "the most history are listed first. SpecGuard stops after walking 10 branches, so that is an " \
        "ordering over the ones it walked and not over every branch here.", normalize_ws: true
      )
      # The menu's own label carries the same bound. "All 11 branches" over a walk that STOPPED
      # would be the completeness claim the sentence above is written to withhold — said on the
      # control itself, where a reader deciding whether to open it will read it first.
      expect(trajectory_panel.find("#suite-trajectory-branch-menu summary").text.squish).to eq("11 branches")
    end

    # Criterion 3, and the reason the fallback is disclosed rather than silent: a deleted branch, a
    # typo and a stale bookmark are ordinary ways to arrive here. The page renders what it would
    # have rendered anyway — and says which branch it drew instead of the one that was asked for.
    it "falls back to the default anchor for a branch it has no runs on, and says so" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository, branch: "feature/deleted")

      expect(response).to have_http_status(:ok)
      expect(trajectory_panel).to have_no_css("svg", visible: :all)
      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/x so far", normalize_ws: true)
      expect(trajectory_panel.find("#suite-trajectory-branch-fallback")).to have_text(
        "SpecGuard has no runs on feature/deleted, so this panel is drawn on feature/x", normalize_ws: true
      )
    end

    it "treats a blank branch as no ask at all, and says nothing about a fallback that did not happen" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository, branch: "")

      expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/x so far", normalize_ws: true)
      expect(trajectory_panel).to have_no_css("#suite-trajectory-branch-fallback")
    end

    it "says nothing about a fallback when the branch asked for is the one it drew" do
      repository = repository_anchored_on_a_feature_branch

      get repository_path(repository, branch: "main")

      expect(trajectory_panel).to have_no_css("#suite-trajectory-branch-fallback")
    end

    # `?branch[]=main` and `?branch[x]=1` are a URL anyone can type, and neither is a branch name.
    # Handed to a `where` they raise — a 500 on the read-only page a reader arrived at by link.
    #
    # The shapes are listed ONCE, in `spec/support/shared_examples/malformed_branch_param.rb`, and
    # `GET /api/v1/repository` runs the same list against the same guard
    # (`RequestedBranchParam#requested_branch`). This page pinned two of the three before that guard
    # was shared; the third was never a live bug here, but the gap was the leading indicator that
    # the two copies were being maintained apart.
    #
    # The assertion is the panel's own words rather than a bare 200, and its force comes from the
    # example directly above: `?branch=main` IS honoured and renders no fallback, so a guard that
    # simply threw the parameter away could not pass both.
    describe "a branch parameter that is not a branch name" do
      def expect_branch_param_treated_as_no_ask(query)
        repository = repository_anchored_on_a_feature_branch

        get repository_path(repository), params: query

        expect(response).to have_http_status(:ok)
        expect(trajectory_panel).to have_text("SpecGuard has 1 run on feature/x so far", normalize_ws: true)
      end

      it_behaves_like "a surface that treats a malformed branch parameter as no ask"
    end

    # The anonymous runs are not a branch and are not offered as one — pooling them is the failure
    # the "No branch to plot a history on" state exists to refuse. What the selector adds is the way
    # OUT of that state: the panel names the branch that does have a history.
    it "offers no way to select the runs that named no branch, and a way to leave that state" do
      repository = create_repository(user: @user)
      run(repository, "trunkaaaaaa", total: 1_000, at: 3.days.ago)
      run(repository, "trunkbbbbbb", total: 1_047, at: 2.days.ago)
      repository.test_runs.create!(commit_sha: "anonymous01", branch: nil, total_specs_count: 900,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_text("No branch to plot a history on", normalize_ws: true)
      expect(branch_choices).to eq(["main (2 runs)"])

      get repository_path(repository, branch: "main")

      expect(plotted_labels).to eq(%w[trunkaa trunkbb])
    end

    it "renders no selector at all when no run has ever named a branch" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "anonymous01", branch: nil, total_specs_count: 900,
                                   created_at: 2.days.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_text("No branch to plot a history on", normalize_ws: true)
      expect(trajectory_panel).to have_no_css("#suite-trajectory-branches")
    end

    # The one page state where there is no selector to nest the disclosure in — and the one state
    # where nothing else on the panel says anything about the ask. Whether there are CHOICES to
    # offer and whether an ASK was substituted are independent questions, and a notice rendered
    # inside the selector could answer the second only when the first happened to be yes.
    it "discloses a substituted branch where there is no selector to hang the notice on" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "anonymous01", branch: nil, total_specs_count: 900,
                                   created_at: 2.days.ago)

      get repository_path(repository, branch: "feature/gone")

      expect(response).to have_http_status(:ok)
      expect(trajectory_panel).to have_no_css("#suite-trajectory-branches")
      expect(trajectory_panel).to have_text("No branch to plot a history on", normalize_ws: true)
      expect(trajectory_panel.find("#suite-trajectory-branch-fallback")).to have_text(
        "SpecGuard has no runs on feature/gone. The latest run named no branch, so there is still " \
        "no history to draw.", normalize_ws: true
      )
    end
  end

  # Criterion 3: the caption's plotted/withheld counts equal direct SQL over the same window.
  #
  # Recomputed here from the database rather than from `SuiteTrajectory`, so this cannot be
  # satisfied by the panel agreeing with itself. The SQL selects the same window the model does —
  # branch-scoped, bounded, ordered by the same key — and the selection rule is re-derived in plain
  # Ruby from the rows it returns.
  it "states counts that agree with direct SQL over the same window" do
    repository = create_repository(user: @user)
    3.times { |i| sharded_run(repository, commit_sha: "whole#{i}0000000", per_shard: 5_000 + i) }
    ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_020,
                 commit_sha: "inflight9999")
    run(repository, "zeroooo0000", total: 0, at: 1.minute.ago)
    run(repository, "otherbranch", branch: "feature/x", total: 999, at: 1.minute.ago)

    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT r.total_specs_count,
             (SELECT COUNT(*) FROM test_run_shards s WHERE s.test_run_id = r.id) AS shards
      FROM test_runs r
      WHERE r.repository_id = #{repository.id} AND r.branch = 'main'
      ORDER BY r.created_at DESC, r.id DESC
      LIMIT #{Repository::TRAJECTORY_LIMIT}
    SQL
    measured = rows.select { |row| row["total_specs_count"].to_i.positive? }
    dominant = measured.group_by { |row| row["shards"] }.values.max_by(&:size)
    expected_plotted = dominant.size
    expected_unmeasured = rows.size - measured.size
    expected_mismatched = measured.size - expected_plotted

    get repository_path(repository)

    expect(expected_plotted).to eq(3)
    expect(expected_unmeasured).to eq(1)
    expect(expected_mismatched).to eq(1)
    expect(chart).to have_text("#{expected_plotted} of #{rows.size} runs plotted", normalize_ws: true)
    expect(plotted_rows.size).to eq(expected_plotted)
    expect(chart).to have_css("svg circle", count: expected_plotted, visible: :all)
    expect(basis_line).to have_text(
      "Drawn through #{expected_plotted} of the last #{rows.size} runs on main", normalize_ws: true
    )
    expect(basis_line).to have_text("#{expected_unmeasured} run is withheld for having reported no tests",
                                    normalize_ws: true)
    expect(basis_line).to have_text(
      "#{expected_mismatched} run is withheld for having reported only some of the parts",
      normalize_ws: true
    )
  end

  # Criterion 4: the panel adds ONE query.
  #
  # The absolute "exactly one" is asserted where it can be measured honestly — around the model call
  # itself, in spec/models/repository_spec.rb — for the reason
  # spec/requests/repository_suite_growth_spec.rb gives about its own budget examples: a render
  # against another render has a control walking the same code path, so an implementation that
  # inflated both sides equally leaves the difference intact. What these examples hold is the half
  # that only a page can show: the panel adds no PER-ROW work, however long the branch's history is
  # and however its runs were assembled.
  describe "what the panel costs the page" do
    # `count_queries` comes from spec/support/query_capture.rb.

    it "costs the same however long the branch's history is" do
      repository = create_repository(user: @user)
      3.times { |i| run(repository, "early#{i}00000", total: 1_000 + i, at: (30 - i).days.ago) }

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(chart).to have_css("svg circle", count: 3, visible: :all)

      # Well inside the thirty-row bound, so every one of these becomes a plotted point.
      20.times { |i| run(repository, "later#{i.to_s.rjust(6, "0")}", total: 1_100 + i, at: (25 - i).days.ago) }

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      expect(chart).to have_css("svg circle", count: 23, visible: :all)
    end

    # The same budget with a branch ASKED for, which is the request that added work: an anchor
    # lookup and a branch list. Both are bounded, and the two axes that could unbound them pull in
    # different directions — more runs on the branch (which the capped counts must not follow) and
    # more branches to choose from (which the index walk must not turn into a query each). Neither
    # moves the count.
    it "costs the same with a branch asked for, however much history and however many branches" do
      repository = create_repository(user: @user)
      3.times { |i| run(repository, "early#{i}00000", total: 1_000 + i, at: (30 - i).days.ago) }

      get repository_path(repository, branch: "main")
      baseline = count_queries { get repository_path(repository, branch: "main") }
      expect(chart).to have_css("svg circle", count: 3, visible: :all)

      20.times { |i| run(repository, "later#{i.to_s.rjust(6, "0")}", total: 1_100 + i, at: (25 - i).days.ago) }
      10.times { |i| run(repository, "side#{i}0000000", branch: "feature/#{i}", total: 5, at: 40.days.ago) }

      expect(count_queries { get repository_path(repository, branch: "main") }).to eq(baseline)
      expect(chart).to have_css("svg circle", count: 23, visible: :all)
      expect(basis_line).to have_text("Drawn through 23 of the last 23 runs on main", normalize_ws: true)
    end

    # The N+1 that would otherwise ship green. Every route to a run's composition —
    # `shard_count`, `assembled_like?`, `delivery_description` — goes through a memoized
    # per-INSTANCE `pick`, so asking thirty points is thirty queries, and it would stay invisible
    # until a repository's history became sharded. Which is exactly the history this panel exists
    # to be careful about.
    #
    # Verified by mutation: dropping the correlated `(SELECT COUNT(*) FROM test_run_shards …)`
    # from `Repository#suite_size_trajectory` and letting each point ask for itself turns both
    # examples in this block red — this one by the eight sharded runs added below — and leaves
    # every other example in this file green.
    it "asks how the runs were assembled once for the whole panel, not once per point" do
      repository = create_repository(user: @user)
      # The newest run is held fixed across both measurements, deliberately: the Overview above
      # reads `latest_test_run` and its predecessor through their OWN unprimed shard aggregates, so
      # a change there would be absorbed into this difference and hide it.
      10.times { |i| run(repository, "plain#{i}00000", total: 20_000 + i, at: (30 - i).days.ago) }

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(chart).to have_css("svg circle", count: 10, visible: :all)

      # Eight sharded runs and thirty-two shard rows, aged back behind the plain ones so the newest
      # run — and therefore the Overview — is untouched, and so the plain cohort stays the one the
      # line is drawn through.
      8.times { |i| sharded_run(repository, commit_sha: "shard#{i}0000000", per_shard: 5_000) }
      TestRun.where.not(ci_run_id: nil).update_all(created_at: 40.days.ago)

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      # Still the ten plain points, and the eight sharded rows are now inside the window and counted
      # as withheld — so the extra rows really were loaded, and really were free.
      expect(chart).to have_css("svg circle", count: 10, visible: :all)
      expect(basis_line).to have_text("8 runs are withheld", normalize_ws: true)
    end
  end

  # Read-only suite telemetry, outside the `keys.manage` gate — the same class of information as
  # the Overview and the Recent-runs panel. Nothing here is credential metadata and nothing here
  # actions anything.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    run(repository, "aaaaaaa1111", total: 1_000, at: 2.days.ago)
    run(repository, "bbbbbbb2222", total: 1_047, at: 1.hour.ago)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb])
  end

  # == The second line: what the same runs COST
  #
  # Every row the size line is drawn through already carried its own `duration_seconds`, unread. The
  # panel could say the suite has 20,013 tests and grew by 47; it could not say whether last month's
  # run waited 40s.
  describe "the wall-clock line" do
    def runtime_chart = trajectory_panel.find("#suite-trajectory-runtime-chart")

    # ELEMENT-scoped for the reason `basis_line` is: the two basis paragraphs in this panel share
    # most of their vocabulary, and a panel-level matcher would read one for the other.
    def runtime_basis = trajectory_panel.find("#suite-trajectory-runtime-basis")

    def runtime_summary = trajectory_panel.find("#suite-trajectory-runtime-chart-summary")

    def runtime_rows
      runtime_chart.all("details table tbody tr", visible: :all).map do |row|
        row.all("td", visible: :all).map { |cell| cell.text(:all).strip }
      end
    end

    def timed_run(repository, commit, seconds:, total: 1_000, branch: "main", at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                   annotated_specs_count: total / 4, duration_seconds: seconds,
                                   created_at: at)
    end

    # Criterion 1: the line goes through the same runs as the size line, and every plotted figure is
    # the run's own `duration_seconds`.
    it "draws each plotted run's wall clock beside the suite's size" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, total: 1_000, at: 20.days.ago)
      timed_run(repository, "bbbbbbb2222", seconds: 61.5, total: 1_020, at: 10.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(runtime_chart).to have_css("svg circle", count: 3, visible: :all)
      expect(runtime_rows).to eq([["aaaaaaa", "40.2s", "20 days ago"],
                                  ["bbbbbbb", "1m 2s", "10 days ago"],
                                  ["ccccccc", "1m 14s", "about 1 hour ago"]])
      # The same three runs the size line drew through, so the two lines cannot describe different
      # cohorts on the same page.
      expect(plotted_labels).to eq(%w[aaaaaaa bbbbbbb ccccccc])
    end

    # The text alternative IS the chart for a reader who cannot see the line, so it needs the same
    # preconditions the plot is given. The summary paragraph above the disclosure states which
    # branch, how many runs, that the axis does not start at zero, and — here — that a point is the
    # slowest single shard rather than machine time. A sighted reader passes that paragraph on the
    # way down to the rows; a reader landing on the table by navigation gets the header row and
    # bare numbers with none of it unless the table names it.
    #
    # Asserted on BOTH charts of one page, because the association is derived from the caller's
    # `id:`: two instances resolving to one summary would describe each chart with the other's
    # sentence, and a single-chart assertion cannot see that.
    it "points each chart's table at that chart's own summary" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, total: 1_000, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      # `visible: :all` because both tables sit in a collapsed `<details>`.
      size_table = chart.find("details table", visible: :all)
      runtime_table = runtime_chart.find("details table", visible: :all)
      expect(size_table[:"aria-describedby"]).to eq("suite-trajectory-chart-summary")
      expect(runtime_table[:"aria-describedby"]).to eq("suite-trajectory-runtime-chart-summary")
      # Each id has to resolve, or the attribute is a reference to nothing — which announces exactly
      # as much as having no attribute while looking, in the markup, like the defect is fixed.
      expect(chart_summary[:id]).to eq(size_table[:"aria-describedby"])
      expect(runtime_summary[:id]).to eq(runtime_table[:"aria-describedby"])
      # And they resolve to two DIFFERENT sentences, which is the whole reason the seam is
      # per-instance rather than a constant.
      expect(chart_summary.text).not_to eq(runtime_summary.text)
    end

    # Criterion 3: markers are durations and never "74 tests" — which is exactly what the component
    # announced before it stopped naming the unit.
    it "announces every marker as a duration and never as a count of tests" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      titles = runtime_chart.all("svg circle title", visible: :all).map { |t| t.text(:all) }
      expect(titles).to eq(["aaaaaaa — 40.2s — 2 days ago",
                            "ccccccc — 1m 14s — about 1 hour ago"])
      expect(titles.join).not_to include("test")
      # And the suite-size chart is untouched by the generalization: same figure, same noun.
      expect(chart.all("svg circle title", visible: :all).map { |t| t.text(:all) })
        .to eq(["aaaaaaa — 1,000 tests — 2 days ago", "ccccccc — 1,047 tests — about 1 hour ago"])
    end

    # Criterion 3 again, at the seam rather than at the output. `TestRun#duration_label` is the one
    # place this column is worded — "the same float cannot render two ways on one page" — and the
    # chart is the third reader. `74.25` reaching the page as `74.25s` or `74.3 s` would be a fourth
    # spelling; it renders as `1m 14s` because it went through the same method the Recent-runs cell
    # does.
    it "words its figures through the one formatter this column has" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      newest = repository.test_runs.order(:created_at).last
      expect(newest.duration_label).to eq("1m 14s")
      expect(runtime_rows.last[1]).to eq(newest.duration_label)
      expect(runtime_chart).to have_text(newest.duration_label)
    end

    # Criterion 4: the defect the integer coercion produced. 74.25 → 74.80 is a real 0.55s
    # regression; coerced it is 74 → 74, drawn down the middle of the plot and described as a wait
    # that "has not moved".
    it "draws a sub-second regression as a slope and does not call it unmoved" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 74.25, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.80, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      ys = runtime_chart.all("svg circle", visible: :all).map { |circle| circle[:cy].to_f }
      expect(ys.uniq.size).to eq(2)
      expect(ys.first).to be > ys.last
      expect(ys).not_to include(UI::SparklineComponent::VIEWBOX_HEIGHT / 2.0)
      expect(runtime_basis).to have_no_text("has not moved")
    end

    # Criterion 4's own blind spot, deferred out of SPGD-226 and closed here. `74.25 → 74.80`
    # straddles a rounding boundary, so it words as two different strings and the guard above passes
    # whether or not the text alternative can carry the movement. `74.25 → 74.30` does not straddle
    # one: `humanized_seconds` drops the tenth at a minute and above, so both points word `1m 14s`.
    # The line separates them either way — that is the float preservation criterion 4 pins — and
    # before this the table did not, so a reader working from the numbers read "unmoved" off a line
    # that moved.
    it "keeps two runtimes the line separates distinguishable on the text alternative" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 74.25, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.30, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      ys = runtime_chart.all("svg circle", visible: :all).map { |circle| circle[:cy].to_f }
      expect(ys.uniq.size).to eq(2)

      older, newer = repository.test_runs.order(:created_at).to_a
      figures = runtime_rows.map { |row| row[1] }
      # The wording is untouched and still single-sourced — this is the collision, asked of the seam
      # itself rather than asserted as a literal, and the disclosure sits BESIDE it rather than
      # replacing it.
      expect(older.duration_label).to eq(newer.duration_label)
      expect(figures).to all(include(newer.duration_label))
      # …and the two rows no longer say the same thing.
      expect(figures.uniq.size).to eq(2)
      expect(figures).to eq(["1m 14s (74.25)", "1m 14s (74.3)"])
    end

    # The other half of that rule, and the half a careless implementation breaks: two runs that
    # waited the SAME 74.25s are not an ambiguity. The line draws them at one height on purpose, so
    # one figure printed twice is the truth about them, and a float disclosed beside it would be
    # noise printed to separate two things that are not different.
    it "words two runs that waited the same time once, with nothing disclosed beside it" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 74.25, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      newest = repository.test_runs.order(:created_at).last
      expect(runtime_rows.map { |row| row[1] }).to eq([newest.duration_label] * 2)
      expect(runtime_chart).to have_no_text("(74.25)")
    end

    # Criterion 2. Nullable by design, so a run that measured its suite and sent no clock is an
    # ordinary state — off this line, counted here, and still on the size line above.
    it "withholds an untimed run by name while leaving it on the size line" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, total: 1_000, at: 20.days.ago)
      timed_run(repository, "silentcc222", seconds: nil, total: 1_020, at: 10.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(runtime_rows.map(&:first)).to eq(%w[aaaaaaa ccccccc])
      expect(plotted_labels).to eq(%w[aaaaaaa silentcc ccccccc].map { |sha| sha.first(7) })
      expect(runtime_chart).to have_text("2 of 3 plotted runs timed")
      expect(runtime_basis)
        .to have_text("1 run is withheld from this line for having reported no timing at all",
                      normalize_ws: true)
      expect(runtime_basis).to have_text("remains on the suite-size line above", normalize_ws: true)
    end

    # THE DEFECT, driven end to end through the recorder rather than hand-primed — the whole reason
    # the sharded examples in this file go through `Ingest::RunRecorder`: `duration_seconds` being a
    # MAX over the shards that REPORTED is a shape the RECORDER produces, and a fixture that wrote
    # the run row by hand would be agreeing with itself about the number under test.
    #
    # Three runs of four shards each. Two timed all four at 60s; the newest had its two slowest
    # cancelled before they reported, so its MAX is 18s. Identical `shard_count`, identical
    # `suite_size_measured?` — so `assembled_like?` is true and the run is on the SIZE line — and
    # before the timing guard the wall-clock chart drew a 70% speed-up produced entirely by
    # telemetry loss, on the same page load where the Overview panel above it withheld its scalar
    # delta over the same pair.
    it "withholds a run whose shards did not all report a clock, at equal shard count" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "aaaafull1111", per_shard: 5_000, seconds: 60.0)
      sharded_run(repository, commit_sha: "bbbbfull2222", per_shard: 5_010, seconds: 61.0)
      partial = sharded_run(repository, commit_sha: "ccccpart3333", per_shard: 5_020,
                            seconds: 18.0, timed_shards: 2)

      # The state under test, asserted before the page is read: the recorder really did produce a
      # run whose clock is a maximum over half its shards. Without this the example could pass on a
      # fixture that never built the shape.
      expect(partial.shard_count).to eq(4)
      expect(partial.timed_shard_count).to eq(2)
      expect(partial.duration_seconds).to eq(18.0)

      get repository_path(repository)

      # Off the wall-clock line...
      expect(runtime_rows.map(&:first)).to eq(%w[aaaaful bbbbful])
      # ...and still on the size line above, which is the shape of the whole fix.
      expect(plotted_labels).to eq(%w[aaaaful bbbbful ccccpar])
      expect(runtime_chart).to have_text("2 of 3 plotted runs timed the same number of shards")
      expect(runtime_basis)
        .to have_text("1 run reported a wall clock over a different number of shards than the " \
                      "runs on this line", normalize_ws: true)
      # Named by its own cause, and NOT as the other one. A run that timed two of its four shards
      # did time; filing it under "reported no timing at all" would name the wrong cause on a page
      # whose entire job is naming causes.
      expect(runtime_basis).to have_no_text("reported no timing at all")
    end

    # The line's own basis, in this panel's register. A wall clock on a sharded run is its SLOWEST
    # SHARD and not what the suite cost in machine time, and a reader who takes it for the latter
    # under-reads a four-shard suite by 3.4×.
    it "states that a point is the run's wait and not the suite's machine time" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: 40.2, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(runtime_basis).to have_text("Drawn through 2 of the 2 runs", normalize_ws: true)
      expect(runtime_basis).to have_text("on main", normalize_ws: true)
      expect(runtime_basis).to have_text("slowest single shard and not the machine time",
                                         normalize_ws: true)
    end

    # `plottable?` does not imply `runtime_plottable?`. The panel is not empty — the size line is
    # drawn — so this is one sentence about what was reported rather than an empty state.
    it "says why there is no line rather than drawing a flat one through a single clock" do
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: nil, total: 1_000, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_css("#suite-trajectory-chart")
      expect(trajectory_panel).to have_no_css("#suite-trajectory-runtime-chart")
      expect(runtime_basis).to have_text("1 of the 2 plotted runs reported one, and a trajectory " \
                                         "needs 2", normalize_ws: true)
    end

    # The count above reads correctly whether it is counted off `timed` or typed in as a literal,
    # because with a threshold of two the shortfall branch can only be reached by exactly one timed
    # run. That makes the assertion above unable to fail on the thing most likely to be wrong — so
    # this moves the threshold and asks the same sentence again. A hard-coded "1 … needs two" prints
    # a FALSE count here: two runs reported a clock, and the sentence explaining the shortfall would
    # say one did.
    it "counts the shortfall off the timed runs rather than assuming the threshold is two" do
      stub_const("SuiteTrajectory::MINIMUM_POINTS", 3)
      repository = create_repository(user: @user)
      timed_run(repository, "aaaaaaa1111", seconds: nil, total: 1_000, at: 3.days.ago)
      timed_run(repository, "bbbbbbb2222", seconds: 40.2, total: 1_020, at: 2.days.ago)
      timed_run(repository, "ccccccc3333", seconds: 74.25, total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_no_css("#suite-trajectory-runtime-chart")
      # Split from the threshold word deliberately: the COUNT is the half that can state a falsehood
      # about the cohort, so it is pinned on its own and a failure here names which half drifted.
      expect(runtime_basis).to have_text("2 of the 3 plotted runs reported one", normalize_ws: true)
      expect(runtime_basis).to have_text("a trajectory needs 3", normalize_ws: true)
    end

    # The same shortfall sentence, reached by the OTHER cause — and the case where its verb is the
    # half that can lie. `timed` withholds on two grounds now, so a shortfall can be produced by
    # runs that every one of them reported a clock; "N of the M plotted runs reported one" is then
    # false about its own subject, in the one sentence whose whole job is explaining why the reader
    # is being shown less than they asked for.
    #
    # The ticket's scenario at two runs, which is the shortest way in: two 4-shard runs whose timed
    # counts are 4 and 2. Both cohorts are size one, the tie goes to the most recent, so exactly one
    # run is on the line and the other is held by `withheld_timing_mismatch`. Driven through the
    # recorder rather than hand-primed, for the reason the sharded examples above are: the partial
    # MAX is a shape the RECORDER produces.
    it "names a denominator mismatch as the cause when it is why there is no line" do
      repository = create_repository(user: @user)
      full = sharded_run(repository, commit_sha: "aaaafull1111", per_shard: 5_000, seconds: 60.0)
      partial = sharded_run(repository, commit_sha: "bbbbpart2222", per_shard: 5_010,
                            seconds: 18.0, timed_shards: 2)

      # The state under test, asserted before the page is read: both runs reported a clock, over
      # different denominators, at an identical shard count. Without this the example could pass on
      # a fixture that built the ordinary untimed shortfall instead.
      expect([full.shard_count, partial.shard_count]).to eq([4, 4])
      expect([full.timed_shard_count, partial.timed_shard_count]).to eq([4, 2])
      expect([full.duration_reported?, partial.duration_reported?]).to eq([true, true])

      get repository_path(repository)

      # The size line above is drawn — this is a shortfall on one axis, not an empty panel.
      expect(trajectory_panel).to have_css("#suite-trajectory-chart")
      expect(trajectory_panel).to have_no_css("#suite-trajectory-runtime-chart")
      expect(plotted_labels).to eq(%w[aaaaful bbbbpar])
      expect(runtime_basis).to have_text("1 of the 2 plotted runs timed the same number of shards",
                                         normalize_ws: true)
      expect(runtime_basis).to have_text("a trajectory needs 2", normalize_ws: true)
      # The falsifying half. Both of these runs reported a clock, so the unqualified verb this
      # sentence carries in the untimed case is a false sentence here — and it is the sentence the
      # page prints the moment the cause branch is removed.
      expect(runtime_basis).to have_no_text("reported one")
    end

    it "says so plainly when no plotted run reported a clock at all" do
      repository = create_repository(user: @user)
      run(repository, "aaaaaaa1111", total: 1_000, at: 2.days.ago)
      run(repository, "ccccccc3333", total: 1_047, at: 1.hour.ago)

      get repository_path(repository)

      expect(trajectory_panel).to have_no_css("#suite-trajectory-runtime-chart")
      expect(runtime_basis).to have_text("none of the 2 plotted runs reported one",
                                         normalize_ws: true)
    end

    # Criterion 6. The rows were already loaded and already carried the column, so a second series
    # over them is free — which is the argument for reading it here rather than anywhere else.
    it "costs no query per plotted point" do
      # `count_queries` comes from spec/support/query_capture.rb — the same rule the block above
      # counts by. What a render-against-render budget can and cannot show is argued there; this
      # example holds the per-point half of it.
      #
      # THREE points on the control side rather than two, and the third one is load-bearing. "Areas
      # that grew or shrank over the window" compares the newest run of this window against the
      # OLDEST one it can use, and on a two-run branch that is the same pair the last-push panel
      # above it compares — the identical statement, served from the query cache and therefore not
      # a round trip this rule counts. Grown to ten points it becomes a different pair and a real
      # query, so a two-point control would read one query lighter than the grown page for a reason
      # that has nothing to do with plotted points, and this example would report a per-point cost
      # that is not there. Both sides of the comparison hold three or more runs, so that neighbour
      # costs exactly one query on each and the difference measured is the trajectory's own.
      repository = create_repository(user: @user)
      3.times { |i| timed_run(repository, "seed#{i}0000000", seconds: 40.0 + i, at: (20 - i).days.ago) }
      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(runtime_chart).to have_css("svg circle", count: 3, visible: :all)

      8.times { |i| timed_run(repository, "more#{i}0000000", seconds: 50.0 + i, at: (10 - i).days.ago) }

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      expect(runtime_chart).to have_css("svg circle", count: 11, visible: :all)
    end
  end
end
