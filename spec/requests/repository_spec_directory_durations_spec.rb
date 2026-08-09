# frozen_string_literal: true

require "rails_helper"

# The "Heaviest spec directories" panel on repositories#show — where ONE run's wall clock actually
# went, rolled up by the code AREA holding the file that ran each example.
#
# The sibling of spec/requests/repository_spec_file_durations_spec.rb one rung up, and deliberately
# its own file for the reason that one states for itself: every example here needs the same
# per-example fixture, and the Overview/API-keys file is edited by sibling slices.
#
# The two panels answer different questions off the same rows and neither derives the other. A
# ten-row ranking by FILE cannot surface a directory that is heavy because it holds forty ordinary
# files, which at the 20,000-example design point is the common way for a suite to spend its time —
# and it is the grain the question is usually asked in ("this area carries 340 tests and 6 minutes
# of wall clock").
#
# It is also not the shard split on the Overview panel: `TestRun#shard_durations` rolls the same run
# up by CI partition, and a partition is arbitrary with respect to directory structure.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: an untimed example is `result&.run_time` coming back nil on a real client, and a
# shared example group reporting a `spec_file_path` that differs from its `file_path` is a shape the
# RECORDER produces. A hand-built fixture would assert against a shape nothing in production writes.
RSpec.describe "Repository heaviest spec directories", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-directory-durations")

  def panel?
    Capybara.string(response.body).has_css?("#spec-directory-durations")
  end

  # ELEMENT-scoped, never panel-scoped: the basis paragraph has two states that share most of their
  # words, so a panel-level `have_text` passes for the wrong state with the deciding branch deleted.
  def basis_line = panel.find("#spec-directory-durations-basis")

  # One row as a reader meets it: the area, what its total was summed over, and the total.
  def rows
    panel.all("tbody tr").map do |row|
      path, coverage, duration = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, coverage: coverage, duration: duration }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  # The panel one rung down, on the same page and off the same rows — read here so the two grains
  # can be compared in the assertions that exist to prove they are two grains.
  def file_row_paths
    Capybara.string(response.body).find("#spec-file-durations").all("tbody tr").map do |row|
      row.first("td").text.gsub(/\s+/, " ").strip
    end
  end

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` is passed at every call site, nils included — an untimed
  # example is the state half this file turns on, and the shared builder defaults it to a number.
  def example_spec(file_path:, duration:, line_number:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration).merge(attrs)
  end

  describe "a run whose examples were timed" do
    # Built so the by-FILE and by-DIRECTORY rankings disagree, which is the whole reason this panel
    # is a second query rather than a re-render of the one below it. `spec/requests` holds the
    # single heaviest FILE (9.0s) and `spec/models` holds none of the top files — yet `spec/models`
    # is the heavier AREA at 10.5s, because it holds three of them.
    def timed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 1),
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: 3.5, line_number: 2),
                          example_spec(file_path: "spec/models/user_spec.rb", duration: 3.5, line_number: 3),
                          example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 4),
                          example_spec(file_path: "spec/system/smoke_spec.rb", duration: 0.5, line_number: 5)])
      repository
    end

    # More areas than the panel lists, so the listed count and the run's own count are different
    # numbers and one caption cannot satisfy both by accident.
    def twenty_five_directory_run
      repository = create_repository(user: @user)
      specs = (1..25).map do |i|
        example_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", duration: i.to_f, line_number: i)
      end
      ingest(repository, specs)
      repository
    end

    # The panel's whole claim: an area's wall clock is the SUM of every file under it, so an area
    # holding three middling files outranks one holding a single heavier one.
    it "ranks the directories by the wall clock the run spent in each, heaviest first" do
      get repository_path(timed_run)

      expect(row_paths).to eq(["spec/models", "spec/requests", "spec/system"])
      expect(rows.map { |row| row[:duration] }).to eq(["10.50s", "9.00s", "0.50s"])
    end

    # THE assertion that would fail if this panel were the by-file rollup relabelled, or if it were
    # dropped and the by-file panel left to stand in for it. The heaviest FILE on this page is in
    # `spec/requests`; the heaviest AREA is `spec/models`, which owns no row at the head of the
    # panel below. Neither list is derivable from the other and the page shows both.
    it "ranks the areas differently from the files, on the same rows of the same run" do
      get repository_path(timed_run)

      expect(file_row_paths.first).to eq("spec/requests/checkout_spec.rb")
      expect(row_paths.first).to eq("spec/models")
    end

    it "says every listed total covers the whole of its area, where every example was timed" do
      get repository_path(timed_run)

      expect(rows.map { |row| row[:coverage] }).to eq(["3 of 3", "1 of 1", "1 of 1"])
      expect(basis_line).to have_text("Every example in every directory listed reported a duration",
                                      normalize_ws: true)
    end

    # Bounded by `SpecObservation::HEAVIEST_DIRECTORIES_LIMIT` — its own constant, not the by-file
    # panel's: the two rank different populations and a suite that wants twenty files ranked has no
    # reason to want twenty areas ranked.
    it "lists no more than the heaviest ten, however many areas the run touched" do
      get repository_path(twenty_five_directory_run)

      expect(rows.size).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
      expect(row_paths.first).to eq("spec/d25")
      expect(row_paths.last).to eq("spec/d16")
    end

    # A capped list that does not disclose its cap is read as the whole story — the same lie by
    # omission the per-row coverage column refuses one grain down. The caption has to name what the
    # list is the head OF, and `rows.size` cannot, because it is the truncated figure.
    it "says how many directories the run touched, not just how many it lists" do
      get repository_path(twenty_five_directory_run)

      expect(basis_line).to have_text("The 10 heaviest of the 25 directories the run named above recorded",
                                      normalize_ws: true)
    end

    # And the other half of the disclosure: a run whose areas all fit is not truncated, and saying
    # "the 3 heaviest of the 3 directories" would make a complete list look like a sample.
    it "says the list is all of them, where nothing was cut" do
      get repository_path(timed_run)

      expect(basis_line).to have_text("All 3 directories the run named above recorded", normalize_ws: true)
      expect(basis_line).to have_no_text("heaviest of the")
    end

    # The IMMEDIATE parent, so the areas partition the run rather than nesting: `spec/models/orders`
    # is its own row and its time does not also count inside `spec/models`. A rollup that walked
    # ancestors would double-count the deep rows and total more than the run.
    it "keeps a nested area's time out of its ancestor's total" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 1),
                          example_spec(file_path: "spec/models/orders/refund_spec.rb", duration: 2.0,
                                       line_number: 2)])

      get repository_path(repository)

      expect(rows).to eq([{ path: "spec/models/orders", coverage: "1 of 1", duration: "2.00s" },
                          { path: "spec/models", coverage: "1 of 1", duration: "1.00s" }])
    end

    # A spec file at the repository root has no parent segment at all. Dropping those rows would
    # understate the run at the one grain that is supposed to account for all of it, and an unnamed
    # area on a ranked list is unreadable — so the root is named the way `Pathname#dirname` names it.
    it "names the repository root rather than losing the rows that sit in it" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "smoke_spec.rb", duration: 3.0, line_number: 1,
                                       id: "./smoke_spec.rb[1:1]"),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 2)])

      get repository_path(repository)

      expect(row_paths).to eq([".", "spec/models"])
      expect(rows.first[:duration]).to eq("3.00s")
    end

    # A shared example group reports `spec/support/shared_examples.rb` as its definition site, and
    # the file that actually RAN it appears only as `spec_file_path`. Rolling up on `file_path`
    # would attribute every including area's time to a `spec/support` that ran nothing — the exact
    # shape spec/requests/api/v1/ingest_spec.rb pins at the ingest end.
    it "lands a shared example group's time on the area that included it, not on the helper's" do
      repository = create_repository(user: @user)
      shared = "spec/support/shared_examples.rb"
      ingest(repository, [example_spec(file_path: shared, line_number: 4, duration: 1.5,
                                       spec_file_path: "spec/models/order_spec.rb",
                                       id: "./spec/models/order_spec.rb[1:1:1]"),
                          example_spec(file_path: shared, line_number: 4, duration: 2.5,
                                       spec_file_path: "spec/requests/refund_spec.rb",
                                       id: "./spec/requests/refund_spec.rb[1:1:1]")])

      get repository_path(repository)

      expect(row_paths).to eq(["spec/requests", "spec/models"])
      expect(rows.map { |row| row[:duration] }).to eq(["2.50s", "1.50s"])
      expect(row_paths).not_to include("spec/support")
    end
  end

  # THE hazard this grain gets wrong most expensively: excluding untimed rows changes each surviving
  # GROUP'S OWN population, and an area is a bigger population than a file. A half-untimed area
  # silently reports half its time, and a wholly untimed one comes back as SQL NULL, which
  # `group(...).sum` casts to `0.0` on the way into Ruby and a naive cell renders "0.00s".
  describe "a run mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 4.0, line_number: 1),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 2),
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 3),
                          example_spec(file_path: "spec/system/never_ran_spec.rb", duration: nil, line_number: 4),
                          example_spec(file_path: "spec/system/also_never_spec.rb", duration: nil, line_number: 5)])
      repository
    end

    it "states how much of a partly timed area its total was summed over" do
      get repository_path(mixed_run)

      expect(rows.first).to eq(path: "spec/models", coverage: "1 of 3", duration: "4.00s")
    end

    # Both halves fail differently. A cell rendering the aggregate's nil through
    # `group(...).sum(:duration_seconds)` prints "0.00s"; an ordering left at plain `DESC` is NULLS
    # FIRST in Postgres and names the area nothing was measured in the heaviest in the run.
    it "shows no total for a wholly untimed area, and does not rank it above a measured one" do
      get repository_path(mixed_run)

      expect(rows.last).to eq(path: "spec/system", coverage: "0 of 2", duration: "not reported")
      expect(row_paths.first).to eq("spec/models")
      expect(panel).to have_no_text("0.00s")
    end

    it "says what the coverage column is, where the totals do not all cover their areas" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("an area that reported none has no total to state rather than a zero",
                                      normalize_ws: true)
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size — that figure
    # is re-derived by SUM over shard reports and the two can legitimately differ. There is no
    # by-directory counter anywhere else to borrow in any case.
    it "counts each area's own rows rather than the run's suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 1),
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 2)],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(rows.first[:coverage]).to eq("1 of 2")
      expect(panel).to have_no_text("4,000")
      expect(panel).to have_no_text("4000")
    end
  end

  describe "a run that recorded examples and timed none of them" do
    it "renders an empty state rather than a column of zeroes" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 1),
                          example_spec(file_path: "spec/requests/refund_spec.rb", duration: nil, line_number: 2)])

      get repository_path(repository)

      expect(panel).to have_text("No timings on this run", normalize_ws: true)
      expect(panel).to have_text("no wall clock to attribute to any area", normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
      expect(panel).to have_no_text("0.00s")
    end

    # The empty state says how much ran unmeasured rather than only that something did — in
    # DIRECTORIES, because that is the count this read has exactly. An example count summed off the
    # rows on hand would be summed over a capped ten of them and understate a wider run while
    # looking suite-wide.
    it "says how many directories went unmeasured, counting past the limit" do
      repository = create_repository(user: @user)
      ingest(repository, (1..12).map do |i|
        example_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", duration: nil, line_number: i)
      end)

      get repository_path(repository)

      expect(panel).to have_text("This run recorded examples in 12 directories", normalize_ws: true)
    end
  end

  # A run with no per-example rows at all — everything ingested before those rows existed, and every
  # client that sends no per-example detail. There is no per-area grain to disclose, and an empty
  # panel on every such run would read as a finding about the suite when it is a fact about the
  # payload.
  describe "a run with nothing at this grain" do
    it "renders no panel for a run that recorded no examples" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, total_specs_count: 900)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end

    it "renders no panel for a repository CI has never reported for" do
      get repository_path(create_repository(user: @user))

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # Every figure on the panel against direct SQL of the same grouping, taken independently of the
  # read the page makes. The panel's own query is the thing under test, so a check written through
  # it would agree with itself by construction; this one groups the rows in Ruby, off the records,
  # and compares what the reader is shown to what the run actually wrote.
  describe "what the rendered figures are" do
    it "matches an independent grouping of the run's own rows" do
      repository = create_repository(user: @user)
      ingest(repository, (1..24).map do |i|
        example_spec(file_path: "spec/d#{i % 4}/f#{i}_spec.rb", duration: (i % 7).zero? ? nil : i.to_f,
                     line_number: i)
      end)

      get repository_path(repository)

      expected = SpecObservation.where(test_run: repository.test_runs.last)
                                .group_by { |row| row.spec_file_path.split("/")[0..-2].join("/") }
                                .map do |directory, observations|
        timed = observations.filter_map(&:duration_seconds)
        # nil, not 0.0, for an area nothing was measured in — the distinction the whole panel turns
        # on, kept in the CONTROL too so a control that flattened it could not certify a page that
        # flattened it.
        [directory, timed.empty? ? nil : timed.sum, timed.size, observations.size]
      end.sort_by { |_directory, total, _timed, _recorded| -(total || -Float::INFINITY) }

      # Rendered through `SpecObservation.humanized_duration` rather than through a format string
      # retyped here: the claim under test is that the FIGURES match an independent grouping, and a
      # hand-rolled "%.2fs" is a second definition of the spelling that disagrees with the seam the
      # moment a total passes a minute — which is exactly what these totals do.
      expect(rows).to eq(expected.map do |directory, total, timed, recorded|
        { path: directory, coverage: "#{timed} of #{recorded}",
          duration: SpecObservation.humanized_duration(total) }
      end)
      expect(rows.size).to eq(4)
    end
  end

  # The rollup is one grouped aggregate in SQL, so the page costs the same on a 20,000-example suite
  # as on a 20-example one. A `group_by` over `has_many` walked in Ruby is exactly the shape that
  # ships green on a three-row fixture and takes the page down on a real suite. The absolute ceiling
  # for the whole page lives in spec/requests/repository_spec_file_durations_spec.rb, which counts
  # both rollups together; what this one guards is that THIS panel's cost does not grow with the
  # suite.
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

    it "costs the same number of queries at 200 examples over 25 directories as at 3 over 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      ingest(small, (1..3).map do |i|
        example_spec(file_path: "spec/d#{i}/a_spec.rb", duration: i.to_f, line_number: i)
      end)
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      ingest(large, (1..200).map do |i|
        example_spec(file_path: "spec/d#{format('%02d', i % 25)}/f#{i}_spec.rb",
                     duration: i.to_f, line_number: i, id: "./spec/d#{i % 25}/f#{i}_spec.rb[1:#{i}]")
      end, commit_sha: "feedfacecafe0002")

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      expect(rows.size).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
    end
  end

  # == The drill-in: one area of that rollup, opened
  #
  # The MIDDLE rung of area → file → example, and the one that was missing. Rung three shipped with
  # the "Examples in this spec file" panel; rung one is the rollup above. Rung two never existed, so
  # rung one could not reach rung three — and it is not a gap the by-file panel could cover, because
  # that panel is a capped ten as well and an area is heavy precisely when it holds many ordinary
  # files. The heaviest area on this page was the one place in the suite a reader could not look
  # inside.
  #
  # Hosted here rather than in its own file because every example needs the fixture this file
  # already builds, and the panel it opens out of is the one this file is about.
  describe "opening one directory out of the rollup" do
    def files_panel = Capybara.string(response.body).find("#spec-directory-files")

    def files_panel? = Capybara.string(response.body).has_css?("#spec-directory-files")

    # ELEMENT-scoped, never panel-scoped: the basis paragraph has branches sharing most of their
    # words, so a panel-level `have_text` passes for the wrong branch with the deciding one deleted.
    def files_basis = files_panel.find("#spec-directory-files-basis")

    def file_rows
      files_panel.all("tbody tr").map do |row|
        path, coverage, duration = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

        { path: path, coverage: coverage, duration: duration }
      end
    end

    def file_row_paths = file_rows.map { |row| row[:path] }

    # Built so the heavy AREA holds none of the run's heavy FILES — the shape that makes this rung
    # necessary rather than convenient. `spec/models` is the heaviest area at 10.5s across three
    # middling files; the single heaviest file in the run is in `spec/requests`.
    def area_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 3.5, line_number: 1),
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: 5.0, line_number: 2),
                          example_spec(file_path: "spec/models/user_spec.rb", duration: 2.0, line_number: 3),
                          example_spec(file_path: "spec/requests/checkout_spec.rb", duration: 9.0, line_number: 4)])
      repository
    end

    describe "the way in, from the panel above" do
      # The panel above already rendered the path as plain text, so the way in costs no query to
      # offer — and without it the ten areas the page names are ten dead ends.
      it "links each listed directory to its own spec files" do
        get repository_path(area_run)

        href = panel.find("a", text: "spec/models")[:href]

        expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
        expect(href).to include("#spec-directory-files")
      end

      # A list of choices with one of them taken, and the drill-in sits below a long page.
      it "marks the open directory in the panel it was opened from" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(panel.find("a", text: "spec/models")["aria-current"]).to eq("true")
        expect(panel.find("a", text: "spec/requests")["aria-current"]).to be_nil
      end

      # `?branch=` anchors the "Suite growth" panel and nothing else. Opening an area must not
      # re-anchor a chart the reader did not touch.
      it "carries a branch ask through the link rather than dropping it" do
        get repository_path(area_run, branch: "main")

        expect(panel.find("a", text: "spec/models")[:href]).to include("branch=main")
      end

      it "renders no panel at all when no directory was asked for" do
        get repository_path(area_run)

        expect(response).to have_http_status(:ok)
        expect(files_panel?).to be(false)
      end
    end

    describe "an area whose files were timed" do
      # THE question this rung exists for. Scoped to the area — the run's heaviest file is in
      # another one and belongs to nothing here — and heaviest file first inside it.
      it "lists that area's spec files, heaviest first, and no other area's" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(file_rows).to eq([{ path: "spec/models/refund_spec.rb", coverage: "1 of 1", duration: "5.00s" },
                                 { path: "spec/models/order_spec.rb", coverage: "1 of 1", duration: "3.50s" },
                                 { path: "spec/models/user_spec.rb", coverage: "1 of 1", duration: "2.00s" }])
        expect(files_panel).to have_no_text("checkout_spec.rb")
      end

      # THE assertion that fails if this panel is ever fed by the by-file rollup instead of its own
      # read: not one of `spec/models`' three files is the heaviest file in the run, which is what
      # makes the area heavy and its files unreachable from a by-file top ten.
      it "shows files the by-file panel's own ranking heads with something else" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(file_row_paths).not_to include("spec/requests/checkout_spec.rb")
        expect(file_row_paths.first).to eq("spec/models/refund_spec.rb")
      end

      it "names the area it is listing" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(files_basis).to have_text("spec/models", normalize_ws: true)
      end

      it "says the list is all of the area's files, where nothing was cut" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(files_basis).to have_text("all 3 spec files this run recorded in this area, heaviest first",
                                         normalize_ws: true)
        expect(files_basis).to have_text(
          "Every one of the 3 examples this run recorded in this area reported a duration",
          normalize_ws: true
        )
      end

      # An EQUALITY narrow at one depth, exactly as the rollup above groups at one depth. A prefix
      # `LIKE` would gather the nested area in — and would have left this slice, per
      # `SpecObservation.files_in_directory`.
      it "does not gather a nested area's files into its ancestor" do
        repository = create_repository(user: @user)
        ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 1),
                            example_spec(file_path: "spec/models/orders/refund_spec.rb", duration: 2.0,
                                         line_number: 2)])

        get repository_path(repository, spec_directory: "spec/models")

        expect(file_row_paths).to eq(["spec/models/order_spec.rb"])
      end

      # The area name a link carries is computed by the same expression the rollup groups by, so the
      # one row the rollup names `.` has to open too — a repository-root file is otherwise a row that
      # links to an empty panel.
      it "opens the repository root under the name the panel above gives it" do
        repository = create_repository(user: @user)
        ingest(repository, [example_spec(file_path: "smoke_spec.rb", duration: 3.0, line_number: 1,
                                         id: "./smoke_spec.rb[1:1]"),
                            example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 2)])

        get repository_path(repository, spec_directory: ".")

        expect(file_row_paths).to eq(["smoke_spec.rb"])
      end

      # Bounded by `SpecObservation::SPEC_DIRECTORY_FILES_LIMIT` — its own constant, not the by-file
      # rollup's ten and not the by-file drill-down's fifty.
      it "lists no more than its own limit, however many files the area holds" do
        get repository_path(capped_area_run, spec_directory: "spec/models")

        expect(file_rows.size).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
      end

      # A capped list that does not disclose its cap is the lie `SpecDirectoryDurations#truncated?`
      # already refuses one rung up. The count has to come from the AREA and not from the rows on
      # hand, which are the truncated figure.
      it "says how many files the area holds, not just how many it lists" do
        get repository_path(capped_area_run, spec_directory: "spec/models")

        expect(files_basis).to have_text(
          "the #{SpecObservation::SPEC_DIRECTORY_FILES_LIMIT} heaviest of the 27 spec files this " \
          "run recorded in this area, heaviest first", normalize_ws: true
        )
      end

      # The OTHER axis, and the one a list of files cannot show: the cap is counted in FILES and
      # the coverage in EXAMPLES, and on a truncated area those describe different populations. Two
      # examples per file, so a coverage figure taken off the listed rows would read 50 rather than
      # 54 and no arithmetic on the page would betray it.
      it "counts its timing coverage over the whole area rather than over the files that fit" do
        get repository_path(capped_area_run, spec_directory: "spec/models")

        expect(file_rows.size).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
        expect(files_basis).to have_text(
          "Every one of the 54 examples this run recorded in this area reported a duration",
          normalize_ws: true
        )
      end
    end

    # Rung three, reached from rung two. It already shipped — what is new is that it can now be
    # reached from an area, which is the whole point of the middle rung existing.
    describe "the way on, into one of those files" do
      it "links each listed file into the examples panel above" do
        get repository_path(area_run, spec_directory: "spec/models")

        href = files_panel.find("a", text: "spec/models/refund_spec.rb")[:href]

        expect(href).to include("spec_file=#{CGI.escape('spec/models/refund_spec.rb')}")
        expect(href).to include("#spec-file-examples")
      end

      # Both parameters on ONE URL. Opening a file out of this list must not close the area it was
      # opened from, or the reader cannot pick a second file without navigating back.
      it "carries the area ask through, so both panels stay open together" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(files_panel.find("a", text: "spec/models/refund_spec.rb")[:href])
          .to include("spec_directory=#{CGI.escape('spec/models')}")
      end

      it "opens both panels when both parameters are asked" do
        get repository_path(area_run, spec_directory: "spec/models",
                                      spec_file: "spec/models/refund_spec.rb")

        expect(files_panel?).to be(true)
        expect(Capybara.string(response.body).has_css?("#spec-file-examples")).to be(true)
        expect(files_panel.find("a", text: "spec/models/refund_spec.rb")["aria-current"]).to eq("true")
      end

      it "carries a branch ask through that link too" do
        get repository_path(area_run, branch: "main", spec_directory: "spec/models")

        expect(files_panel.find("a", text: "spec/models/refund_spec.rb")[:href]).to include("branch=main")
      end
    end

    # The hazard every read on this table shares, at this grain: `SUM` skips a missing timing
    # silently and `DESC` alone is NULLS FIRST in Postgres, so the file nothing measured is named
    # the heaviest in the area and its nil is rendered as a zero it never measured.
    describe "an area mixing timed and untimed files" do
      def mixed_area_run
        repository = create_repository(user: @user)
        ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 4.0, line_number: 1),
                            example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 2),
                            example_spec(file_path: "spec/models/never_ran_spec.rb", duration: nil,
                                         line_number: 3)])
        repository
      end

      it "keeps the untimed file in the list and below every measured one, with no zero" do
        get repository_path(mixed_area_run, spec_directory: "spec/models")

        expect(file_rows).to eq([{ path: "spec/models/order_spec.rb", coverage: "1 of 2", duration: "4.00s" },
                                 { path: "spec/models/never_ran_spec.rb", coverage: "0 of 1",
                                   duration: "not reported" }])
        expect(files_panel).to have_no_text("0.00s")
      end

      # In the spelling `SpecDirectoryDurations::Row#coverage_label` fixed for the row above, so the
      # area's line in the rollup and the area opened out of it cannot state one coverage two ways.
      it "states how much of the area the durations cover" do
        get repository_path(mixed_area_run, spec_directory: "spec/models")

        expect(files_basis).to have_text("Across this area's examples, durations cover 1 of 3",
                                         normalize_ws: true)
        expect(files_basis).to have_no_text("Every one of the 3 examples")
      end

      # The denominator is this area's rows, never the Overview's suite size — that figure is
      # re-derived by SUM over shard reports and the two can legitimately differ.
      it "counts the area's own rows rather than the run's suite size" do
        repository = create_repository(user: @user)
        ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 1),
                            example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 2)],
               total_specs_count: 4_000)

        get repository_path(repository, spec_directory: "spec/models")

        expect(files_basis).to have_text("Across this area's examples, durations cover 1 of 2",
                                         normalize_ws: true)
        expect(files_panel).to have_no_text("4,000")
        expect(files_panel).to have_no_text("4000")
      end
    end

    # An area with rows and no timings is a LIST with no ranking — every file ties. It still
    # renders, because the files exist and their example counts are worth reading; what it must not
    # do is promise an order nothing measured.
    describe "an area none of whose examples were timed" do
      def untimed_area_run
        repository = create_repository(user: @user)
        ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 1),
                            example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 2)])
        repository
      end

      it "still lists the files, with no duration and no zero" do
        get repository_path(untimed_area_run, spec_directory: "spec/models")

        expect(file_row_paths).to eq(["spec/models/order_spec.rb", "spec/models/refund_spec.rb"])
        expect(file_rows.map { |row| row[:duration] }).to eq(["not reported", "not reported"])
        expect(files_panel).to have_no_text("0.00s")
      end

      it "does not claim the list is ranked" do
        get repository_path(untimed_area_run, spec_directory: "spec/models")

        expect(files_basis).to have_text("in path order", normalize_ws: true)
        expect(files_basis).to have_no_text("heaviest first")
        expect(files_basis).to have_text(
          "Not one of the 2 examples this run recorded in this area reported a duration",
          normalize_ws: true
        )
      end
    end

    # `?spec_directory=` is a URL a reader types, edits and bookmarks. An area this run recorded
    # nothing for is an ordinary answer — a renamed directory, a deleted one, a typo — and not a
    # request to error on. The rule `RequestedSpecFileParam` states, unchanged at this grain.
    describe "an area this run recorded nothing for" do
      it "renders an empty state naming the path, not an error" do
        get repository_path(area_run, spec_directory: "spec/ghosts")

        expect(response).to have_http_status(:ok)
        expect(files_panel).to have_text("No spec files in this directory", normalize_ws: true)
        expect(files_panel).to have_text("spec/ghosts", normalize_ws: true)
        expect(files_panel).to have_no_css("tbody tr")
      end

      # A prefix reading of the ask would answer this one with `spec/models`' files rather than
      # with nothing, which is the same fence the nested-area example draws from the other side.
      it "does not answer a partial path with the area it is a prefix of" do
        get repository_path(area_run, spec_directory: "spec/mod")

        expect(files_panel).to have_no_css("tbody tr")
      end

      it "renders no panel for a repository CI has never reported for" do
        get repository_path(create_repository(user: @user), spec_directory: "spec/models")

        expect(response).to have_http_status(:ok)
        expect(files_panel?).to be(false)
      end
    end

    # The three shapes a query string can legally parse into that are not a String. This parameter
    # reaches an EQUALITY comparison against `SpecObservation::DIRECTORY_EXPRESSION`, where an Array
    # does not raise at all — it becomes an `IN` list and answers a question nobody asked under a
    # caption naming one directory.
    describe "a spec-directory parameter that is not a path" do
      def expect_spec_directory_param_treated_as_no_ask(query)
        get repository_path(area_run, **query)

        expect(response).to have_http_status(:ok)
        expect(files_panel?).to be(false)
      end

      it_behaves_like "a surface that treats a malformed spec-directory parameter as no ask"

      # The positive path, beside the group it makes falsifiable: a guard that swallowed every value
      # would answer 200 on all three shapes above and render no panel here either.
      it "honours a spec-directory parameter that IS a path" do
        get repository_path(area_run, spec_directory: "spec/models")

        expect(files_panel?).to be(true)
        expect(file_rows.size).to eq(3)
      end

      # A blank ask is no ask: `DIRECTORY_EXPRESSION` coalesces a separator-less path to `.` and
      # `spec_file_path` is NOT NULL, so no row's area can be blank — an empty ask would open a
      # panel guaranteed to be empty, which is a worse answer than not opening one.
      it "treats a blank spec-directory parameter as no ask" do
        get repository_path(area_run, spec_directory: "")

        expect(response).to have_http_status(:ok)
        expect(files_panel?).to be(false)
      end
    end

    # One narrowed read, bounded by the size of the AREA and not of the suite — and none at all on a
    # page nobody asked an area of. A `select` over the run's rows filtered in Ruby is exactly the
    # shape that ships green on a three-row fixture and takes the page down on a real suite.
    describe "what the drill-in costs" do
      # `queries_against` comes from spec/support/query_capture.rb.

      it "costs one query, and only when an area was asked for" do
        repository = capped_area_run

        opened = queries_against("spec_observations") do
          get repository_path(repository, spec_directory: "spec/models")
        end
        unopened = queries_against("spec_observations") { get repository_path(repository) }

        expect(unopened.size).to eq(opened.size - 1)
      end

      it "costs the same number of queries on a 27-file area as on a 3-file one" do
        small = area_run
        large = capped_area_run

        small_queries = queries_against("spec_observations") do
          get repository_path(small, spec_directory: "spec/models")
        end
        large_queries = queries_against("spec_observations") do
          get repository_path(large, spec_directory: "spec/models")
        end

        expect(file_rows.size).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
        expect(large_queries.size).to eq(small_queries.size)
      end
    end

    # More files in one area than the panel lists, and TWO examples in each — so the file cap and
    # the example coverage are different numbers and one caption cannot satisfy both by accident.
    def capped_area_run
      repository = create_repository(user: @user, github_full_name: "acme/capped-area")
      files = SpecObservation::SPEC_DIRECTORY_FILES_LIMIT + 2
      specs = (1..files).flat_map do |i|
        (1..2).map do |j|
          example_spec(file_path: "spec/models/f#{format('%03d', i)}_spec.rb", duration: i.to_f,
                       line_number: (i * 10) + j)
        end
      end
      ingest(repository, specs, commit_sha: "feedfacecafe0003")
      repository
    end
  end
end
