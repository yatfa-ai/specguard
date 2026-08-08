# frozen_string_literal: true

require "rails_helper"

# The drill-down under the "Heaviest spec files" panel on repositories#show — ONE file's examples in
# the run that panel rolls up, opened with `?spec_file=`.
#
# The rung below spec/requests/repository_spec_file_durations_spec.rb and deliberately its own file,
# for the reason that one states for itself: every example here needs the same per-example fixture,
# and the panels above are edited by sibling slices.
#
# This is the first read in the application that narrows to a file rather than grouping by one, and
# the question it answers exists only because every other surface on the page is a capped ten: the
# rollup says a file cost six minutes across three hundred examples, and until this panel nothing
# anywhere said which three hundred.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: an untimed example is `result&.run_time` coming back nil on a real client, and a
# shared example group reporting a `spec_file_path` that differs from its `file_path` is a shape the
# RECORDER produces. A hand-built fixture would assert against a shape nothing in production writes.
RSpec.describe "Repository spec file examples", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#spec-file-examples")

  def panel?
    Capybara.string(response.body).has_css?("#spec-file-examples")
  end

  # ELEMENT-scoped, never panel-scoped: the basis paragraph has four scope sentences sharing most
  # of their words, so a panel-level `have_text` passes for the wrong one with the deciding branch
  # deleted.
  def basis_line = panel.find("#spec-file-examples-basis")

  def files_panel = Capybara.string(response.body).find("#spec-file-durations")

  # One row as a reader meets it: what the example is called, where it is DEFINED, what it took and
  # what CI said happened to it.
  def rows
    panel.all("tbody tr").map do |row|
      cells = row.all("td")
      test, duration, outcome = cells.map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { test: test, name: row_name(cells.first), duration: duration, outcome: outcome }
    end
  end

  def row_names = rows.map { |row| row[:name] }

  # The example's NAME, without the definition-site line rendered under it. The two share one cell,
  # so a whole-cell read would turn every ordering assertion in this file into an assertion about
  # paths as well — and the fallback row, where the name IS the location, has no span at all.
  def row_name(cell)
    site = cell.all("span").map(&:text).join

    cell.text.sub(site, "").gsub(/\s+/, " ").strip
  end

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
  # example is the state this panel lists where every ranking above excludes it, and the shared
  # builder defaults it to a number.
  def example_spec(file_path:, duration:, line_number:, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration).merge(attrs)
  end

  ORDER_SPEC = "spec/models/order_spec.rb"
  REFUND_SPEC = "spec/models/refund_spec.rb"

  # Two files, so every assertion about "this file's examples" has another file's rows to be wrong
  # about.
  def two_file_run
    repository = create_repository(user: @user)
    ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: 1.5, line_number: 1,
                                     name: "Order totals the line items"),
                        example_spec(file_path: ORDER_SPEC, duration: 4.0, line_number: 2,
                                     name: "Order refuses a negative quantity"),
                        example_spec(file_path: ORDER_SPEC, duration: 0.5, line_number: 3,
                                     name: "Order is valid with a customer"),
                        example_spec(file_path: REFUND_SPEC, duration: 9.0, line_number: 4,
                                     name: "Refund settles against the original charge")])
    repository
  end

  describe "opening a file from the rollup above" do
    # The panel this drills out of already rendered the path as plain text, so the way in costs no
    # query to offer — and until it existed, a reader who had found the heavy file had found the
    # end of the road.
    it "links each listed file to its own examples" do
      get repository_path(two_file_run)

      href = files_panel.find("a", text: ORDER_SPEC)[:href]

      expect(href).to include("spec_file=#{CGI.escape(ORDER_SPEC)}")
      expect(href).to include("#spec-file-examples")
    end

    # A list of choices with one of them taken. The drill-down sits a long way down the page, so a
    # reader arriving back at this table has to be told which row they are already looking at.
    it "marks the open file in the panel it was opened from" do
      get repository_path(two_file_run, spec_file: ORDER_SPEC)

      expect(files_panel.find("a", text: ORDER_SPEC)["aria-current"]).to eq("true")
      expect(files_panel.find("a", text: REFUND_SPEC)["aria-current"]).to be_nil
    end

    # `?branch=` anchors the "Suite growth" panel and nothing else. Opening a file must not
    # re-anchor a chart the reader did not touch.
    it "carries a branch ask through the link rather than dropping it" do
      get repository_path(two_file_run, branch: "main")

      expect(files_panel.find("a", text: ORDER_SPEC)[:href]).to include("branch=main")
    end

    it "renders no panel at all when no file was asked for" do
      get repository_path(two_file_run)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  describe "a file whose examples were timed" do
    # THE question this slice exists for: which examples are in the file the rollup says is heavy.
    # Slowest first, and scoped to the file — the other file's nine-second example is the run's
    # slowest and belongs to nothing here.
    it "lists that file's examples, slowest first, and no other file's" do
      get repository_path(two_file_run, spec_file: ORDER_SPEC)

      expect(row_names).to eq(["Order refuses a negative quantity",
                               "Order totals the line items",
                               "Order is valid with a customer"])
      expect(rows.map { |row| row[:duration] }).to eq(["4.00s", "1.50s", "0.50s"])
      expect(panel).to have_no_text("Refund settles against the original charge")
    end

    it "names the file it is listing" do
      get repository_path(two_file_run, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text(ORDER_SPEC, normalize_ws: true)
    end

    it "says the list is all of the file's examples, where nothing was cut" do
      get repository_path(two_file_run, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text("All 3 examples this run recorded in it, slowest first",
                                      normalize_ws: true)
      expect(basis_line).to have_text("Every one of them reported a duration", normalize_ws: true)
    end

    # What CI said happened, in the word CI sent, through the same seam the ranking panel above
    # renders — a row that never ran is exactly the row whose outcome a reader has come to find.
    it "reports each example's outcome" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: 1.0, line_number: 1,
                                       name: "Order totals the line items", outcome: "failed"),
                          example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 2,
                                       name: "Order refuses a negative quantity", outcome: nil)])

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(rows.map { |row| row[:outcome] }).to eq(["failed", "not reported"])
    end

    # `name` is nullable — the client sends nil for an example it could not describe — and a blank
    # cell is a row the reader can neither identify nor go and find.
    it "falls back to the definition site where the client sent no name" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: 1.0, line_number: 42,
                                       name: nil)])

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(row_names).to eq(["#{ORDER_SPEC}:42"])
    end

    # Bounded by `SpecObservation::FILE_EXAMPLES_LIMIT`, which is the file's own constant and not a
    # reuse of the ten every ranking on this page is capped at: a reader who opened a file to get
    # PAST a top ten is not served by another top ten.
    it "lists no more than its own limit, however many examples the file holds" do
      repository = create_repository(user: @user)
      count = SpecObservation::FILE_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(file_path: ORDER_SPEC, duration: i.to_f, line_number: i, name: "example #{i}")
      end)

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(rows.size).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(row_names.first).to eq("example #{count}")
    end

    # A capped list that does not disclose its cap is read as the whole file — the same lie by
    # omission the panel above refuses one grain up, where the population is files and here is
    # examples. The count has to come from the FILE and not from the rows on hand, which are the
    # truncated figure.
    it "says how many examples the file holds, not just how many it lists" do
      repository = create_repository(user: @user)
      count = SpecObservation::FILE_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(file_path: ORDER_SPEC, duration: i.to_f, line_number: i, name: "example #{i}")
      end)

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text(
        "The #{SpecObservation::FILE_EXAMPLES_LIMIT} slowest of the #{count} examples this run " \
        "recorded in it, slowest first", normalize_ws: true
      )
    end
  end

  # `spec_file_path` is the INCLUDING file and `file_path` the definition site, and they differ
  # exactly for a shared example group. A panel keyed on the first therefore lists rows defined
  # somewhere else — correctly, because this file is what RAN them — and the reader has to be able
  # to go and find them.
  describe "an example a shared example group defines elsewhere" do
    def shared_group_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: "spec/support/shared_examples.rb", line_number: 7,
                                       duration: 2.0, name: "behaves like an auditable record",
                                       spec_file_path: ORDER_SPEC,
                                       id: "./#{ORDER_SPEC}[1:1:1]"),
                          example_spec(file_path: ORDER_SPEC, line_number: 3, duration: 1.0,
                                       name: "Order totals the line items")])
      repository
    end

    it "lists it under the file that ran it, showing where it is defined" do
      get repository_path(shared_group_run, spec_file: ORDER_SPEC)

      expect(row_names.first).to eq("behaves like an auditable record")
      expect(rows.first[:test]).to include("spec/support/shared_examples.rb:7")
    end

    # The definition site is `file_path` + `line_number` — never `spec_file_path` + `line_number`,
    # which on this exact row would pair two halves from different files and point at whatever sits
    # on line 7 of the including one.
    it "does not pair the including file with the other file's line number" do
      get repository_path(shared_group_run, spec_file: ORDER_SPEC)

      expect(panel).to have_no_text("#{ORDER_SPEC}:7")
    end

    it "says the rows name where they are defined" do
      get repository_path(shared_group_run, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text("Each row names where it is DEFINED", normalize_ws: true)
    end
  end

  # The hazard `scope :timed` answers by EXCLUSION everywhere else on this page, answered here by
  # ORDERING instead — because a file's untimed examples are that file's population and a list that
  # dropped them would disagree with the count printed above it.
  describe "a file mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: 2.0, line_number: 1,
                                       name: "Order totals the line items"),
                          example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 2,
                                       name: "Order refuses a negative quantity"),
                          example_spec(file_path: ORDER_SPEC, duration: 5.0, line_number: 3,
                                       name: "Order is valid with a customer")])
      repository
    end

    # `duration_seconds: :desc` alone is NULLS FIRST in Postgres, so the naive ordering does not
    # merely include the example that never ran — it names it the slowest in the file.
    it "keeps the untimed examples in the list and at the end of it" do
      get repository_path(mixed_run, spec_file: ORDER_SPEC)

      expect(row_names).to eq(["Order is valid with a customer",
                               "Order totals the line items",
                               "Order refuses a negative quantity"])
    end

    it "shows no duration for the untimed example rather than a zero" do
      get repository_path(mixed_run, spec_file: ORDER_SPEC)

      expect(rows.last[:duration]).to eq("not reported")
      expect(panel).to have_no_text("0.00s")
    end

    # In the spelling `SpecFileDurations::Row#coverage_label` fixed for the row above, through
    # `SpecFileExamples#coverage_label` — so the file's line in the rollup and the file opened out
    # of it cannot state the same coverage two different ways.
    it "states how much of the file the durations cover" do
      get repository_path(mixed_run, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text("Durations here cover 2 of 3", normalize_ws: true)
      expect(basis_line).to have_text("The other 1 reported none and sit at the END",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("Every one of them reported a duration")
    end

    # THE SHAPE THIS PANEL WAS BUILT FOR, and the one both captions used to lie about: the big file
    # a partial or interrupted client run left with a large untimed tail. The timed rows run out
    # before the cap does, so the page ends in untimed rows and MOST of the untimed population is
    # not on it.
    #
    # "The 50 slowest of the 104" is false of that page twice — the tail rows are the lowest-`id`
    # rows of something nothing ranked, and are not the slowest of anything — and "the other 100
    # reported none and sit at the END of the list" asserts a population is visible where 54 of it
    # is absent. A reader acting on either concludes this file's untimed population is 46 examples.
    it "does not call an untimed tail the slowest, nor place absent rows at the end of the list" do
      repository = create_repository(user: @user)
      untimed = SpecObservation::FILE_EXAMPLES_LIMIT * 2
      ingest(repository,
             (1..4).map do |i|
               example_spec(file_path: ORDER_SPEC, duration: i.to_f, line_number: i,
                            name: "timed #{i}")
             end + (1..untimed).map do |i|
               example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 100 + i,
                            name: "untimed #{i}")
             end)

      get repository_path(repository, spec_file: ORDER_SPEC)

      shown_untimed = SpecObservation::FILE_EXAMPLES_LIMIT - 4
      expect(rows.size).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(rows.count { |row| row[:duration] == "not reported" }).to eq(shown_untimed)
      expect(basis_line).to have_no_text("#{SpecObservation::FILE_EXAMPLES_LIMIT} slowest")
      expect(basis_line).to have_text(
        "The 4 timed examples of the #{untimed + 4} this run recorded in it, slowest first, then " \
        "#{shown_untimed} of the #{untimed} that reported no duration and nothing ranked — the " \
        "remaining #{untimed - shown_untimed} are not shown.", normalize_ws: true
      )
      expect(basis_line).to have_text(
        "#{shown_untimed} of those are at the END of this list rather than at the head of it, " \
        "and the remaining #{untimed - shown_untimed} are not on this page at all",
        normalize_ws: true
      )
    end

    # The denominator is this file's rows, never the Overview's suite size — that figure is
    # re-derived by SUM over shard reports and the two can legitimately differ. There is no
    # per-file counter anywhere else to borrow in any case.
    it "counts the file's own rows rather than the run's suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: 1.0, line_number: 1),
                          example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 2)],
             total_specs_count: 4_000)

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text("All 2 examples this run recorded in it", normalize_ws: true)
      expect(panel).to have_no_text("4,000")
      expect(panel).to have_no_text("4000")
    end
  end

  # A file with rows and no timings is a LIST with no ranking — every row ties. It still renders,
  # because the examples exist and their outcomes are worth reading; what it must not do is promise
  # an order nothing measured.
  describe "a file none of whose examples were timed" do
    def untimed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 1,
                                       name: "Order totals the line items", outcome: "failed"),
                          example_spec(file_path: ORDER_SPEC, duration: nil, line_number: 2,
                                       name: "Order refuses a negative quantity", outcome: nil)])
      repository
    end

    it "still lists the examples, with no duration and no zero" do
      get repository_path(untimed_run, spec_file: ORDER_SPEC)

      expect(row_names).to eq(["Order totals the line items", "Order refuses a negative quantity"])
      expect(rows.map { |row| row[:duration] }).to eq(["not reported", "not reported"])
      expect(panel).to have_no_text("0.00s")
    end

    # "The slowest first" over a file nothing timed is a promise about an order that was never
    # measured, and on a truncated file it becomes "the 50 slowest of 340" — the sentence a reader
    # is most likely to act on, about a ranking that does not exist.
    it "does not claim the list is ranked" do
      get repository_path(untimed_run, spec_file: ORDER_SPEC)

      expect(basis_line).to have_text("in the order this run recorded them", normalize_ws: true)
      expect(basis_line).to have_no_text("slowest first")
    end

    # What is left to report about those rows, still reported: a delivery that timed nothing and
    # failed something would otherwise disclose nothing at all.
    it "still says what CI reported for them" do
      get repository_path(untimed_run, spec_file: ORDER_SPEC)

      expect(rows.map { |row| row[:outcome] }).to eq(["failed", "not reported"])
    end

    # The two axes MEETING — the sentence `RepositoriesHelper#spec_file_examples_scope_sentence`
    # says it exists for, and which no example above constructs: the truncation examples are all
    # timed and the untimed examples are all under the cap, so nothing stood where "the 50 slowest
    # of 340" could be written over a file nothing ranked.
    it "does not call a truncated list of untimed examples the slowest of anything" do
      repository = create_repository(user: @user)
      count = SpecObservation::FILE_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(file_path: ORDER_SPEC, duration: nil, line_number: i, name: "example #{i}")
      end)

      get repository_path(repository, spec_file: ORDER_SPEC)

      expect(rows.size).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(basis_line).to have_text(
        "The first #{SpecObservation::FILE_EXAMPLES_LIMIT} of the #{count} examples this run " \
        "recorded in it, in the order this run recorded them", normalize_ws: true
      )
      expect(basis_line).to have_no_text("slowest")
    end
  end

  # `?spec_file=` is a URL a reader types, edits and bookmarks. A path this run recorded nothing for
  # is an ordinary answer — a renamed file, a deleted one, a typo — and not a request to error on.
  describe "a file this run recorded nothing for" do
    it "renders an empty state naming the path, not an error" do
      get repository_path(two_file_run, spec_file: "spec/models/ghost_spec.rb")

      expect(response).to have_http_status(:ok)
      expect(panel).to have_text("No examples for this file", normalize_ws: true)
      expect(panel).to have_text("spec/models/ghost_spec.rb", normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    it "renders no panel for a repository CI has never reported for" do
      get repository_path(create_repository(user: @user), spec_file: ORDER_SPEC)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # The three shapes a query string can legally parse into that are not a String. This parameter
  # reaches `where(spec_file_path: …)` on a plain string column, where an Array does not raise at
  # all — it becomes an `IN` list and answers a question nobody asked under a caption naming one
  # file. A silent wrong answer needs the guard more than a crash does.
  describe "a spec-file parameter that is not a path" do
    def expect_spec_file_param_treated_as_no_ask(query)
      get repository_path(two_file_run, **query)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end

    it_behaves_like "a surface that treats a malformed spec-file parameter as no ask"

    # The positive path, beside the group it makes falsifiable: a guard that swallowed every value
    # would answer 200 on all three shapes above and render no panel here either.
    it "honours a spec-file parameter that IS a path" do
      get repository_path(two_file_run, spec_file: ORDER_SPEC)

      expect(panel?).to be(true)
      expect(rows.size).to eq(3)
    end

    # A blank ask is no ask: `spec_file_path` is NOT NULL and `Ingest::ObservationRecorder` falls
    # back to `file_path` for a producer that sends none, so no row can carry a blank — an empty
    # ask would open a panel guaranteed to be empty, which is a worse answer than not opening one.
    it "treats a blank spec-file parameter as no ask" do
      get repository_path(two_file_run, spec_file: "")

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # One narrowed read, bounded by the size of the FILE and not of the suite — and none at all on a
  # page nobody asked a file of. A `select` over the run's rows filtered in Ruby is exactly the
  # shape that ships green on a three-row fixture and takes the page down on a real suite.
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

    def repository_with(example_count, name:)
      repository = create_repository(user: @user, github_full_name: name)
      ingest(repository, (1..example_count).map do |i|
        example_spec(file_path: ORDER_SPEC, duration: i.to_f, line_number: i, name: "example #{i}")
      end)
      repository
    end

    it "costs the same number of queries on a 200-example file as on a 3-example one" do
      small = repository_with(3, name: "acme/small-suite")
      large = repository_with(200, name: "acme/large-suite")

      small_queries = queries_against("spec_observations") do
        get repository_path(small, spec_file: ORDER_SPEC)
      end
      large_queries = queries_against("spec_observations") do
        get repository_path(large, spec_file: ORDER_SPEC)
      end

      # The large page renders a full list of the cap, and costs what the three-example page cost.
      expect(rows.size).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      # An absolute ceiling too: equality alone would still hold if both pages regressed to a
      # fixed-but-wasteful number of passes over the same table. FIVE reads serve this page with a
      # file open — the four the page already took (the ranking and its coverage aggregate for
      # "Slowest tests", one grouped aggregate each for the by-file and by-directory rollups) and
      # ONE for this panel. The list and both figures in its caption come back on that one read:
      # the counts are windows on it rather than a second aggregate.
      expect(large_queries.size).to eq(5)
    end

    # The whole drill-down is off the default page's budget. A reader who never opens a file pays
    # exactly what they paid before this panel existed.
    it "asks nothing of the table when no file was asked for" do
      repository = repository_with(200, name: "acme/unopened-suite")

      opened = queries_against("spec_observations") do
        get repository_path(repository, spec_file: ORDER_SPEC)
      end
      unopened = queries_against("spec_observations") { get repository_path(repository) }

      expect(unopened.size).to eq(opened.size - 1)
      expect(unopened.size).to eq(4)
    end
  end
end
