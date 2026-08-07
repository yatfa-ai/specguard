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
  def ingest_shard(repository, ci_run_id:, shard_id:, total:, commit_sha:, branch: "main")
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, ci_run_id: ci_run_id,
        total_specs_count: total, annotated_specs_count: total / 4, duration_seconds: 60.0 },
      shard_id: shard_id
    )
  end

  def sharded_run(repository, commit_sha:, per_shard: 5_000, shards: 4)
    shards.times do |i|
      ingest_shard(repository, ci_run_id: "gha-#{commit_sha}", shard_id: i.to_s,
                   total: per_shard, commit_sha: commit_sha)
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
end
