# frozen_string_literal: true

require "rails_helper"

# The "Areas that grew or shrank" panel on repositories#show — which AREAS of the suite moved
# between the latest run and the previous run ON THE SAME BRANCH.
#
# Its own file rather than more examples in spec/requests/repository_spec_directory_durations_spec.rb,
# for the reason that file states for itself one panel up: every example here needs the same
# TWO-run fixture, where every panel there needs a one-run one. It is also the file that would have
# to change if the comparability rules changed, and those belong to this panel alone.
#
# == What this panel is, in one sentence, and what it must never become
#
# It compares two POPULATIONS: how many rows each area holds in run A against how many it holds in
# run B. It matches no examples between the runs, and it must not — `example_id` is positional and
# not stable across refactors, which is why every sibling panel is scoped to a single run. The
# examples below are written so that nothing about a per-example correspondence could make them
# pass: the two runs' examples sit at different line numbers throughout, so any implementation that
# tried to pair rows would produce different numbers from the ones asserted here.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder` because the shapes this panel turns on are shapes the RECORDER
# produces: a run with a `total_specs_count` and no per-example rows is what a client that posts
# only totals writes, and `total_specs_count` climbing shard by shard is what makes two runs
# incomparable. A hand-built fixture can trivially produce a pair that agrees with itself in ways
# CI never does — the trap SPGD-91 names, and the one the sibling growth spec was green under.
RSpec.describe "Repository spec directory growth", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-directory-growth")

  def panel? = Capybara.string(response.body).has_css?("#spec-directory-growth")

  # ELEMENT-scoped, never panel-scoped. Six states render inside this panel and five of them are
  # sentences sharing most of their words ("no comparison to draw", "the previous run on this
  # branch") — so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted. Every assertion below names the element it means.
  def basis_line = panel.find("#spec-directory-growth-basis")

  # Whitespace-normalised, because the caption is a paragraph of ERB whose source line breaks are
  # not the sentence's — an assertion against the raw text would be pinning the template's
  # indentation rather than what it says.
  def basis_text = basis_line.text.gsub(/\s+/, " ").strip

  def basis? = panel.has_css?("#spec-directory-growth-basis")

  # The empty state's own text, so "the panel said why" can never be satisfied by the caption.
  def empty_state = panel.find("[class*='border-dashed']")

  def empty_state_text = empty_state.text.gsub(/\s+/, " ").strip

  # Several examples build more than one repository, and `github_full_name` is unique per owner.
  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  # One row as a reader meets it: the area, both operands, and the movement between them.
  def rows
    panel.all("tbody tr").map do |row|
      path, then_count, now_count, change = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, then: then_count, now: now_count, change: change,
        reading: row.all("td").last["aria-label"] }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  def row_for(path) = rows.find { |row| row[:path] == path }

  # One run on the wire. `specs:` omitted entirely — not `specs: []` — is the client that reports
  # totals and no per-example detail, which is one of the states this panel exists to keep apart
  # from a suite that was deleted.
  def ingest(repository, commit_sha:, specs: nil, branch: "main", total: nil, shard_id: nil, **attrs)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
  end

  # `count` examples in one area, at line numbers that cannot collide within their run. `offset`
  # is what keeps the two runs' example ids from lining up: a correspondence between the runs is
  # the one thing this panel never claims, so no fixture here supplies one.
  def area_specs(directory, count, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: "#{directory}/a_spec.rb", line_number: offset + i + 1, duration: 0.1)
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
    # `spec/models` gained 3, `spec/legacy` LOST 5, `spec/system` did not move. Built so the
    # ranking's whole claim is testable: the biggest movement in the suite is a deletion, so a
    # panel ranking the signed change puts `spec/legacy` last instead of first.
    def moved_suite
      two_runs(
        previous_specs: area_specs("spec/models", 2) + area_specs("spec/legacy", 6, offset: 100) +
                        area_specs("spec/system", 1, offset: 200),
        latest_specs: area_specs("spec/models", 5, offset: 300) + area_specs("spec/legacy", 1, offset: 400) +
                      area_specs("spec/system", 1, offset: 500)
      )
    end

    it "names each area's count then, its count now, and the movement between them" do
      get repository_path(moved_suite)

      expect(row_for("spec/models")).to include(then: "2", now: "5", change: "+3")
      expect(row_for("spec/legacy")).to include(then: "6", now: "1", change: "−5")
    end

    # THE assertion the panel exists for, and the one a `DESC`-only ranking on the signed change
    # fails: the largest movement in this suite is a loss of five, and it has to head the list.
    it "ranks by how far each area moved, in both directions" do
      get repository_path(moved_suite)

      expect(row_paths).to eq(["spec/legacy", "spec/models", "spec/system"])
    end

    # An area that did not move is a real answer and renders as one — `±0`, not a blank cell and
    # not `+0`, which claims a direction it does not have.
    it "says so of an area that did not move rather than leaving the cell empty" do
      get repository_path(moved_suite)

      expect(row_for("spec/system")).to include(then: "1", now: "1", change: "±0")
    end

    # The ranking is by movement descending and the list is capped, so an unmoved area appears only
    # once the movement has run out — which makes a list headed "the areas that moved most" contain
    # rows that moved by nothing. The caption says which, and says it ONLY where it is true of the
    # rows on the page: asserted in both directions, because a clause that is always printed is not
    # a description of anything.
    it "says the movement ran out only where the list actually shows an unmoved area" do
      get repository_path(moved_suite)

      expect(basis_text).to include("areas that did not move are listed too, as ±0")
    end

    it "does not claim the movement ran out where every listed area moved" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 2) + area_specs("spec/legacy", 6, offset: 100),
        latest_specs: area_specs("spec/models", 5, offset: 300) + area_specs("spec/legacy", 1, offset: 400)
      )

      get repository_path(repository)

      expect(rows.map { |row| row[:change] }).to eq(["−5", "+3"])
      expect(basis_text).not_to include("did not move are listed too")
    end

    # U+2212 and `±` are announced inconsistently across screen readers — from "minus" to nothing
    # at all — and three numbers in a row announce as three unattached numbers. So the direction
    # and what it was measured against are spelled out on the cell.
    it "spells the movement out for a screen reader" do
      get repository_path(moved_suite)

      expect(row_for("spec/legacy")[:reading])
        .to eq("5 examples fewer than the previous run on this branch")
      expect(row_for("spec/models")[:reading])
        .to eq("3 examples more than the previous run on this branch")
      expect(row_for("spec/system")[:reading]).to eq("unchanged since the previous run on this branch")
    end

    # An area the earlier run never recorded is NEW, and saying `+4` of it would read identically
    # to an existing area that gained four tests — the one distinction a reader scanning this
    # column most needs. Both operands stay visible beside it, so naming the state loses nothing.
    it "names an area the previous run did not have rather than differencing it from a zero" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 3),
        latest_specs: area_specs("spec/models", 3, offset: 100) + area_specs("spec/system", 4, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/system")).to include(then: "0", now: "4", change: "New area")
      expect(row_for("spec/system")[:reading])
        .to eq("4 examples, an area the previous run did not record")
    end

    it "names an area that is gone rather than differencing it to a zero" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 3) + area_specs("spec/legacy", 4, offset: 100),
        latest_specs: area_specs("spec/models", 3, offset: 200)
      )

      get repository_path(repository)

      expect(row_for("spec/legacy")).to include(then: "4", now: "0", change: "Area removed")
      expect(row_for("spec/legacy")[:reading]).to eq("4 examples in the previous run and none now")
    end

    # The caption's three load-bearing claims, each asserted rather than assumed.
    it "states how many areas the comparison covered, and what it was measured over" do
      get repository_path(moved_suite)

      expect(basis_text).to include("All 3 areas either run recorded")
      expect(basis_text).to include("previous run on this branch")
      expect(basis_text).to include("prev000")
    end

    # Constraint 5, and the disclosure that separates a figure a reader can act on from one they
    # will act on wrongly: a MOVED test is the same test, so a rename reads here as one area
    # growing and another shrinking with nothing added and nothing deleted. The page cannot tell
    # the two apart, so it says so.
    it "discloses that a moved test reads as growth in one area and shrinkage in another" do
      get repository_path(moved_suite)

      expect(basis_text).to match(/moved.*same test/i)
      expect(basis_text).to include("with nothing added and nothing deleted")
    end

    # Every figure is counted off the rows these two runs WROTE, never off `total_specs_count` —
    # which is re-derived by SUM over shard reports and can legitimately differ. The caption has to
    # say which, or a reader reconciles it against the Overview panel and finds a discrepancy that
    # is not one.
    it "states that the counts are the runs' own rows and not the suite size above" do
      get repository_path(moved_suite)

      expect(basis_text).to include("example rows the two runs recorded here")
      expect(basis_text).to include("may legitimately differ")
    end

    # The caption is a claim ABOUT the table, so it is carried to a screen-reader user landing on
    # the table by navigation — who otherwise meets the header row with none of it.
    it "carries the caption to the table it describes" do
      get repository_path(moved_suite)

      expect(panel.find("table")["aria-describedby"]).to eq("spec-directory-growth-basis")
    end

    # The list is capped, so its own length says nothing about how much of the comparison it
    # covers — and the total has to come from a count of GROUPS taken before the cap, not from the
    # rows on hand, which are exactly the ten the cap left.
    #
    # Twelve areas in the latest run and one only the previous run has: thirteen, a figure neither
    # run alone could produce. And deliberately not equal to any single area's row count — the
    # heaviest area here holds twelve — because a `COUNT(*)` where the window total belongs reads
    # the leading GROUP's size, and a fixture where those two numbers coincide is green under
    # exactly that mutation.
    #
    # The fixture carries a second property worth naming, because it is the one that makes this
    # example guard more than a caption. `spec/gone` moved by one and does NOT survive the cap — so
    # the previous run's entire recorded population sits outside the ten rows on hand. Derive the
    # per-run totals from those rows instead of from the window and the panel does not merely
    # miscount: it reads the previous run as having recorded nothing and withholds the whole
    # comparison. Verified by mutation — this example is what turns red.
    it "says the list is the head of a longer one, and how long" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/gone", 1))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002",
                         specs: (0..11).flat_map { |i| area_specs("spec/d#{i}", i + 1, offset: i * 100) })

      get repository_path(repository)

      expect(rows.size).to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(basis_text).to include("The 10 areas that moved most, of the 13 either run recorded")
    end

    # Two comparable runs whose areas all hold the same number of examples. A real answer, and the
    # one a reader most wants confirmed — so it is said in words rather than rendered as a table of
    # `±0` under a heading promising areas that grew or shrank.
    it "says nothing moved rather than tabulating a column of zeroes" do
      repository = two_runs(
        previous_specs: area_specs("spec/models", 3) + area_specs("spec/system", 2, offset: 100),
        latest_specs: area_specs("spec/models", 3, offset: 200) + area_specs("spec/system", 2, offset: 300)
      )

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("No area moved")
      expect(empty_state_text).to include("Every one of the 2 areas")
    end
  end

  # Five reasons there is no comparison, said APART rather than collapsed into one blank panel.
  # They are not one fact: "the earlier run reported no tests" and "the earlier run recorded no
  # per-example rows" produce the same empty panel and are two different things to go and fix, and
  # only the second is invisible everywhere else on this page.
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

    # The state that would otherwise produce a wrong NUMBER rather than an honest absence, and here
    # it would produce one per AREA. A run's rows arrive shard by shard, so a sharded build
    # differenced against a complete one reports every area shrinking. Both compositions are named,
    # through the same `TestRun#delivery_description` the Overview panel words this with.
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

    # The condition neither comparability predicate covers, and the one this grain adds. A run that
    # posts totals and no per-example detail is fully "measured" by both of them and has zero rows
    # here — so an ungated comparison renders the entire suite as deleted, area by area, on a page
    # that has just certified both runs as comparable.
    it "says so where the previous run recorded no per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("recorded no per-example detail")
      expect(empty_state_text).to include("every area of this run would read as new")
    end

    it "says so where this run recorded no per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: area_specs("spec/models", 3))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", total: 40)

      get repository_path(repository)

      expect(empty_state_text).to include("every area of the previous run would read as deleted")
    end

    it "says so where neither run recorded per-example detail" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", total: 42)

      get repository_path(repository)

      expect(empty_state_text).to include("Neither this run nor the previous run")
    end

    # The five states share a title and most of their words, so an implementation that rendered one
    # sentence for all of them would satisfy every example above that only checked the shared half.
    # This one pins that the two states nothing else on the page distinguishes are distinguished
    # here: "reported no tests" and "recorded no per-example detail" of the SAME side.
    it "keeps the two absences of the same run apart" do
      unmeasured = new_repository
      unmeasured.test_runs.create!(commit_sha: "prev00000000001", branch: "main", total_specs_count: 0,
                                   created_at: 2.hours.ago)
      ingest(unmeasured, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))
      get repository_path(unmeasured)
      reported_nothing = empty_state_text

      unrecorded = new_repository
      ingest(unrecorded, commit_sha: "prev00000000001", total: 40)
      unrecorded.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(unrecorded, commit_sha: "late00000000002", specs: area_specs("spec/models", 3))
      get repository_path(unrecorded)

      expect(empty_state_text).not_to eq(reported_nothing)
    end
  end

  # What the panel costs the page, in EVERY state — including the ones that render no table, which
  # is where an implementation that queried first and gated afterwards would show up.
  describe "what the panel costs the page" do
    # `count_queries` comes from spec/support/query_capture.rb.

    # ONE query for the whole comparison, and it does not grow with the suite. Measured as a
    # difference against the same page rendering ten times the examples, so an implementation that
    # read a run's areas per row — or issued a second round trip to count them — shows up here
    # whatever the page's absolute query count happens to be.
    it "costs the same whether the two runs hold thirty examples or three hundred" do
      small = two_runs(previous_specs: area_specs("spec/models", 10) + area_specs("spec/system", 5, offset: 50),
                       latest_specs: area_specs("spec/models", 12, offset: 100) +
                                     area_specs("spec/system", 3, offset: 200))
      get repository_path(small)
      baseline = count_queries { get repository_path(small) }
      expect(rows.size).to eq(2)

      large = two_runs(previous_specs: area_specs("spec/models", 100) + area_specs("spec/system", 50, offset: 500),
                       latest_specs: area_specs("spec/models", 120, offset: 1_000) +
                                     area_specs("spec/system", 30, offset: 2_000))
      get repository_path(large)

      expect(count_queries { get repository_path(large) }).to eq(baseline)
      expect(rows.size).to eq(2)
    end

    # The three states decidable from the two runs alone cost the page NOTHING, because the gate
    # runs before the query rather than filtering its results. An implementation that queried and
    # then discarded would be green on every rendering example above and one query heavier here on
    # exactly the pages that have nothing to show.
    it "asks the observations table nothing where the runs are not comparable" do
      comparable = two_runs(previous_specs: area_specs("spec/models", 3),
                            latest_specs: area_specs("spec/models", 5, offset: 100))
      get repository_path(comparable)
      with_comparison = count_queries { get repository_path(comparable) }
      expect(rows.size).to eq(1)

      incomparable = new_repository
      incomparable.test_runs.create!(commit_sha: "prev00000000001", branch: "main", total_specs_count: 0,
                                     created_at: 2.hours.ago)
      ingest(incomparable, commit_sha: "late00000000002", specs: area_specs("spec/models", 5))
      get repository_path(incomparable)

      expect(count_queries { get repository_path(incomparable) }).to eq(with_comparison - 1)
      expect(panel).to have_no_css("tbody tr")
    end
  end

  # Read-only suite telemetry, like every panel around it: a `view` member legitimately needs to
  # see what CI reported. Nothing here is credential metadata and nothing here actions anything.
  it "is visible to a member with only 'view'" do
    repository = two_runs(previous_specs: area_specs("spec/models", 2),
                          latest_specs: area_specs("spec/models", 5, offset: 100))
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(row_for("spec/models")).to include(change: "+3")
  end
end
