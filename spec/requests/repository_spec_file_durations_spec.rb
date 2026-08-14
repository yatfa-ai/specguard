# frozen_string_literal: true

require "rails_helper"

# The "Heaviest spec files" panel on repositories#show — where ONE run's wall clock actually went,
# rolled up by the file that ran each example.
#
# The sibling of spec/requests/repository_slowest_examples_spec.rb and deliberately its own file,
# for the reason that one states for itself: every example here needs the same per-example fixture,
# and the Overview/API-keys file is edited by sibling slices.
#
# The two panels answer different questions off the same rows and neither derives the other. A
# ten-row ranking by INDIVIDUAL cost cannot surface a file that is heavy because it holds four
# hundred cheap examples, which at the 20,000-example design point is the common way for a suite to
# spend its time.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: an untimed example is `result&.run_time` coming back nil on a real client, and a
# shared example group reporting a `spec_file_path` that differs from its `file_path` is a shape the
# RECORDER produces. A hand-built fixture would assert against a shape nothing in production writes.
RSpec.describe "Repository heaviest spec files", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-file-durations")

  def panel?
    Capybara.string(response.body).has_css?("#spec-file-durations")
  end

  # ELEMENT-scoped, never panel-scoped: the basis paragraph has two states that share most of their
  # words, so a panel-level `have_text` passes for the wrong state with the deciding branch deleted.
  def basis_line = panel.find("#spec-file-durations-basis")

  # One row as a reader meets it: the file, what its total was summed over, and the total.
  def rows
    panel.all("tbody tr").map do |row|
      path, coverage, duration = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, coverage: coverage, duration: duration }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  # One ingested run, through the producer. `specs` are the wire hashes a client POSTs; the recorder
  # reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
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
    def timed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.5, line_number: 1),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: 2.5, line_number: 2),
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: 9.0, line_number: 3),
                          example_spec(file_path: "spec/models/user_spec.rb", duration: 0.5, line_number: 4)])
      repository
    end

    # More files than the panel lists, so the listed count and the run's own count are different
    # numbers and one caption cannot satisfy both by accident.
    def twenty_five_file_run
      repository = create_repository(user: @user)
      specs = (1..25).map do |i|
        example_spec(file_path: "spec/models/f#{format('%02d', i)}_spec.rb", duration: i.to_f, line_number: i)
      end
      ingest(repository, specs)
      repository
    end

    # The panel's whole claim: a file's wall clock is the SUM of its examples', so a file holding
    # two middling examples outranks one holding a single quicker one — a ranking of individual
    # examples orders these three files differently and is not this question.
    it "ranks the files by the wall clock the run spent in each, heaviest first" do
      get repository_path(timed_run)

      expect(row_paths).to eq(["spec/models/refund_spec.rb",
                               "spec/models/order_spec.rb",
                               "spec/models/user_spec.rb"])
      expect(rows.map { |row| row[:duration] }).to eq(["9.00s", "4.00s", "0.50s"])
    end

    it "says every listed total covers the whole of its file, where every example was timed" do
      get repository_path(timed_run)

      expect(rows.map { |row| row[:coverage] }).to eq(["1 of 1", "2 of 2", "1 of 1"])
      expect(basis_line).to have_text("Every example in every file listed reported a duration",
                                      normalize_ws: true)
    end

    # Bounded by `SpecObservation::HEAVIEST_FILES_LIMIT`: a list of the heaviest files, not a
    # rendering of the suite's directory tree.
    it "lists no more than the heaviest ten, however many files the run touched" do
      get repository_path(twenty_five_file_run)

      expect(rows.size).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(row_paths.first).to eq("spec/models/f25_spec.rb")
      expect(row_paths.last).to eq("spec/models/f16_spec.rb")
    end

    # A capped list that does not disclose its cap is read as the whole story, which is the same
    # lie by omission the per-row coverage column refuses one grain down: on a run spread over
    # three hundred files, ten rows captioned "the files this run spent the most wall clock in"
    # describe three per cent of it and say so nowhere. The caption has to name what the list is
    # the head OF — and `rows.size` cannot, because it is the truncated figure.
    it "says how many files the run touched, not just how many it lists" do
      get repository_path(twenty_five_file_run)

      expect(basis_line).to have_text("The 10 heaviest of the 25 files the run named above recorded",
                                      normalize_ws: true)
    end

    # And the other half of the disclosure: a run whose files all fit is not truncated, and saying
    # "the 3 heaviest of the 3 files" would make a complete list look like a sample. The count is
    # still stated — a reader should not have to count table rows to learn it.
    it "says the list is all of them, where nothing was cut" do
      get repository_path(timed_run)

      expect(basis_line).to have_text("All 3 files the run named above recorded", normalize_ws: true)
      expect(basis_line).to have_no_text("heaviest of the")
    end

    # A shared example group reports `spec/support/shared_examples.rb` as its definition site, and
    # the file that actually RAN it appears only as `spec_file_path`. Rolling up on `file_path`
    # would attribute every including file's time to a helper that ran nothing — the exact shape
    # spec/requests/api/v1/ingest_spec.rb pins at the ingest end.
    it "lands a shared example group's time on the file that included it, not on the helper" do
      repository = create_repository(user: @user)
      shared = "spec/support/shared_examples.rb"
      ingest(repository, [example_spec(file_path: shared, line_number: 4, duration: 1.5,
                                       spec_file_path: "spec/models/order_spec.rb",
                                       id: "./spec/models/order_spec.rb[1:1:1]"),
                          example_spec(file_path: shared, line_number: 4, duration: 2.5,
                                       spec_file_path: "spec/models/refund_spec.rb",
                                       id: "./spec/models/refund_spec.rb[1:1:1]")])

      get repository_path(repository)

      expect(row_paths).to eq(["spec/models/refund_spec.rb", "spec/models/order_spec.rb"])
      expect(rows.map { |row| row[:duration] }).to eq(["2.50s", "1.50s"])
      expect(row_paths).not_to include(shared)
    end
  end

  # THE hazard this slice exists to refuse, and the one the ranking panel's `scope :timed` could
  # not be reused for. Excluding untimed rows changes each surviving GROUP'S OWN population: a
  # half-untimed file silently reports half its time, and a wholly untimed file comes back as SQL
  # NULL, which `group(...).sum` casts to `0.0` on the way into Ruby and a naive cell renders
  # "0.00s" — a run that measured nothing wearing the spelling of a measurement.
  describe "a run mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 4.0, line_number: 1),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 2),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 3),
                          example_spec(file_path: "spec/models/never_ran_spec.rb", duration: nil, line_number: 4),
                          example_spec(file_path: "spec/models/never_ran_spec.rb", duration: nil, line_number: 5)])
      repository
    end

    it "states how much of a partly timed file its total was summed over" do
      get repository_path(mixed_run)

      expect(rows.first).to eq(path: "spec/models/order_spec.rb", coverage: "1 of 3", duration: "4.00s")
    end

    # Both halves fail differently. A cell rendering the aggregate's nil through
    # `group(...).sum(:duration_seconds)` prints "0.00s"; an ordering left at plain `DESC` is NULLS
    # FIRST in Postgres and names the file nothing was measured in the heaviest in the run.
    it "shows no total for a wholly untimed file, and does not rank it above a measured one" do
      get repository_path(mixed_run)

      expect(rows.last).to eq(path: "spec/models/never_ran_spec.rb", coverage: "0 of 2",
                              duration: "not reported")
      expect(row_paths.first).to eq("spec/models/order_spec.rb")
      expect(panel).to have_no_text("0.00s")
    end

    it "says what the coverage column is, where the totals do not all cover their files" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("a file that reported none has no total to state rather than a zero",
                                      normalize_ws: true)
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size — that figure
    # is re-derived by SUM over shard reports and the two can legitimately differ. There is no
    # by-file counter anywhere else to borrow in any case.
    it "counts each file's own rows rather than the run's suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/models/order_spec.rb", duration: 1.0, line_number: 1),
                          example_spec(file_path: "spec/models/order_spec.rb", duration: nil, line_number: 2)],
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
                          example_spec(file_path: "spec/models/refund_spec.rb", duration: nil, line_number: 2)])

      get repository_path(repository)

      expect(panel).to have_text("No timings on this run", normalize_ws: true)
      expect(panel).to have_text("no wall clock to attribute to any file", normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
      expect(panel).to have_no_text("0.00s")
    end

    # The empty state says how much ran unmeasured, rather than only that something did — the same
    # figure the ranking panel above states for its own absence. In FILES, because that is the
    # count this read has exactly: an example count summed off the rows on hand would be summed
    # over a capped ten of them and understate a wider run while looking suite-wide.
    it "says how many files went unmeasured, counting past the limit" do
      repository = create_repository(user: @user)
      ingest(repository, (1..12).map do |i|
        example_spec(file_path: "spec/models/f#{format('%02d', i)}_spec.rb", duration: nil, line_number: i)
      end)

      get repository_path(repository)

      expect(panel).to have_text("This run recorded examples in 12 files", normalize_ws: true)
    end
  end

  # A run with no per-example rows at all — everything ingested before those rows existed, and every
  # client that sends no per-example detail. There is no per-file grain to disclose, and an empty
  # panel on every such run would read as a finding about the suite when it is a fact about the
  # payload. The Overview's never-ingested empty state is this page's one statement of absence.
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

  # The rollup is one grouped aggregate in SQL, so the page costs the same on a 20,000-example suite
  # as on a 20-example one. A `group_by` over `has_many` walked in Ruby is exactly the shape that
  # ships green on a three-row fixture and takes the page down on a real suite.
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

    it "costs the same number of queries at 200 examples over 25 files as at 3 over 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      ingest(small, (1..3).map do |i|
        example_spec(file_path: "spec/models/s#{i}_spec.rb", duration: i.to_f, line_number: i)
      end)
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      ingest(large, (1..200).map do |i|
        example_spec(file_path: "spec/models/f#{format('%02d', i % 25)}_spec.rb",
                     duration: i.to_f, line_number: i, id: "./spec/models/f#{i % 25}_spec.rb[1:#{i}]")
      end, commit_sha: "feedfacecafe0002")

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      # The large page renders a full ten rows, and costs what the three-file page cost.
      expect(rows.size).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      # An absolute ceiling too: equality alone would still hold if both pages regressed to a
      # fixed-but-wasteful number of passes over the same table. FIVE reads of this table serve
      # this page — the ranking and its coverage aggregate for the "Slowest tests" panel above, ONE
      # grouped aggregate for this one, ONE more for the "Heaviest spec directories" panel below
      # it, which takes these same rows up to the code area, and the cross-run panel's gating probe
      # (this fixture holds a single run, so that panel establishes it cannot compare outcomes and
      # asks nothing further; its own budget is asserted in
      # spec/requests/repository_unstable_tests_spec.rb). That fourth query is the directory
      # panel's entire budget, as the third is this one's: each rung is one grouped aggregate and
      # neither is derivable from the other.
      #
      # RECOUNTED AT 7 by SPGD-344, which added the "Descriptions this run recorded more than once"
      # panel: TWO further reads of these same rows at a grain neither rung above reaches — grouped
      # by DESCRIPTION rather than by where the code lives — plus the count of the rows carrying no
      # description, which that grouping excludes in its WHERE clause and therefore cannot count for
      # itself. Only the first of the two is a `GROUP BY`, which is why the grouping tally below
      # moves to three rather than four: the presence count is a plain aggregate over one run.
      expect(large_queries.size).to eq(7)
      expect(large_queries.count { |sql| sql.include?("GROUP BY") }).to eq(3)
    end
  end

  # The panel above this one used to declare a by-file rollup something this page does not do, and
  # the panel itself used to defer the by-DIRECTORY rollup to an index that was never needed. Both
  # halves are now false: the two rollups sit on this page as two panels. A stale disclosure is a
  # live instruction not to build the thing that is now built, so neither claim may survive — and
  # the by-directory one may not survive in the softened spelling either, since "rolls nothing up
  # by directory" is exactly the sentence a reader would take as a standing prohibition.
  describe "the carve-outs the panels above state" do
    it "no longer tells its authors the page rolls nothing up by file or by directory" do
      source = Rails.root.join("app/views/repositories/show.html.erb").read

      expect(source).not_to include("rolls nothing up by file or directory")
      expect(source).not_to include("rolls nothing up by directory")
      # And the migration the by-file panel deferred the subtree rollup to is not still being
      # waited on: the rollup shipped without one, because the index that comment named governs a
      # prefix predicate this read does not issue.
      expect(source).not_to include("needs its own migration")
      # The replacement truth the retired carve-outs gave way to is still stated — if this read
      # stops reaching the panels, this fails instead of passing.
      expect(source).to include("Both rollups now exist, in the two panels below this one")
    end
  end
end
