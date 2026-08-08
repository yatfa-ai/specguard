# frozen_string_literal: true

require "rails_helper"

# The "Areas that got slower or faster" panel on repositories#show — which AREAS of the suite
# changed how long they take, between the latest run and the previous run ON THE SAME BRANCH.
#
# Its own file rather than more examples in spec/requests/repository_spec_directory_growth_spec.rb,
# for the reason that file gives one panel up: every example here needs a two-run fixture whose two
# runs differ in SECONDS, where every example there needs one whose runs differ in EXAMPLE COUNT.
# The two are independent quantities — that independence is the reason this panel exists — so a
# fixture built for one of them says nothing about the other.
#
# == What this panel is, in one sentence, and what it must never become
#
# It sums `spec_observations.duration_seconds` per area per run and subtracts two numbers. It
# matches no examples between the runs, and it must not — `example_id` is positional and not stable
# across refactors. And it never reads `test_runs.duration_seconds`: that is a run's wall clock, a
# MAX over shard reports with no area grain at all. The examples below are written so that nothing
# about a per-example correspondence could make them pass — the two runs' examples sit at different
# line numbers throughout — and so that the run-level wall clock is constant across every fixture,
# which means any implementation reaching for it produces zeroes where these expect movement.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder` because the shapes this panel turns on are shapes the RECORDER
# produces: a run with a `total_specs_count` and no per-example rows is what a client posting only
# totals writes, a run whose specs carry no `duration` is what a client that reports outcomes and
# no timings writes, and `total_specs_count` climbing shard by shard is what makes two runs
# incomparable. A hand-built fixture can trivially produce a pair that agrees with itself in ways
# CI never does — the trap SPGD-91 names.
RSpec.describe "Repository spec directory runtime growth", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-directory-runtime-growth")

  def panel? = Capybara.string(response.body).has_css?("#spec-directory-runtime-growth")

  # The COUNT panel next door, read in the two examples that exist to show the two panels disagree.
  def count_panel = Capybara.string(response.body).find("#spec-directory-growth")

  # ELEMENT-scoped, never panel-scoped. Ten states render inside this panel and nine of them are
  # sentences sharing most of their words ("no comparison to draw", "the previous run on this
  # branch") — so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted. Every assertion below names the element it means.
  def basis_line = panel.find("#spec-directory-runtime-growth-basis")

  # Whitespace-normalised, because the caption is a paragraph of ERB whose source line breaks are
  # not the sentence's — an assertion against the raw text would pin the template's indentation.
  def basis_text = basis_line.text.gsub(/\s+/, " ").strip

  # The empty state's own text, so "the panel said why" can never be satisfied by the caption.
  def empty_state = panel.find("[class*='border-dashed']")

  def empty_state_text = empty_state.text.gsub(/\s+/, " ").strip

  # Several examples build more than one repository, and `github_full_name` is unique per owner.
  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  # One row as a reader meets it: the area, both totals, the movement between them, and what each
  # total was summed over.
  def rows
    panel.all("tbody tr").map do |row|
      path, then_time, now_time, change, timed = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, then: then_time, now: now_time, change: change, timed: timed,
        reading: row.all("td")[3]["aria-label"] }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  def row_for(path) = rows.find { |row| row[:path] == path }

  # One run on the wire. The run-level `duration_seconds` is FIXED at 60.0 for every run every
  # fixture builds, deliberately: it is the wall clock the Overview panel differences, it has no
  # area grain, and an implementation that reached for it instead of summing these rows would
  # report every area as `±0` throughout this file.
  #
  # `specs:` omitted entirely — not `specs: []` — is the client that reports totals and no
  # per-example detail, one of the states this panel keeps apart from a suite that went quiet.
  def ingest(repository, commit_sha:, specs: nil, branch: "main", total: nil, shard_id: nil, **attrs)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
  end

  # `count` examples in one area, each taking `each` seconds, at line numbers that cannot collide
  # within their run. `each: nil` is the example a client reported without a timing.
  #
  # `offset` is what keeps the two runs' example ids from lining up: a correspondence between the
  # runs is the one thing this panel never claims, so no fixture here supplies one.
  #
  # Every duration in this file is a sum of negative powers of two, so the totals asserted below are
  # exact in binary and the assertions are about the panel rather than about float formatting.
  def area_specs(directory, count, each: 1.0, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: "#{directory}/a_spec.rb", line_number: offset + i + 1, duration: each)
    end
  end

  # Two runs on one branch, the earlier one first so `previous_test_run_on_branch` finds it.
  def two_runs(previous_specs:, latest_specs:, **latest_attrs)
    repository = new_repository
    ingest(repository, commit_sha: "prev00000000001", specs: previous_specs)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(repository, commit_sha: "late00000000002", specs: latest_specs, **latest_attrs)

    repository
  end

  describe "two comparable runs" do
    # THE fixture, and the whole reason this slice exists: **not one area's example count changes.**
    #
    # `spec/models` holds two examples in both runs and went from 2.00s to 10.00s — somebody made an
    # existing spec eight seconds slower. `spec/legacy` holds four in both and got a second faster.
    # `spec/system` is untouched. Every area's `ABS(latest_count - previous_count)` is 0, so the
    # panel next door correctly reports that nothing moved, and every count-shaped read of these two
    # runs is blind to the regression.
    def slowed_suite
      two_runs(
        previous_specs: area_specs("spec/models", 2, each: 1.0) +
                        area_specs("spec/legacy", 4, each: 0.5, offset: 100) +
                        area_specs("spec/system", 1, each: 0.25, offset: 200),
        latest_specs: area_specs("spec/models", 2, each: 5.0, offset: 300) +
                      area_specs("spec/legacy", 4, each: 0.25, offset: 400) +
                      area_specs("spec/system", 1, each: 0.25, offset: 500)
      )
    end

    it "names each area's time then, its time now, and the movement between them" do
      get repository_path(slowed_suite)

      expect(row_for("spec/models")).to include(then: "2.00s", now: "10.00s", change: "+8.00s")
      expect(row_for("spec/legacy")).to include(then: "2.00s", now: "1.00s", change: "−1.00s")
    end

    # The success criterion, asserted as the comparison it is: the same two runs, on the same page,
    # rendered into two panels — and the area that got eight seconds slower is NAMED here while the
    # count panel beside it says, correctly, that no area moved. This is the example that fails if
    # this panel is ever collapsed into the count one.
    it "names the slowed area on a page where the count panel says nothing moved" do
      get repository_path(slowed_suite)

      expect(row_for("spec/models")).to include(then: "2.00s", now: "10.00s", change: "+8.00s")
      expect(count_panel).to have_no_css("tbody tr")
      expect(count_panel.text).to include("No area moved")
    end

    # The ranking's whole claim, and the one a `DESC`-only ordering on the signed change fails: a
    # second SHED from an area answers "which areas changed pace" as much as eight seconds added.
    it "ranks by how far each area's time moved, in both directions" do
      get repository_path(slowed_suite)

      expect(row_paths).to eq(["spec/models", "spec/legacy", "spec/system"])
    end

    # An area whose time did not move is a real answer and renders as one — `±0`, not a blank cell
    # and not `+0.00s`, which claims a direction it does not have.
    it "says so of an area whose time did not move rather than leaving the cell empty" do
      get repository_path(slowed_suite)

      expect(row_for("spec/system")).to include(then: "0.25s", now: "0.25s", change: "±0")
    end

    # Every total states what it was summed over, on both sides. `SUM` skips NULLs silently, so a
    # figure covering a third of an area is otherwise indistinguishable from one covering all of it.
    it "states how much of each side each total was summed over" do
      get repository_path(slowed_suite)

      expect(row_for("spec/legacy")[:timed]).to eq("4 of 4 → 4 of 4")
    end

    # U+2212 and `±` are announced inconsistently across screen readers — from "minus" to nothing at
    # all — and four figures in a row announce as four unattached numbers. So the direction and what
    # it was measured against are spelled out on the cell.
    it "spells the movement out for a screen reader" do
      get repository_path(slowed_suite)

      expect(row_for("spec/models")[:reading])
        .to eq("8.00s slower than the previous run on this branch")
      expect(row_for("spec/legacy")[:reading])
        .to eq("1.00s faster than the previous run on this branch")
      expect(row_for("spec/system")[:reading])
        .to eq("took the same time as it did in the previous run on this branch")
    end

    # HAZARD 1, at the surface. An area none of whose examples were timed on a side sums to SQL
    # NULL, and NULL is not zero: rendering it `0.00s` would invent a measurement, and ranking it
    # first — which is what `DESC` alone does in Postgres — would name the area nobody measured the
    # biggest mover in the suite, above a real four-second regression.
    #
    # Both halves asserted, because they fail independently: the cell says "not reported", and the
    # row sits BELOW the area that actually moved.
    it "says an untimed side is not reported, and never ranks it above an area that moved" do
      repository = two_runs(
        previous_specs: area_specs("spec/quiet", 3, each: 1.0) +
                        area_specs("spec/models", 1, each: 1.0, offset: 100),
        latest_specs: area_specs("spec/quiet", 3, each: nil, offset: 200) +
                      area_specs("spec/models", 1, each: 5.0, offset: 300)
      )

      get repository_path(repository)

      expect(row_paths).to eq(["spec/models", "spec/quiet"])
      expect(row_for("spec/quiet")).to include(then: "3.00s", now: "not reported", change: "Not timed")
      expect(row_for("spec/quiet")[:timed]).to eq("3 of 3 → 0 of 3")
    end

    # The same row read aloud, and the sentence that matters most on this whole panel: the reason
    # there is nothing to compare is the REPORTING, not the code. A reader who met only "Not timed"
    # beside a fallen total could reasonably conclude the area got faster.
    #
    # Both fixtures keep ONE area timed on the quiet side, deliberately: a run that timed nothing at
    # all is a different state entirely (`:previous_untimed` / `:latest_untimed`, asserted below),
    # and this example is about a run that reported timings and skipped an area.
    it "tells a screen reader which run went quiet rather than implying a speedup" do
      repository = two_runs(
        previous_specs: area_specs("spec/quiet", 2, each: 4.0) +
                        area_specs("spec/models", 1, each: 1.0, offset: 50),
        latest_specs: area_specs("spec/quiet", 2, each: nil, offset: 100) +
                      area_specs("spec/models", 1, each: 1.0, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/quiet")[:reading])
        .to eq("this run reported no timing for this area, so there is nothing to compare")
      expect(basis_text).to include("Areas one of the two runs reported no timing for are listed last")
    end

    it "names the earlier run as the quiet one where it is the earlier run that went quiet" do
      repository = two_runs(
        previous_specs: area_specs("spec/quiet", 2, each: nil) +
                        area_specs("spec/models", 1, each: 1.0, offset: 50),
        latest_specs: area_specs("spec/quiet", 2, each: 4.0, offset: 100) +
                      area_specs("spec/models", 1, each: 1.0, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/quiet")[:reading])
        .to eq("the previous run on this branch reported no timing for this area, " \
               "so there is nothing to compare")
    end

    # An area the earlier run never recorded is NEW, and saying `+4.00s` of it would read identically
    # to an existing area that got four seconds slower — the one distinction a reader scanning this
    # column most needs. Both totals stay visible beside it, so naming the state loses no magnitude.
    it "names an area the previous run did not have rather than differencing it from a zero" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 2, each: 1.0),
        latest_specs: area_specs("spec/models", 2, each: 1.0, offset: 100) +
                      area_specs("spec/system", 2, each: 2.0, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/system")).to include(then: "not reported", now: "4.00s", change: "New area")
      expect(row_for("spec/system")[:reading])
        .to eq("4.00s of examples, an area the previous run did not record")
    end

    # An area can be BOTH new and untimed, and the two facts are said as two facts: "not reported of
    # examples" is not a sentence, and a reader who met it would be reconciling a template rather
    # than reading a row.
    it "keeps 'new area' and 'no timing' apart on an area that is both" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 2, each: 1.0),
        latest_specs: area_specs("spec/models", 2, each: 1.0, offset: 100) +
                      area_specs("spec/system", 2, each: nil, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/system")).to include(then: "not reported", now: "not reported", change: "New area")
      expect(row_for("spec/system")[:reading])
        .to eq("an area the previous run did not record, and this run reported no timing for it")
      # And the caption's "Not timed" clause stays off the page: it describes a run that ran an area
      # and did not time it, which is a different row from an area a run never had. The cell says
      # "New area"; a sentence about missing timings would be describing something else entirely.
      expect(basis_text).not_to include("reported no timing for are listed last")
    end

    it "names an area that is gone rather than differencing it to a zero" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 2, each: 1.0) +
                        area_specs("spec/legacy", 2, each: 2.0, offset: 100),
        latest_specs: area_specs("spec/models", 2, each: 1.0, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/legacy")).to include(then: "4.00s", now: "not reported", change: "Area removed")
      expect(row_for("spec/legacy")[:reading]).to eq("4.00s of examples in the previous run and none now")
    end

    # The caption's load-bearing claims, each asserted rather than assumed — including the one only
    # this grain has: how much of EACH run was timed, as a fraction, so a total summed over a
    # fraction of a run cannot read as a total summed over all of it.
    it "states its window, its two runs, and how much of each run was timed" do
      get repository_path(slowed_suite)

      expect(basis_text).to include("All 3 areas either run recorded")
      expect(basis_text).to include("previous run on this branch")
      expect(basis_text).to include("prev000")
      expect(basis_text).to include("Summed off the 7 of 7 and 7 of 7 example rows")
      expect(basis_text).to include("that reported a timing")
    end

    # The other half of that sentence, and the one that stops a reader reconciling this panel
    # against the Overview delta and finding a discrepancy that is not one: the wall clock up there
    # is a MAX over shards, these figures are a SUM over rows, and they are not the same quantity.
    it "states that the totals are the runs' own rows and not the wall clock above" do
      get repository_path(slowed_suite)

      expect(basis_text).to include("never the run wall clock")
      expect(basis_text).to include("maximum over the run's shards")
    end

    # HAZARD 4, carried over from the panel above unchanged: a MOVED test is the same test, so a
    # rename reads here as one area gaining time and another losing the same, with nothing having
    # got slower. The page cannot tell the two apart, so it says so.
    it "discloses that a moved test reads as time gained in one area and lost in another" do
      get repository_path(slowed_suite)

      expect(basis_text).to match(/moved.*same test/i)
      expect(basis_text).to include("with nothing having got slower and nothing faster")
    end

    # The caption is a claim ABOUT the table, so it is carried to a screen-reader user landing on
    # the table by navigation — who otherwise meets the header row with none of it.
    it "carries the caption to the table it describes" do
      get repository_path(slowed_suite)

      expect(panel.find("table")["aria-describedby"]).to eq("spec-directory-runtime-growth-basis")
    end

    # Two clauses that must appear only where they are TRUE of the rows on the page. A clause that
    # is always printed describes nothing, so both are asserted in both directions.
    it "does not claim the movement ran out where every listed area moved" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 1, each: 1.0) +
                        area_specs("spec/legacy", 1, each: 4.0, offset: 100),
        latest_specs: area_specs("spec/models", 1, each: 8.0, offset: 200) +
                      area_specs("spec/legacy", 1, each: 1.0, offset: 300)
      )

      get repository_path(repository)

      expect(rows.map { |row| row[:change] }).to eq(["+7.00s", "−3.00s"])
      expect(basis_text).not_to include("did not move are listed too")
      expect(basis_text).not_to include("reported no timing for are listed last")
    end

    it "says the movement ran out only where the list actually shows an unmoved area" do
      get repository_path(slowed_suite)

      expect(basis_text).to include("areas whose time did not move are listed too, as ±0")
    end

    # The list is capped, so its own length says nothing about how much of the comparison it covers
    # — and the total has to come from a count of GROUPS taken before the cap, not from the rows on
    # hand, which are exactly the ten the cap left.
    #
    # Twelve areas in both runs and a thirteenth only the previous run has. Deliberately not equal
    # to any single area's row count, because a `COUNT(*)` where the window total belongs reads the
    # leading GROUP's size, and a fixture where those coincide is green under exactly that mutation.
    #
    # The fixture carries a second property worth naming. `spec/gone` does not survive the cap, so
    # the previous run's rows for it sit outside the ten on hand — derive the per-run totals from
    # those rows instead of from the window and the panel miscounts what it was summed over.
    it "says the list is the head of a longer one, and how long" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001",
                         specs: (0..11).flat_map { |i| area_specs("spec/d#{i}", 1, each: 1.0, offset: i * 100) } +
                                area_specs("spec/gone", 1, each: 1.0, offset: 5_000))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002",
                         specs: (0..11).flat_map do |i|
                                  area_specs("spec/d#{i}", 1, each: i + 1.0, offset: (i * 100) + 50)
                                end)

      get repository_path(repository)

      expect(rows.size).to eq(SpecObservation::RETIMED_DIRECTORIES_LIMIT)
      expect(basis_text).to include("The 10 areas whose time moved most, of the 13 either run recorded")
      expect(basis_text).to include("Summed off the 13 of 13 and 12 of 12 example rows")
    end

    # HAZARD 3, asserted rather than argued. Two runs of two shards each, where the LATER run had a
    # shard report no timing at all. `shard_count` is equal so `assembled_like?` holds, but
    # `timed_shard_count` differs — so the Overview panel's runtime delta withholds its figure, and
    # correctly: its quantity is a MAX over the shards that REPORTED, and differencing two maxima
    # taken over different denominators fakes a speedup out of telemetry loss.
    #
    # This panel SUMS per-example rows. The vanished shard's timing was never an operand here — the
    # rows carry their own — so there is no MAX to fold and no denominator to compare, and the
    # comparison is sound where the Overview's is not. Both halves asserted on ONE page, because the
    # claim is precisely that these two panels disagree here and are both right.
    #
    # This is what stops a future edit "tidying" the gate by copying the fourth condition across:
    # adding it turns this example red, which is the whole point of writing it down.
    it "still compares where the Overview runtime delta withholds for unequal timed shards" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/models", 2, each: 1.0),
                         ci_run_id: "gha-1", shard_id: "0", duration_seconds: 30.0)
      ingest(repository, commit_sha: "prev00000000001",
                         specs: area_specs("spec/system", 2, each: 1.0, offset: 50),
                         ci_run_id: "gha-1", shard_id: "1", duration_seconds: 30.0)
      repository.test_runs.find_by!(ci_run_id: "gha-1").update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002",
                         specs: area_specs("spec/models", 2, each: 4.0, offset: 100),
                         ci_run_id: "gha-2", shard_id: "0", duration_seconds: 30.0)
      ingest(repository, commit_sha: "late00000000002",
                         specs: area_specs("spec/system", 2, each: 1.0, offset: 150),
                         ci_run_id: "gha-2", shard_id: "1", duration_seconds: nil)

      get repository_path(repository)

      expect(Capybara.string(response.body).find("#overview")).to have_no_css("#runtime-delta")
      expect(row_for("spec/models")).to include(then: "2.00s", now: "8.00s", change: "+6.00s")
      expect(row_for("spec/system")).to include(change: "±0")
    end

    # Two comparable runs whose every area took the same time. A real answer, and the one a reader
    # most wants confirmed — so it is said in words rather than rendered as a table of `±0` under a
    # heading promising areas that changed pace.
    #
    # And it states its COVERAGE rather than an area count, which is the difference between a
    # sentence this state can support and one it cannot: the list is capped, so on a suite where
    # nothing moved anywhere the rows on hand are areas that did not move while an untimed area sits
    # past the cap unseen. "Every one of the N areas took the same time" would then be a claim about
    # areas nobody measured.
    it "says no area changed pace, over the coverage it can claim, rather than tabulating zeroes" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 2, each: 1.0) +
                        area_specs("spec/system", 1, each: 0.5, offset: 100),
        latest_specs: area_specs("spec/models", 2, each: 1.0, offset: 200) +
                      area_specs("spec/system", 1, each: 0.5, offset: 300)
      )

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("No area changed pace")
      expect(empty_state_text).to include("Every area these two runs timed took the same time in both")
      expect(empty_state_text).to include("Summed off the 3 of 3 and 3 of 3 example rows")
      expect(empty_state_text).not_to include("Every one of the")
    end
  end

  # Nine reasons there is no comparison, said APART rather than collapsed into one blank panel.
  # Three of them exist only at this grain — "recorded no per-example rows" and "reported no timings"
  # are the same empty panel, two different things to go and fix, and NOTHING else on this page can
  # tell them apart.
  describe "when the two runs cannot be compared" do
    it "renders no panel at all where there is no earlier run on the branch" do
      repository = new_repository
      ingest(repository, commit_sha: "only00000000001", specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(panel?).to be(false)
    end

    it "says so where this run reported no tests" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/models", 3))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "late00000000002", branch: "main", total_specs_count: 0)

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("This run reported no tests")
    end

    it "says so where the previous run on the branch reported no tests" do
      repository = new_repository
      repository.test_runs.create!(commit_sha: "prev00000000001", branch: "main", total_specs_count: 0,
                                   created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(empty_state_text).to include("previous run on this branch (prev000) reported no tests")
    end

    # HAZARD 3's other half. The gate this panel DOES take: a run's rows arrive shard by shard, so a
    # partial build differenced against a complete one reports every area getting faster. What it
    # does NOT take is the Overview runtime delta's `timed_shard_count` guard, which is the
    # denominator of a MAX — and the two examples in "what the panel costs the page" below are what
    # pin that this panel still renders where that guard would have withheld it.
    it "says so where the two runs were assembled from different numbers of parts" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/models", 4))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", specs: area_specs("spec/models", 2, offset: 100),
                         ci_run_id: "gha-1", shard_id: "0")

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("assembled from 1 shard report")
      expect(empty_state_text).to include("reported in one piece")
    end

    it "says so where the previous run recorded no per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("recorded no per-example detail")
      expect(empty_state_text).to include("every area of this run would read as time newly appearing")
    end

    it "says so where this run recorded no per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/models", 3))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", total: 40)

      get repository_path(repository)

      expect(empty_state_text).to include("every area of the previous run would read as time disappearing")
    end

    # HAZARD 2, and the state this panel exists to name. The run wrote every one of its rows and
    # sent a duration with none of them — so it is fully "recorded", fully "measured", and has
    # nothing to sum. Ungated, every area of the other run reads as a slowdown, or a win, that no
    # commit caused.
    it "says the previous run reported no timings, and how many rows it did record" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 4, each: nil),
        latest_specs: area_specs("spec/models", 4, each: 2.0, offset: 100)
      )

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("reported no timings")
      expect(empty_state_text).to include("recorded 4 examples and a duration for none of them")
      expect(empty_state_text).to include("time newly appearing")
    end

    it "says this run reported no timings rather than letting the suite read as a speedup" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 4, each: 2.0),
        latest_specs: area_specs("spec/models", 4, each: nil, offset: 100)
      )

      get repository_path(repository)

      expect(empty_state_text).to include("This run reported no timings")
      expect(empty_state_text).to include("which is a reporting gap and not a speedup")
    end

    it "says so where neither run reported a timing" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 4, each: nil),
        latest_specs: area_specs("spec/models", 4, each: nil, offset: 100)
      )

      get repository_path(repository)

      expect(empty_state_text).to include("Neither this run nor the previous run on this branch reported a duration")
    end

    it "says so where neither run recorded per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", total: 42)

      get repository_path(repository)

      expect(empty_state_text).to include("recorded per-example detail")
      expect(empty_state_text).to include("there are no areas to time")
    end

    # The nine states share a title and most of their words, so an implementation rendering one
    # sentence for all of them would satisfy every example above that checked only the shared half.
    # This pins the pair NOTHING ELSE on this page distinguishes: the same run, "recorded no
    # per-example rows" against "recorded them and timed none".
    it "keeps a run's two absences apart" do
      unrecorded = new_repository
      ingest(unrecorded, commit_sha: "prev00000000001", total: 40)
      unrecorded.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(unrecorded, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))
      get repository_path(unrecorded)
      recorded_nothing = empty_state_text

      untimed = two_runs(previous_specs: area_specs("spec/models", 3, each: nil),
                         latest_specs: area_specs("spec/models", 3, each: 1.0, offset: 100))
      get repository_path(untimed)

      expect(empty_state_text).not_to eq(recorded_nothing)
      expect(empty_state_text).to include("reported no timings")
      expect(recorded_nothing).to include("recorded no per-example detail")
    end
  end

  # What the panel costs the page, in EVERY state — including the ones that render no table, which
  # is where an implementation that queried first and gated afterwards would show up.
  describe "what the panel costs the page" do
    # `count_queries` comes from spec/support/query_capture.rb.

    # The statements THIS panel issued, picked out of everything the page asked by the one thing
    # only this aggregate does: SUM durations per run with `SUM(duration_seconds) FILTER (WHERE
    # test_run_id = ...)`. The by-directory duration rollup sums durations and groups on the same
    # expression but is scoped to one run and uses no `FILTER`; the count comparison next door
    # `FILTER`s per run but counts rows.
    def runtime_aggregates(&)
      executed_sql(&).select { |sql| sql.include?("SUM(duration_seconds) FILTER (WHERE test_run_id =") }
    end

    # ONE query for the whole comparison, and it does not grow with the suite. Measured as a
    # difference against the same page rendering ten times the examples, so an implementation that
    # read a run's areas per row — or issued a second round trip to count them — shows up here
    # whatever the page's absolute query count happens to be.
    it "costs the same whether the two runs hold thirty examples or three hundred" do
      small = two_runs(previous_specs: area_specs("spec/models", 10, each: 1.0) +
                                       area_specs("spec/system", 5, each: 0.5, offset: 50),
                       latest_specs: area_specs("spec/models", 12, each: 2.0, offset: 100) +
                                     area_specs("spec/system", 3, each: 0.5, offset: 200))
      get repository_path(small)
      baseline = count_queries { get repository_path(small) }
      expect(rows.size).to eq(2)

      large = two_runs(previous_specs: area_specs("spec/models", 100, each: 1.0) +
                                       area_specs("spec/system", 50, each: 0.5, offset: 500),
                       latest_specs: area_specs("spec/models", 120, each: 2.0, offset: 1_000) +
                                     area_specs("spec/system", 30, each: 0.5, offset: 2_000))
      get repository_path(large)

      expect(count_queries { get repository_path(large) }).to eq(baseline)
      expect(rows.size).to eq(2)
    end

    # The three states decidable from the two runs alone cost the page NOTHING, because the gate
    # runs before the query rather than filtering its results. An implementation that queried and
    # then discarded would be green on every rendering example above and one query heavier here on
    # exactly the pages that have nothing to show.
    #
    # Counted as THIS panel's own statement rather than as a page-wide difference of one: several
    # neighbours gate on the same two runs and shed their own reads on the incomparable side too, so
    # a page-wide subtraction would stop being a claim about this gate the moment another arrives.
    it "asks the observations table nothing where the runs are not comparable" do
      comparable = two_runs(previous_specs: area_specs("spec/models", 3, each: 1.0),
                            latest_specs: area_specs("spec/models", 3, each: 2.0, offset: 100))
      get repository_path(comparable)
      expect(runtime_aggregates { get repository_path(comparable) }.size).to eq(1)
      expect(rows.size).to eq(1)

      incomparable = new_repository
      incomparable.test_runs.create!(commit_sha: "prev00000000001", branch: "main", total_specs_count: 0,
                                     created_at: 2.hours.ago)
      ingest(incomparable, commit_sha: "late00000000002", specs: area_specs("spec/models", 5))
      get repository_path(incomparable)

      expect(runtime_aggregates { get repository_path(incomparable) }).to be_empty
      expect(panel).to have_no_css("tbody tr")
    end
  end

  # Read-only suite telemetry, like every panel around it: a `view` member legitimately needs to see
  # what CI reported. Nothing here is credential metadata and nothing here actions anything.
  it "is visible to a member with only 'view'" do
    repository = two_runs(previous_specs: area_specs("spec/models", 2, each: 1.0),
                          latest_specs: area_specs("spec/models", 2, each: 3.0, offset: 100))
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(row_for("spec/models")).to include(change: "+4.00s")
  end
end
