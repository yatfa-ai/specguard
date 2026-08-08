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
end
