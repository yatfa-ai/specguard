# frozen_string_literal: true

require "rails_helper"

# The "Areas that grew over the window" panel on repositories#show — which AREAS of the suite moved
# across the branch's last-thirty-runs window, as opposed to since the last push.
#
# Its own file rather than more examples beside the last-push panel's, for the reason that file
# states for itself: every example here needs a MULTI-run fixture on one branch where the endpoints
# and the middle disagree, and the rules this panel turns on — the baseline WALK, and what happens
# when it steps over runs — belong to this panel alone.
#
# == The two properties every fixture below is built to separate
#
# 1. **This panel is not the panel above it.** Where both are on the page, the fixtures make them
#    print DIFFERENT numbers, and several examples assert both. A window comparison that quietly
#    read the previous run would be green under any fixture whose window is two runs long, so no
#    fixture here is two runs long except the ones testing exactly that.
# 2. **It compares two ENDPOINTS and not a series.** The middle of the window is deliberately
#    hostile: runs whose counts swing far past both ends, so an implementation that summed movements
#    run-to-run, or ranked on any intermediate row, produces numbers that appear nowhere below.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder` because the shapes this panel turns on are shapes the RECORDER
# produces: a run with a `total_specs_count` and no per-example rows is what a client that posts only
# totals writes, and a sharded run beside an unsharded one is what makes two runs incomparable.
RSpec.describe "Repository spec directory window growth", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-directory-window-growth")

  def panel? = Capybara.string(response.body).has_css?("#spec-directory-window-growth")

  # ELEMENT-scoped, never panel-scoped. Eight states render inside this panel and seven of them are
  # sentences sharing most of their words ("no comparison to draw", "this window"), so a
  # panel-level `have_text` passes for the wrong state with the deciding branch deleted.
  def basis_text = panel.find("#spec-directory-window-growth-basis").text.gsub(/\s+/, " ").strip

  def empty_state_text = panel.find("[class*='border-dashed']").text.gsub(/\s+/, " ").strip

  # The panel BESIDE this one — the last-push comparison. Read here so the examples can assert that
  # the two panels answer differently over the same fixture, which is the whole claim of shipping a
  # second one.
  def push_rows
    Capybara.string(response.body).find("#spec-directory-growth").all("tbody tr").to_h do |row|
      cells = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      [cells.first, cells.last]
    end
  end

  def rows
    panel.all("tbody tr").map do |row|
      path, baseline, now, change = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, baseline: baseline, now: now, change: change,
        reading: row.all("td").last["aria-label"] }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  def row_for(path) = rows.find { |row| row[:path] == path }

  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  # One run on the wire, stamped so the window's order is the fixture's order rather than the
  # order the rows happened to be inserted in. `specs:` omitted entirely — not `specs: []` — is the
  # client that reports totals and no per-example detail.
  def ingest(repository, sha, specs: nil, branch: "main", total: nil, shard_id: nil, minutes_ago: 0,
             **attrs)
    payload = { commit_sha: sha, branch: branch, total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
    repository.test_runs.find_by!(commit_sha: sha)
              .tap { |run| run.update!(created_at: minutes_ago.minutes.ago) }
  end

  # A run that reported a count of zero: measured by nothing, and one of the two conditions the
  # baseline walk steps over.
  def unmeasured_run(repository, sha, minutes_ago:, branch: "main")
    repository.test_runs.create!(commit_sha: sha, branch: branch, total_specs_count: 0,
                                 created_at: minutes_ago.minutes.ago)
  end

  # `count` examples in one area, at line numbers that cannot collide within their run. `offset` is
  # what keeps two runs' example ids from lining up: a correspondence between runs is the one thing
  # this panel never claims, so no fixture here supplies one.
  def area_specs(directory, count, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: "#{directory}/a_spec.rb", line_number: offset + i + 1, duration: 0.1)
    end
  end

  # Four runs on one branch, and the fixture the panel exists for: `spec/models` gains ONE example
  # per run and `spec/legacy` sheds one. Neither is ever the biggest mover of any single push — the
  # last-push panel reads +1 and −1 — and across the window they are +3 and −3.
  def creeping_window
    repository = new_repository
    ingest(repository, "one0000000001", minutes_ago: 240,
                       specs: area_specs("spec/models", 2) + area_specs("spec/legacy", 6, offset: 100))
    ingest(repository, "two0000000002", minutes_ago: 180,
                       specs: area_specs("spec/models", 3, offset: 200) +
                              area_specs("spec/legacy", 5, offset: 300))
    ingest(repository, "three000000003", minutes_ago: 120,
                       specs: area_specs("spec/models", 4, offset: 400) +
                              area_specs("spec/legacy", 4, offset: 500))
    ingest(repository, "four0000000004", minutes_ago: 60,
                       specs: area_specs("spec/models", 5, offset: 600) +
                              area_specs("spec/legacy", 3, offset: 700))

    repository
  end

  describe "a window with a comparable baseline" do
    # THE example this panel ships for. Both panels are on the page over the same fixture and they
    # print different numbers: the push moved each area by one, the window moved them by three.
    it "measures each area across the window rather than since the last push" do
      get repository_path(creeping_window)

      expect(row_for("spec/models")).to include(baseline: "2", now: "5", change: "+3")
      expect(row_for("spec/legacy")).to include(baseline: "6", now: "3", change: "−3")
      expect(push_rows).to eq("spec/models" => "+1", "spec/legacy" => "−1")
    end

    # Ranked by ABSOLUTE movement across the window, in both directions — a `DESC`-only ranking on
    # the signed change puts every deletion below every addition and off the end of the cap.
    it "ranks by how far each area moved across the window, in both directions" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 120,
                         specs: area_specs("spec/models", 2) + area_specs("spec/legacy", 9, offset: 100) +
                                area_specs("spec/system", 1, offset: 200))
      ingest(repository, "two0000000002", minutes_ago: 60,
                         specs: area_specs("spec/models", 5, offset: 300) +
                                area_specs("spec/legacy", 1, offset: 400) +
                                area_specs("spec/system", 1, offset: 500))

      get repository_path(repository)

      expect(row_paths).to eq(["spec/legacy", "spec/models", "spec/system"])
      expect(row_for("spec/system")).to include(change: "±0")
    end

    # WHICH run the figure was taken against — the sentence with no counterpart on the panel above,
    # where the comparand is "the previous run" and there is only one candidate. Commit, distance
    # and age, because "26 runs back" is a week on one branch and a quarter on another.
    it "names the run it compared against, how far back it is, and how old it is" do
      get repository_path(creeping_window)

      expect(basis_text).to include("Measured against one0000")
      expect(basis_text).to include("3 runs back in this window")
      expect(basis_text).to match(/4 hours ago — and this run/)
      expect(basis_text).to include("It spans all 4 runs of this window on main.")
    end

    # The limitation a thirty-run heading would otherwise imply away, asserted as a sentence rather
    # than assumed from the code.
    it "states that what happened between the two ends is not shown" do
      get repository_path(creeping_window)

      expect(basis_text).to include("Only the two ends are compared")
      expect(basis_text).to include("grew and shrank back to where it started")
    end

    # The rename disclosure, which is STRONGER across a window than across one push: a reader can
    # remember last week's rename and cannot be expected to remember every rename in thirty runs.
    it "discloses that a moved test reads as growth in one area and shrinkage in another" do
      get repository_path(creeping_window)

      expect(basis_text).to match(/MOVED is the same test/)
      expect(basis_text).to include("with nothing added and nothing deleted")
      expect(basis_text).to include("that rename may be one nobody remembers")
    end

    # Every figure is counted off the rows the two ENDS wrote, never off `total_specs_count`.
    it "states what it was counted over" do
      get repository_path(creeping_window)

      expect(basis_text).to include("All 2 areas either end of this window recorded")
      expect(basis_text).to include("8 and 8 example rows the two ends recorded here")
      expect(basis_text).to include("may legitimately differ")
    end

    # U+2212 and `±` are announced inconsistently across screen readers, and the direction has to
    # name the BASELINE: a reader told this is a change since the last push has the wrong figure,
    # not a vaguer one.
    it "spells the movement out for a screen reader, against the baseline and not the last push" do
      get repository_path(creeping_window)

      expect(row_for("spec/models")[:reading])
        .to eq("3 examples more than the baseline run of this window")
      expect(row_for("spec/legacy")[:reading])
        .to eq("3 examples fewer than the baseline run of this window")
    end

    # The ranking is by movement descending and the list is capped, so an unmoved area appears only
    # once the movement has run out — which makes a list headed "the areas that moved most" contain
    # rows that moved by nothing. The caption says which, and says it ONLY where it is true of the
    # rows on the page: asserted in both directions, because a clause that is always printed is not
    # a description of anything.
    it "does not claim the movement ran out where every listed area moved" do
      get repository_path(creeping_window)

      expect(rows.map { |row| row[:change] }).to eq(["−3", "+3"])
      expect(basis_text).not_to include("did not move are listed too")
    end

    it "carries the caption to the table it describes" do
      get repository_path(creeping_window)

      expect(panel.find("table")["aria-describedby"]).to eq("spec-directory-window-growth-basis")
    end

    # An area only one END has says so rather than differencing against a zero that was never a
    # measurement of it — and over a window that reading matters more, because the area may have
    # existed in the middle of it.
    it "names an area the baseline did not record rather than differencing it from a zero" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 120, specs: area_specs("spec/models", 3))
      ingest(repository, "two0000000002", minutes_ago: 60,
                         specs: area_specs("spec/models", 3, offset: 100) +
                                area_specs("spec/system", 4, offset: 200))

      get repository_path(repository)

      expect(row_for("spec/system")).to include(baseline: "0", now: "4", change: "New area")
      expect(row_for("spec/system")[:reading])
        .to eq("4 examples, an area the baseline run did not record")
    end

    # The list is capped, so its own length says nothing about how much of the comparison it covers.
    # The total is a count of GROUPS taken before the cap — thirteen here, a figure neither end
    # alone could produce.
    it "says the list is the head of a longer one, and how long" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 120, specs: area_specs("spec/gone", 1))
      ingest(repository, "two0000000002", minutes_ago: 60,
                         specs: (0..11).flat_map { |i| area_specs("spec/d#{i}", i + 1, offset: i * 100) })

      get repository_path(repository)

      expect(rows.size).to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(basis_text).to include("The 10 areas that moved most across this window, of the 13")
    end
  end

  # The property that separates this panel from a sum of pushes, and the one a reader is owed in
  # words: two endpoints are two measurements, not a trajectory.
  describe "when the movement happened inside the window" do
    it "reads an area that grew and shrank back as an area that did not move, and says so" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 180, specs: area_specs("spec/models", 3))
      ingest(repository, "two0000000002", minutes_ago: 120, specs: area_specs("spec/models", 300, offset: 100))
      ingest(repository, "three000000003", minutes_ago: 60, specs: area_specs("spec/models", 3, offset: 1_000))

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("No area moved across this window")
      expect(empty_state_text).to include("grew and shrank back in between")
      # And the panel beside it, over the same fixture, reports the 297 examples that just left.
      expect(push_rows).to eq("spec/models" => "−297")
    end
  end

  # The walk: the baseline is the OLDEST run of the window that can be compared against this one,
  # so the comparison spans as much of the window as is sound — and the reader is told when that is
  # less than the window itself, because a shorter comparison under a thirty-run heading is a wrong
  # measurement rather than a vague one.
  describe "when the far end of the window cannot be compared against" do
    # Five runs: the oldest reported no tests, the next was sharded where this one is whole, and the
    # walk lands on the third. The comparison is +3 (2 → 5) and never +4, which is what reading the
    # oldest row regardless would have produced.
    def walked_window
      repository = new_repository
      unmeasured_run(repository, "zero0000000000", minutes_ago: 300)
      ingest(repository, "shard000000001", minutes_ago: 240, ci_run_id: "gha-1", shard_id: "0",
                         specs: area_specs("spec/models", 1))
      ingest(repository, "base0000000002", minutes_ago: 180, specs: area_specs("spec/models", 2, offset: 100))
      ingest(repository, "mid00000000003", minutes_ago: 120, specs: area_specs("spec/models", 9, offset: 200))
      ingest(repository, "head0000000004", minutes_ago: 60, specs: area_specs("spec/models", 5, offset: 300))

      repository
    end

    it "walks past the runs it cannot compare and measures from the first one it can" do
      get repository_path(walked_window)

      expect(row_for("spec/models")).to include(baseline: "2", now: "5", change: "+3")
      expect(basis_text).to include("Measured against base000")
      expect(basis_text).to include("2 runs back in this window")
    end

    # A window is a promise about depth, so a comparison spanning less of it says by how much — and
    # names each reason separately, because a client that stopped reporting totals and a branch
    # whose sharding changed are two different things to go and fix.
    it "says how much of the window the comparison spans, and why it is not all of it" do
      get repository_path(walked_window)

      expect(basis_text).to include("It spans 3 of the last 5 runs on main")
      expect(basis_text).to include("the 2 older runs could not be compared against this one")
      expect(basis_text).to include("1 reported no tests and 1 was assembled from a different " \
                                    "number of parts")
    end

    # A single stepped-over run says "it", because the sentence has already counted it: "the 1 older
    # run could not be compared — 1 reported no tests" counts one run twice in eleven words, and the
    # reader goes looking for the second one.
    it "says why one stepped-over run was stepped over without counting it twice" do
      repository = new_repository
      unmeasured_run(repository, "zero0000000000", minutes_ago: 240)
      ingest(repository, "base0000000001", minutes_ago: 180, specs: area_specs("spec/models", 2))
      ingest(repository, "head0000000002", minutes_ago: 60, specs: area_specs("spec/models", 5, offset: 100))

      get repository_path(repository)

      expect(basis_text).to include("It spans 2 of the last 3 runs on main: the 1 older run could " \
                                    "not be compared against this one — it reported no tests.")
    end
  end

  # Seven reasons there is no comparison, said APART rather than collapsed into one blank panel.
  # Four of them are this panel's own, because its comparand is CHOSEN rather than given.
  describe "when there is no comparison to draw" do
    it "says the window has only one run yet, without calling it a fault" do
      repository = new_repository
      ingest(repository, "only0000000001", minutes_ago: 60, specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(empty_state_text).to include("No window to compare across yet")
      expect(empty_state_text).to include("one run in the window so far")
    end

    it "says so where this run reported no tests" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 120, specs: area_specs("spec/models", 3))
      unmeasured_run(repository, "head0000000002", minutes_ago: 60)

      get repository_path(repository)

      expect(empty_state_text).to include("This run reported no tests")
    end

    it "says so where every earlier run in the window reported no tests" do
      repository = new_repository
      unmeasured_run(repository, "one0000000001", minutes_ago: 180)
      unmeasured_run(repository, "two0000000002", minutes_ago: 120)
      ingest(repository, "head0000000003", minutes_ago: 60, specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(empty_state_text).to include("Every one of the 2 earlier runs in this window on main " \
                                          "reported no tests")
      expect(empty_state_text).to include("has a count but not a measurement")
    end

    # The state that would otherwise produce a wrong NUMBER per AREA rather than an honest absence.
    # This run's own composition is named, so the reader is told what the earlier runs would have
    # had to match.
    it "says so where no earlier run was assembled the way this one was" do
      repository = new_repository
      ingest(repository, "one0000000001", minutes_ago: 120, ci_run_id: "gha-1", shard_id: "0",
                         specs: area_specs("spec/models", 4))
      ingest(repository, "head0000000002", minutes_ago: 60, specs: area_specs("spec/models", 2, offset: 100))

      get repository_path(repository)

      expect(empty_state_text).to include("The 1 earlier run in this window on main was not " \
                                          "assembled the way this run was")
      expect(empty_state_text).to include("reported in one piece")
    end

    # Both walk rejections in one window: the composition sentence is about the runs it describes,
    # and the runs rejected before it ever got there are counted separately rather than folded in.
    it "counts the runs that never reached the composition question separately" do
      repository = new_repository
      unmeasured_run(repository, "zero0000000001", minutes_ago: 180)
      ingest(repository, "one0000000002", minutes_ago: 120, ci_run_id: "gha-1", shard_id: "0",
                         specs: area_specs("spec/models", 4))
      ingest(repository, "head0000000003", minutes_ago: 60, specs: area_specs("spec/models", 2, offset: 100))

      get repository_path(repository)

      expect(empty_state_text).to include("A further 1 run in the window reported no tests at all")
    end

    # The condition neither comparability predicate covers and which is decidable only from the
    # rows: a run that posts totals and no per-example detail is fully "measured" and has nothing
    # here, so an ungated comparison renders the whole suite as new.
    #
    # The walk does NOT step over it — that would cost a query per candidate — so the panel names
    # the run it landed on and says what it found there, rather than silently comparing against a
    # nearer run the reader was never told about.
    it "says so where the run it landed on recorded no per-example detail" do
      repository = new_repository
      ingest(repository, "base0000000001", minutes_ago: 180, total: 40)
      ingest(repository, "mid00000000002", minutes_ago: 120, specs: area_specs("spec/models", 3))
      ingest(repository, "head0000000003", minutes_ago: 60, specs: area_specs("spec/models", 5, offset: 100))

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("The run this comparison landed on (base000, 2 back in " \
                                          "this window) recorded no per-example detail")
      expect(empty_state_text).to include("every area of this run would read as new")
    end

    it "says so where this run recorded no per-example detail" do
      repository = new_repository
      ingest(repository, "base0000000001", minutes_ago: 120, specs: area_specs("spec/models", 3))
      ingest(repository, "head0000000002", minutes_ago: 60, total: 40)

      get repository_path(repository)

      expect(empty_state_text).to include("every area of the earlier run would read as deleted")
    end

    it "says so where neither end recorded per-example detail" do
      repository = new_repository
      ingest(repository, "base0000000001", minutes_ago: 120, total: 40)
      ingest(repository, "head0000000002", minutes_ago: 60, total: 42)

      get repository_path(repository)

      expect(empty_state_text).to include("Neither this run nor base000, the run at the far end of " \
                                          "this window")
    end

    # The seven states share a title and most of their words, so an implementation rendering one
    # sentence for all of them would satisfy every example above that only checked the shared half.
    # This pins that the two absences of the SAME window are kept apart: "every earlier run reported
    # no tests" and "the run it landed on recorded no per-example rows".
    it "keeps the two absences of the same window apart" do
      unmeasured = new_repository
      unmeasured_run(unmeasured, "one0000000001", minutes_ago: 120)
      ingest(unmeasured, "head0000000002", minutes_ago: 60, specs: area_specs("spec/models", 3))
      get repository_path(unmeasured)
      reported_nothing = empty_state_text

      unrecorded = new_repository
      ingest(unrecorded, "one0000000001", minutes_ago: 120, total: 40)
      ingest(unrecorded, "head0000000002", minutes_ago: 60, specs: area_specs("spec/models", 3))
      get repository_path(unrecorded)

      expect(empty_state_text).not_to eq(reported_nothing)
    end
  end

  # What the panel costs the page, in EVERY state — including the ones that render no table, which
  # is where an implementation that queried first and gated afterwards would show up.
  describe "what the panel costs the page" do
    # THIS panel's own statements, picked out of everything the page asked. The per-run
    # `COUNT(*) FILTER (WHERE test_run_id = ...)` shape belongs to the two cross-run growth reads;
    # the `SUM(duration_seconds)` exclusion drops the runtime one, and naming the BASELINE's id is
    # what separates this read from the last-push read beside it — which counts the same way over
    # the previous run. A selector that matched both would stop being a measurement of this gate.
    def window_aggregates(baseline, &)
      executed_sql(&).select do |sql|
        sql.include?("FILTER (WHERE test_run_id = #{baseline.id})") && sql.exclude?("SUM(duration_seconds)")
      end
    end

    # ONE query for the whole comparison, however long the window and however large the suite. The
    # baseline walk itself reads nothing: the window is already loaded for the chart, and
    # `assembled_like?` reads the shard count `Repository#suite_size_trajectory` primed onto every
    # point of it.
    it "costs one query over a five-run window, and no more over a ten-run one" do
      short = new_repository
      base = ingest(short, "base0000000001", minutes_ago: 300, specs: area_specs("spec/models", 4))
      (1..4).each do |i|
        ingest(short, "run#{i}0000000000", minutes_ago: 300 - (i * 30),
                      specs: area_specs("spec/models", 4 + i, offset: i * 100))
      end
      get repository_path(short)
      expect(window_aggregates(base) { get repository_path(short) }.size).to eq(1)

      long = new_repository
      long_base = ingest(long, "base0000000001", minutes_ago: 600, specs: area_specs("spec/models", 4))
      (1..9).each do |i|
        ingest(long, "run#{i}0000000000", minutes_ago: 600 - (i * 30),
                     specs: area_specs("spec/models", 4 + i, offset: i * 100))
      end
      get repository_path(long)

      expect(window_aggregates(long_base) { get repository_path(long) }.size).to eq(1)
      expect(row_for("spec/models")).to include(baseline: "4", now: "13")
    end

    # Where the window IS one push long the two panels ask the identical question, and the page pays
    # for it once: the repeat is a query-cache hit and no round trip. `executed_sql` drops cached
    # statements for exactly that reason, so this counts what the page actually spent.
    it "adds no round trip where the window comparison is the last-push comparison" do
      repository = new_repository
      base = ingest(repository, "base0000000001", minutes_ago: 120, specs: area_specs("spec/models", 2))
      ingest(repository, "head0000000002", minutes_ago: 60, specs: area_specs("spec/models", 5, offset: 100))
      get repository_path(repository)

      expect(window_aggregates(base) { get repository_path(repository) }.size).to eq(1)
      expect(row_for("spec/models")).to include(change: "+3")
    end

    # The four states decidable from the loaded runs alone cost the page NOTHING, because the gate
    # runs before the query rather than filtering its results.
    #
    # Measured against a page where the LAST-PUSH panel is comparable and issues its own aggregate,
    # so this is a claim about this gate rather than about the page going quiet: the window is drawn
    # on `?branch=`, and the branch asked for holds runs that cannot be compared while the
    # repository's newest run sits on a branch whose pair can.
    it "asks the observations table nothing where the window has no baseline" do
      repository = new_repository
      stale = unmeasured_run(repository, "stale000000001", minutes_ago: 300, branch: "feature")
      ingest(repository, "feat0000000002", minutes_ago: 240, branch: "feature",
                         specs: area_specs("spec/models", 3))
      ingest(repository, "main0000000003", minutes_ago: 120, specs: area_specs("spec/models", 4, offset: 100))
      ingest(repository, "main0000000004", minutes_ago: 60, specs: area_specs("spec/models", 6, offset: 200))
      get repository_path(repository, branch: "feature")

      statements = window_aggregates(stale) { get repository_path(repository, branch: "feature") }

      expect(statements).to be_empty
      expect(empty_state_text).to include("reported no tests")
      # The page did ask its OTHER cross-run question, so the silence above is this gate's.
      expect(push_rows).to eq("spec/models" => "+2")
    end
  end

  # Read-only suite telemetry, like every panel around it: a `view` member legitimately needs to see
  # what CI reported.
  it "is visible to a member with only 'view'" do
    repository = creeping_window
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(row_for("spec/models")).to include(change: "+3")
  end
end
