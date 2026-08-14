# frozen_string_literal: true

require "rails_helper"

# The "Files that grew or shrank in this directory" panel on repositories#show — which FILES of ONE
# area moved between the latest run and the previous run ON THE SAME BRANCH, and the link into it
# from the panel above.
#
# Its own file rather than more examples in spec/requests/repository_spec_directory_growth_spec.rb,
# for the reason that file gives for its own separation one rung up: every example here needs a
# two-run fixture WITH AN ASK, and it is this file that would have to change if the drill-in's
# rules changed. The panel above keeps asserting what its rows say; this one asserts what opens out
# of them.
#
# == What this panel is, in one sentence, and what it must never become
#
# It compares two POPULATIONS at the file grain: how many rows each file holds in run A against how
# many it holds in run B. It matches no examples between the runs, and it must not — `example_id`
# is positional and not stable across refactors. The examples below are written so that nothing
# about a per-example correspondence could make them pass: the two runs' examples sit at different
# line numbers throughout, so any implementation that tried to pair rows would produce different
# numbers from the ones asserted here.
#
# The point of the finer grain is NOT that the page can now tell a rename from a gain-and-a-loss.
# It cannot, and it says so. The point is that at this grain the two shapes stop LOOKING alike, so
# a reader can tell — which is the doubt the panel above discloses and leaves them holding.
#
# == THE load-bearing case
#
# `#renders nothing where the panel above cannot compare` is the example this file exists for. A
# drill-in that compared two runs its parent refuses to compare would assert, in a closer view, a
# comparison the wider view has just withheld — and it would do it on a page that is at that moment
# printing the reason no comparison is possible.
RSpec.describe "Repository spec directory file growth", type: :request do
  before { @user = sign_in_via_github }

  def page = Capybara.string(response.body)

  def panel = page.find("#spec-directory-file-growth")

  def panel? = page.has_css?("#spec-directory-file-growth")

  # ELEMENT-scoped, never panel-scoped, for the reason the sibling spec states: several states
  # render inside this panel and they share most of their words, so a panel-level `have_text`
  # passes for the wrong state with the deciding branch deleted.
  def basis_text = panel.find("#spec-directory-file-growth-basis").text.gsub(/\s+/, " ").strip

  def empty_state_text = panel.find("[class*='border-dashed']").text.gsub(/\s+/, " ").strip

  # The area panel this drills out of, scoped by id — its rows carry the same path strings the
  # "Heaviest spec directories" panel does, and a page-scoped lookup would silently assert about
  # whichever one Capybara reached first.
  def area_panel = page.find("#spec-directory-growth")

  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  # One row as a reader meets it: the file, both operands, and the movement between them.
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
  # totals and no per-example detail, one of the states the panel above withholds a comparison for
  # and therefore one this panel must not render in.
  def ingest(repository, commit_sha:, specs: nil, branch: "main", total: nil, shard_id: nil, **attrs)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
  end

  # `count` examples in one FILE, at line numbers that cannot collide within their run. `offset` is
  # what keeps the two runs' example ids from lining up.
  def file_specs(path, count, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: path, line_number: offset + i + 1, duration: 0.1)
    end
  end

  def two_runs(previous_specs: nil, latest_specs: nil, previous_total: nil, latest_total: nil, **latest_attrs)
    repository = new_repository
    ingest(repository, commit_sha: "prev00000000001", specs: previous_specs, total: previous_total)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(repository, commit_sha: "late00000000002", specs: latest_specs, total: latest_total, **latest_attrs)

    repository
  end

  # `spec/models` gained 3 in one file, LOST 5 in another, and held still in a third. `spec/requests`
  # exists so nothing here can pass by reading the whole run instead of the area asked for.
  def moved_area
    two_runs(
      previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                      file_specs("spec/models/legacy_spec.rb", 6, offset: 100) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 200) +
                      file_specs("spec/requests/checkout_spec.rb", 9, offset: 300),
      latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 400) +
                    file_specs("spec/models/legacy_spec.rb", 1, offset: 500) +
                    file_specs("spec/models/user_spec.rb", 1, offset: 600) +
                    file_specs("spec/requests/checkout_spec.rb", 9, offset: 700)
    )
  end

  # Acceptance 1: the row's path is a LINK and not the inert `<td>` it was. Asserted inside the
  # panel that owns it, and on the href rather than only on the element being an anchor — a link
  # pointing somewhere else is not this feature.
  describe "the way in, from the panel above" do
    it "links each area of 'Areas that grew or shrank' to its per-file drill-in" do
      get repository_path(moved_area)

      href = area_panel.find("a", text: "spec/models", match: :prefer_exact)[:href]

      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
      expect(href).to include("#spec-directory-file-growth")
    end

    # A list of choices with one of them taken, and the panel it opens is a long way down the page.
    # Asserted in both directions, so an implementation stamping `aria-current` on every row — which
    # tells a screen-reader user that every area is the open one — is not green here.
    it "marks the open area and only the open area" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(area_panel.find("a", text: "spec/models", match: :prefer_exact)["aria-current"]).to eq("true")
      expect(area_panel.find("a", text: "spec/requests", match: :prefer_exact)["aria-current"]).to be_nil
    end
  end

  describe "an area that was asked for" do
    it "renders no panel at all where no area was asked for" do
      get repository_path(moved_area)

      expect(panel?).to be(false)
    end

    it "names each file's count then, its count now, and the movement between them" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(row_for("spec/models/order_spec.rb")).to include(then: "2", now: "5", change: "+3")
      expect(row_for("spec/models/legacy_spec.rb")).to include(then: "6", now: "1", change: "−5")
    end

    # Acceptance 2, and the assertion a `DESC`-only ranking on the SIGNED change fails: the largest
    # movement in this area is a loss of five, and it has to head the list.
    it "ranks by how far each file moved, in both directions" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(row_paths).to eq(["spec/models/legacy_spec.rb", "spec/models/order_spec.rb",
                               "spec/models/user_spec.rb"])
    end

    # The narrow is an EQUALITY at one depth, the same one the durations drill-down on this very ask
    # uses. A prefix `LIKE` would gather the nested area in and this panel would double-count rows
    # against the one above it on a single click.
    it "reads the area at its own depth, gathering no nested area into it" do
      repository = two_runs(
        previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                        file_specs("spec/models/orders/refund_spec.rb", 8, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 200) +
                      file_specs("spec/models/orders/refund_spec.rb", 1, offset: 300)
      )

      get repository_path(repository, spec_directory: "spec/models")

      expect(row_paths).to eq(["spec/models/order_spec.rb"])
    end

    # An area that did not move is a real answer and renders as one — `±0`, not a blank cell and not
    # `+0`, which claims a direction it does not have.
    it "says so of a file that did not move rather than leaving the cell empty" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(row_for("spec/models/user_spec.rb")).to include(then: "1", now: "1", change: "±0")
    end

    # THE pair of rows this panel exists to put in front of a reader. One rung up this area is a
    # single `±0` under a caption admitting it cannot tell a relocation from a gain and a loss; here
    # both halves are named as STATES, because `+4` against an absent side reads identically to an
    # existing file that gained four.
    it "names an appeared file and a vanished one rather than differencing either from a zero" do
      repository = two_runs(
        previous_specs: file_specs("spec/models/user_spec.rb", 4),
        latest_specs: file_specs("spec/models/users_spec.rb", 4, offset: 100)
      )

      get repository_path(repository, spec_directory: "spec/models")

      expect(row_for("spec/models/users_spec.rb")).to include(then: "0", now: "4", change: "New file")
      expect(row_for("spec/models/user_spec.rb")).to include(then: "4", now: "0", change: "File removed")
    end

    # U+2212 and `±` are announced inconsistently across screen readers, and three numbers in a row
    # announce as three unattached numbers. The one-sided readings name the FILE grain — the sibling
    # one rung up says "area", and a struct shared between the two would say it here.
    it "spells the movement out for a screen reader" do
      repository = two_runs(
        previous_specs: file_specs("spec/models/legacy_spec.rb", 6) +
                        file_specs("spec/models/user_spec.rb", 1, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 3, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 300)
      )

      get repository_path(repository, spec_directory: "spec/models")

      expect(row_for("spec/models/legacy_spec.rb")[:reading])
        .to eq("6 examples in the previous run and none now")
      expect(row_for("spec/models/order_spec.rb")[:reading])
        .to eq("3 examples, a file the previous run did not record")
      expect(row_for("spec/models/user_spec.rb")[:reading])
        .to eq("unchanged since the previous run on this branch")
    end

    # The rung BELOW: opening a file out of this list is the same `?spec_file=` three other panels
    # offer. A file the LATEST run did not record is deliberately NOT linked — `?spec_file=` reads
    # the latest run, so that link would open a guaranteed-empty panel, and naming removed files is
    # half this panel's subject. Both halves asserted, because they fail differently.
    it "opens a listed file's examples, except for one the latest run does not have" do
      repository = two_runs(
        previous_specs: file_specs("spec/models/user_spec.rb", 4),
        latest_specs: file_specs("spec/models/users_spec.rb", 4, offset: 100)
      )

      get repository_path(repository, spec_directory: "spec/models")

      href = panel.find("a", text: "spec/models/users_spec.rb", match: :prefer_exact)[:href]
      expect(href).to include("spec_file=#{CGI.escape('spec/models/users_spec.rb')}")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
      expect(panel).to have_no_link("spec/models/user_spec.rb")
    end

    # The caption's load-bearing claims. The totals are the AREA's — the fixture's `spec/requests`
    # holds nine examples per run precisely so a caption built on the parent panel's whole-run
    # figures prints a visibly different number here.
    it "states what the panel covered and what it was measured over" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(basis_text).to include("all 3 spec files either run recorded in this area")
      expect(basis_text).to include("Counted off the 9 and 7 example rows the two runs recorded in this area")
      expect(basis_text).to include("prev000")
    end

    # The disclosure the finer grain EARNS. One rung up the reader is told a relocation and a
    # gain-and-a-loss are indistinguishable and can do nothing about it; here they are told what to
    # look for — while the page still refuses to assert either reading.
    it "discloses that a new file beside a removed one is what a rename looks like from here" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(basis_text).to match(/new.*beside one listed as removed/i)
      expect(basis_text).to include("pairs no example with any other example")
    end

    # The caption is a claim ABOUT the table, so it is carried to a screen-reader user landing on
    # the table by navigation — who otherwise meets the header row with none of it.
    it "carries the caption to the table it describes" do
      get repository_path(moved_area, spec_directory: "spec/models")

      expect(panel.find("table")["aria-describedby"]).to eq("spec-directory-file-growth-basis")
    end

    # The list is capped, so its own length says nothing about how much of the comparison it
    # covers — the total has to come from a count of GROUPS taken before the cap.
    #
    # Thirty-two files in the latest run and one only the previous run has: thirty-three, a figure
    # neither run alone could produce, and deliberately not equal to any single file's row count.
    it "says the list is the head of a longer one, and how long" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", specs: file_specs("spec/models/gone_spec.rb", 1))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002",
                         specs: (0..31).flat_map { |i| file_specs("spec/models/f#{i}_spec.rb", i + 1, offset: i * 100) })

      get repository_path(repository, spec_directory: "spec/models")

      expect(rows.size).to eq(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      expect(basis_text).to include("the 30 spec files that moved most, of the 33 either run recorded")
    end

    # Two comparable runs whose every file in the area holds the same number of examples. A real
    # answer, and the one a reader who suspected a rename most wants confirmed — so it is said in
    # words rather than rendered as a table of `±0`.
    it "says nothing moved rather than tabulating a column of zeroes" do
      repository = two_runs(
        previous_specs: file_specs("spec/models/order_spec.rb", 3) +
                        file_specs("spec/models/user_spec.rb", 2, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 3, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 2, offset: 300)
      )

      get repository_path(repository, spec_directory: "spec/models")

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("No file moved")
      expect(empty_state_text).to include("Every one of the 2 spec files")
    end

    # An area neither run recorded is an ordinary answer, not an error: `?spec_directory=` is a URL
    # a reader types, edits and bookmarks. The empty state names the path back, because an empty
    # state without a subject is a sentence about nothing.
    it "names the area back where neither run recorded anything in it" do
      get repository_path(moved_area, spec_directory: "spec/ghosts")

      expect(panel).to have_no_css("tbody tr")
      expect(empty_state_text).to include("No spec files in this directory")
      expect(empty_state_text).to include("spec/ghosts")
    end
  end

  # THE case this file exists for. Six states in which the panel above withholds the comparison, and
  # in every one of them this drill-in must be ABSENT — even though the ask that opens it is set.
  # A closer view asserting a comparison the wider view refuses is the defect; that it would do so
  # directly beneath the printed reason no comparison is possible is what makes it indefensible.
  describe "when the panel above cannot compare" do
    def incomparable(**attrs) = two_runs(**attrs)

    {
      "this run reported no tests" => { previous_specs: :specs, latest_total: 0 },
      "the previous run reported no tests" => { previous_total: 0, latest_specs: :specs },
      "the previous run recorded no per-example detail" => { previous_total: 40, latest_specs: :specs },
      "this run recorded no per-example detail" => { previous_specs: :specs, latest_total: 40 },
      "neither run recorded per-example detail" => { previous_total: 40, latest_total: 42 }
    }.each do |reason, fixture|
      it "renders nothing where #{reason}, even with the area asked for" do
        attrs = fixture.transform_values do |value|
          value == :specs ? file_specs("spec/models/order_spec.rb", 3) : value
        end

        get repository_path(incomparable(**attrs), spec_directory: "spec/models")

        expect(panel?).to be(false)
      end
    end

    # The sixth, built apart because its cause is HOW the runs were assembled rather than what they
    # measured: a sharded run differenced against a complete one reports every file shrinking.
    it "renders nothing where the two runs were assembled from different numbers of parts" do
      repository = two_runs(previous_specs: file_specs("spec/models/order_spec.rb", 4),
                            latest_specs: file_specs("spec/models/order_spec.rb", 2, offset: 100),
                            ci_run_id: "gha-1", shard_id: "0")

      get repository_path(repository, spec_directory: "spec/models")

      expect(panel?).to be(false)
      expect(page).to have_css("#spec-directory-growth")
    end

    # And where there is no earlier run on the branch at all, so the panel above does not exist
    # either. The drill-in must not become the page's first opinion on a comparison nobody can make.
    it "renders nothing where there is no earlier run on the branch" do
      repository = new_repository
      ingest(repository, commit_sha: "only00000000001", specs: file_specs("spec/models/order_spec.rb", 3))

      get repository_path(repository, spec_directory: "spec/models")

      expect(panel?).to be(false)
    end
  end

  # Acceptance 4: one query when asked, zero when not.
  describe "what the panel costs the page" do
    # `count_queries` and `executed_sql` come from spec/support/query_capture.rb.

    # The statements THIS panel issued, picked out by the one thing only this aggregate does: count
    # rows per run with `COUNT(*) FILTER (WHERE test_run_id = ...)` while grouping on
    # `spec_file_path`. The two by-AREA growth panels count the same way and group on the area
    # expression; the runtime siblings carry `SUM(duration_seconds)`. A selector naming more than
    # the guard means stops being a measurement of the guard.
    def file_growth_aggregates(&)
      executed_sql(&).select do |sql|
        sql.include?("COUNT(*) FILTER (WHERE test_run_id =") &&
          sql.include?('GROUP BY "spec_observations"."spec_file_path"') &&
          sql.exclude?("SUM(duration_seconds)")
      end
    end

    it "asks the observations table nothing where no area was asked for" do
      repository = moved_area
      get repository_path(repository)

      expect(file_growth_aggregates { get repository_path(repository) }).to be_empty
    end

    it "asks it exactly once where an area was asked for" do
      repository = moved_area
      get repository_path(repository, spec_directory: "spec/models")

      expect(file_growth_aggregates { get repository_path(repository, spec_directory: "spec/models") }.size)
        .to eq(1)
    end

    # The gate runs before the query rather than filtering its results, so a page that cannot
    # compare pays nothing for this panel even with the ask set. An implementation that queried and
    # then discarded would be green on every rendering example above.
    it "asks it nothing where the panel above cannot compare, even with the area asked for" do
      repository = new_repository
      ingest(repository, commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(repository, commit_sha: "late00000000002", specs: file_specs("spec/models/order_spec.rb", 3))
      get repository_path(repository, spec_directory: "spec/models")

      expect(file_growth_aggregates { get repository_path(repository, spec_directory: "spec/models") })
        .to be_empty
      expect(panel?).to be(false)
    end

    # ONE query for the whole comparison, and it does not grow with the area. Measured as a
    # difference against ten times the examples, so an implementation reading a file's rows per row —
    # or taking a second round trip for the captions — shows up here whatever the page's absolute
    # query count happens to be.
    it "costs the same whether the area holds twenty examples or two hundred" do
      small = two_runs(previous_specs: file_specs("spec/models/order_spec.rb", 10),
                       latest_specs: file_specs("spec/models/order_spec.rb", 12, offset: 100))
      get repository_path(small, spec_directory: "spec/models")
      baseline = count_queries { get repository_path(small, spec_directory: "spec/models") }
      expect(rows.size).to eq(1)

      large = two_runs(previous_specs: file_specs("spec/models/order_spec.rb", 100),
                       latest_specs: file_specs("spec/models/order_spec.rb", 120, offset: 1_000))
      get repository_path(large, spec_directory: "spec/models")

      expect(count_queries { get repository_path(large, spec_directory: "spec/models") }).to eq(baseline)
      expect(rows.size).to eq(1)
    end
  end

  # One ask, TWO panels — the durations drill-down and this one — each answering in its own grain
  # over the same area. Intended, and the property a later reader is most likely to "fix" by minting
  # a second parameter, so it is pinned rather than left to a comment.
  it "opens both drill-downs of one area on one ask" do
    get repository_path(moved_area, spec_directory: "spec/models")

    expect(page).to have_css("#spec-directory-files")
    expect(page).to have_css("#spec-directory-file-growth")
  end

  # Read-only suite telemetry, like every panel around it: a `view` member legitimately needs to see
  # what CI reported. Nothing here is credential metadata and nothing here actions anything.
  it "is visible to a member with only 'view'" do
    repository = moved_area
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository, spec_directory: "spec/models")

    expect(response).to have_http_status(:ok)
    expect(row_for("spec/models/order_spec.rb")).to include(change: "+3")
  end
end
