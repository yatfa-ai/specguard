# frozen_string_literal: true

require "rails_helper"

# The drill-down under the "Descriptions this run recorded more than once" panel on
# repositories#show — ONE description's examples in the run that panel ranks, opened with
# `?repeated_description=`.
#
# The rung below spec/requests/repository_repeated_descriptions_spec.rb and deliberately its own
# file, for the reason every sibling drill-down spec states for itself: every example here needs the
# same per-example fixture, and the panels above are edited by sibling slices.
#
# Until this panel, that ranking was the only ranked list on the page whose rows dead-ended.
# `SpecObservation.repeated_descriptions_in` is an aggregate — a name, a SUM, two counts and the
# distinct files — out of which no member row escapes, so a reader told that eight examples share a
# description and cost ninety seconds between them had no way whatever to learn which eight.
#
# The `?spec_file=` panel is NOT that way and several examples here pin why: it lists every example
# of a file capped at fifty and ranked by duration, so a reader following a two-file group through it
# gets two lists of unrelated rows that need not contain the group's members at all.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: an untimed example is `result&.run_time` coming back nil on a real client, two
# examples sharing a description in one run is what the RECORDER produces from a table-driven loop,
# and a shared example group reporting a `spec_file_path` that differs from its `file_path` is a
# shape it produces too. A hand-built fixture would assert against a shape nothing in production
# writes.
RSpec.describe "Repository repeated description examples", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#repeated-description-examples")

  def panel? = Capybara.string(response.body).has_css?("#repeated-description-examples")

  # ELEMENT-scoped, never panel-scoped: the basis paragraph has five scope sentences sharing most of
  # their words, so a panel-level `have_text` passes for the wrong one with the deciding branch
  # deleted.
  def basis_line = panel.find("#repeated-description-examples-basis")

  def ranking_panel = Capybara.string(response.body).find("#repeated-descriptions")

  # One row as a reader meets it: where it RAN, where it is DEFINED, what it took and what CI said
  # happened to it. The two paths are separate columns rather than one cell, which is the whole point
  # of the panel's shared-example-group reading, so they are read separately here too.
  def rows
    panel.all("tbody tr").map do |row|
      ran_in, defined_at, duration, outcome = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { ran_in: ran_in, defined_at: defined_at, duration: duration, outcome: outcome }
    end
  end

  def ran_in_paths = rows.map { |row| row[:ran_in] }

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` is passed at every call site, nils included — an untimed
  # example is a state this panel LISTS where every ranking above excludes it, and the shared builder
  # defaults it to a number.
  def example_spec(name:, duration:, line_number:, file_path: order_spec, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  # The four fixture names are METHODS and deliberately not constants. A constant assigned inside an
  # `RSpec.describe` block is not scoped to the example group — blocks open no constant scope, so it
  # lands on `Object` — and spec/requests/repository_spec_file_examples_spec.rb already assigns
  # `ORDER_SPEC` and `REFUND_SPEC` there. A second file assigning those names would not merely warn:
  # whichever loaded LAST would decide the value BOTH files read at run time, and this file's refund
  # path is a different one. That is a cross-file coupling neither file's author could see from
  # inside it, and methods have none of it.
  def order_spec = "spec/models/order_spec.rb"

  def refund_spec = "spec/requests/refunds_spec.rb"

  # The repeated description this file opens, and a second one to be wrong about.
  def looped = "settles the balance"

  def other = "refuses a negative quantity"

  # One description carried by three examples across two files, one carried by two, and one carried
  # by a single example — so every assertion about "this description's examples" has other rows to be
  # wrong about, and `HAVING COUNT(*) > 1` has something real to exclude.
  def two_group_run
    repository = create_repository(user: @user)
    ingest(repository, [example_spec(name: looped, duration: 4.0, line_number: 1),
                        example_spec(name: looped, duration: 1.5, line_number: 2),
                        example_spec(name: looped, duration: 0.5, line_number: 3,
                                     file_path: refund_spec),
                        example_spec(name: other, duration: 9.0, line_number: 4),
                        example_spec(name: other, duration: 8.0, line_number: 5),
                        example_spec(name: "is valid with a customer", duration: 2.0, line_number: 6)])
    repository
  end

  describe "opening a description from the ranking above" do
    # The panel this drills out of already rendered the description as plain text, so the way in
    # costs no query to offer — and until it existed, a reader who had found the heaviest repetition
    # in their suite had found the end of the road.
    it "links each ranked description to its own examples" do
      get repository_path(two_group_run)

      href = ranking_panel.find("a", text: looped)[:href]

      expect(href).to include("repeated_description=#{CGI.escape(looped)}")
      expect(href).to include("#repeated-description-examples")
    end

    # A list of choices with one of them taken. The drill-down sits a long way down the page, so a
    # reader arriving back at this table has to be told which row they are already looking at.
    it "marks the open description in the panel it was opened from" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(ranking_panel.find("a", text: looped)["aria-current"]).to eq("true")
      expect(ranking_panel.find("a", text: other)["aria-current"]).to be_nil
    end

    # `?branch=` anchors the "Suite growth" panel and nothing else. Opening a description must not
    # re-anchor a chart the reader did not touch.
    it "carries a branch ask through the link rather than dropping it" do
      get repository_path(two_group_run, branch: "main")

      expect(ranking_panel.find("a", text: looped)[:href]).to include("branch=main")
    end

    # The reciprocity every drill-down link on this page keeps: opening one panel is not a request to
    # close another the reader opened separately.
    it "carries an open file and an open area through the link" do
      get repository_path(two_group_run, spec_file: order_spec, spec_directory: "spec/models")

      href = ranking_panel.find("a", text: looped)[:href]

      expect(href).to include("spec_file=#{CGI.escape(order_spec)}")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
    end

    # The same invariant in the other direction, and it is the one that would break silently: the
    # file drill-down's own links and its way out predate this parameter, so a reader who opened a
    # description and then a file would have had the description closed under them by a control that
    # says "Close file".
    it "carries an open description through the file panel's links and its way out" do
      get repository_path(two_group_run, repeated_description: looped, spec_file: order_spec)

      expect(Capybara.string(response.body).find("#spec-file-durations").find("a", text: order_spec)[:href])
        .to include("repeated_description=#{CGI.escape(looped)}")
      expect(Capybara.string(response.body).find("#spec-file-examples").find_link("Close file")[:href])
        .to include("repeated_description=#{CGI.escape(looped)}")
    end

    it "renders no panel at all when no description was asked for" do
      get repository_path(two_group_run)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  describe "a description whose examples were timed" do
    # THE question this slice exists for: which examples are in the group the ranking says is heavy.
    # Slowest first, and scoped to the description — the other group's nine-second example is the
    # run's slowest and belongs to nothing here.
    it "lists that description's examples, slowest first, and no other description's" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(rows.map { |row| row[:duration] }).to eq(["4.00s", "1.50s", "0.50s"])
      expect(rows.map { |row| row[:defined_at] }).to eq(["#{order_spec}:1", "#{order_spec}:2",
                                                         "#{refund_spec}:3"])
      expect(panel).to have_no_text("#{order_spec}:4")
    end

    it "names the description it is listing" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(basis_line).to have_text(looped, normalize_ws: true)
    end

    it "says the list is all of the group's examples, where nothing was cut" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(basis_line).to have_text("All 3 examples this run recorded under it, slowest first",
                                      normalize_ws: true)
      expect(basis_line).to have_text("Every one of them reported a duration", normalize_ws: true)
    end

    # What CI said happened, in the word CI sent. A group whose members ended differently is a
    # repetition doing different work under one sentence, and that is visible in no other column.
    it "reports each example's outcome" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: looped, duration: 1.0, line_number: 1, outcome: "failed"),
                          example_spec(name: looped, duration: 0.5, line_number: 2, outcome: nil)])

      get repository_path(repository, repeated_description: looped)

      expect(rows.map { |row| row[:outcome] }).to eq(["failed", "not reported"])
    end

    # Bounded by `SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT`, which is the group's own
    # constant and not a reuse of the ten the ranking above is capped at: a reader who opened a
    # description to get PAST a top ten is not served by another top ten.
    it "lists no more than its own limit, however many examples the group holds" do
      repository = create_repository(user: @user)
      count = SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(name: looped, duration: i.to_f, line_number: i)
      end)

      get repository_path(repository, repeated_description: looped)

      expect(rows.size).to eq(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
      expect(rows.first[:defined_at]).to eq("#{order_spec}:#{count}")
    end

    # A capped list that does not disclose its cap is read as the whole group — the same lie by
    # omission every panel on this page refuses. The count has to come from the GROUP and not from
    # the rows on hand, which are the truncated figure.
    it "says how many examples the group holds, not just how many it lists" do
      repository = create_repository(user: @user)
      count = SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(name: looped, duration: i.to_f, line_number: i)
      end)

      get repository_path(repository, repeated_description: looped)

      expect(basis_line).to have_text(
        "The #{SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT} slowest of the #{count} " \
        "examples this run recorded under it, slowest first", normalize_ws: true
      )
    end

    # `#complete?` is `timed_count == recorded_count`, both counted before the cap, so it is true of
    # a 25-row page of a 30-example group; spent as "the list covers the whole of what this run
    # recorded here" it would deny the sentence directly before it, which has just said the page
    # holds 25 of 30. The branch the file drill-down was fixed to carry, pinned here before it can be
    # written the other way.
    it "does not call a truncated page the whole of what the run recorded" do
      repository = create_repository(user: @user)
      count = SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT + 5
      ingest(repository, (1..count).map do |i|
        example_spec(name: looped, duration: i.to_f, line_number: i)
      end)

      get repository_path(repository, repeated_description: looped)

      expect(basis_line).to have_no_text("the list covers the whole of what this run recorded here")
      expect(basis_line).to have_text(
        "Every one of the #{count} reported a duration, so the ranking these " \
        "#{SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT} were drawn from covers the whole " \
        "of what this run recorded here", normalize_ws: true
      )
    end
  end

  # The rung that CLOSES the chain the controller has always claimed: area → file → example, and now
  # description → example → file.
  describe "the file each listed example ran in" do
    it "links each row's file into the spec-file drill-down" do
      get repository_path(two_group_run, repeated_description: looped)

      href = panel.first("tbody tr").find("a", text: order_spec)[:href]

      expect(href).to include("spec_file=#{CGI.escape(order_spec)}")
      expect(href).to include("#spec-file-examples")
    end

    # Following a member's file must not close the description it was followed FROM — otherwise the
    # reader loses the list they were reading the moment they act on one of its rows.
    it "carries the open description through that link" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(panel.first("tbody tr").find("a", text: order_spec)[:href])
        .to include("repeated_description=#{CGI.escape(looped)}")
    end

    it "marks the open file among the rows" do
      get repository_path(two_group_run, repeated_description: looped, spec_file: refund_spec)

      links = panel.all("tbody tr a")

      expect(links.select { |link| link["aria-current"] == "true" }.map(&:text)).to eq([refund_spec])
    end

    # The way out, which no other control offers: the parameter is removable only by editing the URL
    # otherwise, and it must not take a file or an area the reader opened separately with it.
    it "offers a way out that keeps every other ask" do
      get repository_path(two_group_run, repeated_description: looped, branch: "main",
                                         spec_file: order_spec, spec_directory: "spec/models")

      href = panel.find_link("Close description")[:href]

      expect(href).not_to include("repeated_description")
      expect(href).to include("branch=main")
      expect(href).to include("spec_file=#{CGI.escape(order_spec)}")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
      expect(href).to include("#repeated-descriptions")
    end

    # `spec_file_path` is NULLABLE in the schema. `Ingest::ObservationRecorder#attributes` populates
    # it by falling back to `file_path`, so the producer cannot write a nil and the fixture cannot
    # either — which is exactly why the column is set directly here. A defensive branch nothing
    # exercises is a branch that gets deleted as dead, and the cell it guards would otherwise render
    # a link to nowhere.
    it "says so rather than linking nowhere when a row has no including file" do
      repository = two_group_run
      SpecObservation.where(name: looped, line_number: 3).update_all(spec_file_path: nil)

      get repository_path(repository, repeated_description: looped)

      expect(ran_in_paths.last).to eq("not reported")
      expect(rows.last[:defined_at]).to eq("#{refund_spec}:3")
    end
  end

  # `spec_file_path` is the INCLUDING file and `file_path` the definition site, and they differ
  # exactly for a shared example group — which on THIS panel is not a footnote but one of the three
  # readings the reader came to distinguish. Four rows sharing one definition site are one test run
  # four times; four rows at four sites are four tests that happen to say the same thing.
  describe "a description a shared example group defines in one place" do
    def shared_group_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: looped, duration: 2.0, line_number: 7,
                                       file_path: "spec/support/shared_examples.rb",
                                       spec_file_path: order_spec,
                                       id: "./#{order_spec}[1:1:1]"),
                          example_spec(name: looped, duration: 1.0, line_number: 7,
                                       file_path: "spec/support/shared_examples.rb",
                                       spec_file_path: refund_spec,
                                       id: "./#{refund_spec}[1:1:1]")])
      repository
    end

    it "names both the file that ran it and the one place it is defined" do
      get repository_path(shared_group_run, repeated_description: looped)

      expect(ran_in_paths).to eq([order_spec, refund_spec])
      expect(rows.map { |row| row[:defined_at] })
        .to eq(["spec/support/shared_examples.rb:7", "spec/support/shared_examples.rb:7"])
    end

    # The definition site is `file_path` + `line_number` — never `spec_file_path` + `line_number`,
    # which on these exact rows would pair two halves from different files and point at whatever sits
    # on line 7 of each including one.
    it "does not pair an including file with the other file's line number" do
      get repository_path(shared_group_run, repeated_description: looped)

      expect(panel).to have_no_text("#{order_spec}:7")
      expect(panel).to have_no_text("#{refund_spec}:7")
    end

    it "says what the two columns are, so the shared-group reading is available" do
      get repository_path(shared_group_run, repeated_description: looped)

      expect(basis_line).to have_text("Each row names both the file that RAN it and the file and " \
                                      "line where it is DEFINED", normalize_ws: true)
    end
  end

  # The hazard `scope :timed` answers by EXCLUSION everywhere else on this page, answered here by
  # ORDERING instead — because a group's untimed examples are that group's population, and on this
  # panel an untimed member is often the row the reader came to find: a test that never ran is one
  # way three examples come to say the same thing.
  describe "a description mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: looped, duration: 2.0, line_number: 1),
                          example_spec(name: looped, duration: nil, line_number: 2),
                          example_spec(name: looped, duration: 5.0, line_number: 3)])
      repository
    end

    # `duration_seconds DESC` alone is NULLS FIRST in Postgres — the example that reported nothing at
    # the head of a list captioned "slowest first".
    it "sorts the untimed example to the end rather than to the head" do
      get repository_path(mixed_run, repeated_description: looped)

      expect(rows.map { |row| row[:duration] }).to eq(["5.00s", "2.00s", "not reported"])
    end

    # Never "0.00s": that is this surface inventing the measurement it is missing, and it is the
    # whole reason an untimed row is allowed in this list at all.
    it "says an untimed example reported nothing rather than that it took no time" do
      get repository_path(mixed_run, repeated_description: looped)

      expect(panel).to have_no_text("0.00s")
    end

    it "states what the durations cover and where the untimed rows are" do
      get repository_path(mixed_run, repeated_description: looped)

      expect(basis_line).to have_text("Durations here cover 2 of 3", normalize_ws: true)
      expect(basis_line).to have_text("The other 1 reported none and sit at the END of the list",
                                      normalize_ws: true)
    end
  end

  # A group the run timed NOTHING in is an ORDINARY state here rather than an edge of one: the
  # ranking above sorts exactly such groups to the end of itself and says so, so the reader who
  # opened one arrives at a list nothing ranked.
  describe "a description none of whose examples were timed" do
    def untimed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: looped, duration: nil, line_number: 1),
                          example_spec(name: looped, duration: nil, line_number: 2)])
      repository
    end

    it "lists the examples and promises no order it cannot deliver" do
      get repository_path(untimed_run, repeated_description: looped)

      expect(rows.size).to eq(2)
      expect(basis_line).to have_text("All 2 examples this run recorded under it, in the order this " \
                                      "run recorded them — nothing here was timed, so there is no " \
                                      "order to rank them in", normalize_ws: true)
      expect(basis_line).to have_no_text("slowest first")
    end

    # `id` ascending, so a group where every row ties has one stable order rather than one the
    # planner picks afresh per request.
    it "orders an all-untimed group stably" do
      repository = untimed_run

      2.times do
        get repository_path(repository, repeated_description: looped)

        expect(rows.map { |row| row[:defined_at] }).to eq(["#{order_spec}:1", "#{order_spec}:2"])
      end
    end
  end

  # A description this run recorded nothing under is an ordinary answer and not a 404:
  # `?repeated_description=` is a URL a reader types, edits and bookmarks, so a test renamed since, a
  # description reworded and a typo all arrive here.
  describe "a description this run recorded nothing under" do
    it "renders an empty state naming it rather than a 404" do
      get repository_path(two_group_run, repeated_description: "a sentence nobody wrote")

      expect(response).to have_http_status(:ok)
      expect(panel).to have_text("No examples under this description", normalize_ws: true)
      expect(panel).to have_text("a sentence nobody wrote", normalize_ws: true)
    end

    it "points at the panel that lists what the run DID record twice" do
      get repository_path(two_group_run, repeated_description: "a sentence nobody wrote")

      expect(panel).to have_text("Descriptions this run recorded more than once", normalize_ws: true)
    end

    # A repository whose latest run wrote no per-example rows at all has no ranking to open, so there
    # is nothing for this panel to be a rung below.
    it "renders no panel on a repository with no run" do
      get repository_path(create_repository(user: @user), repeated_description: looped)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # The ranking was taken from `@latest_test_run`, so the drill-down must be too — anything else
  # answers about rows the reader did not click. `?branch=` follows the "Suite growth" panel alone.
  describe "which run the examples come from" do
    it "answers about the latest run even when a branch was asked for" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: looped, duration: 3.0, line_number: 1),
                          example_spec(name: looped, duration: 3.0, line_number: 2)],
             branch: "feature", commit_sha: "feedfacecafe0001")
      ingest(repository, [example_spec(name: looped, duration: 7.0, line_number: 1),
                          example_spec(name: looped, duration: 7.0, line_number: 2)],
             branch: "main", commit_sha: "feedfacecafe0002")

      get repository_path(repository, repeated_description: looped, branch: "feature")

      expect(rows.map { |row| row[:duration] }).to eq(["7.00s", "7.00s"])
    end
  end

  # The claim boundary the panel above holds, inherited whole. A shared description is equally a
  # table-driven loop, a shared example group, or the same test written twice, and these rows decide
  # none of it — so the word that would decide it appears nowhere.
  describe "what the panel refuses to say" do
    it "never calls a repetition a duplicate" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(panel).to have_no_text(/duplicat/i)
    end

    it "never calls a repetition redundant" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(panel).to have_no_text(/redundan/i)
    end
  end

  # The three shapes a query string can legally parse into that are not a String. This parameter
  # reaches `where(name: …)` on a plain text column, where an Array does not raise at all — it
  # becomes an `IN` list and lists the examples of several descriptions under a caption naming one. A
  # silent wrong answer needs the guard more than a crash does.
  describe "a repeated-description parameter that is not a description" do
    def expect_repeated_description_param_treated_as_no_ask(query)
      get repository_path(two_group_run, **query)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end

    it_behaves_like "a surface that treats a malformed repeated-description parameter as no ask"

    # The positive path, beside the group it makes falsifiable: a guard that swallowed every value
    # would answer 200 on all three shapes above and render no panel here either.
    it "honours a repeated-description parameter that IS a description" do
      get repository_path(two_group_run, repeated_description: looped)

      expect(panel?).to be(true)
      expect(rows.size).to eq(3)
    end

    # A blank ask is no ask. `name` is NULLABLE here — which is why the ranking excludes unnamed rows
    # in SQL — so without `.presence` an empty ask becomes `WHERE name = ''`, a query for a
    # description no row can carry and therefore a panel guaranteed to be empty. That is a worse
    # answer than not opening one.
    it "treats a blank repeated-description parameter as no ask" do
      get repository_path(two_group_run, repeated_description: "")

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # One narrowed read, bounded by the size of one RUN and not of the suite — and none at all on a
  # page nobody asked a description of. A `select` over the run's rows filtered in Ruby is exactly the
  # shape that ships green on a three-row fixture and takes the page down on a real suite.
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

    def repository_with(example_count, name:)
      repository = create_repository(user: @user, github_full_name: name)
      ingest(repository, (1..example_count).map do |i|
        example_spec(name: looped, duration: i.to_f, line_number: i)
      end)
      repository
    end

    it "costs the same number of queries on a 200-example group as on a 3-example one" do
      small = repository_with(3, name: "acme/small-suite")
      large = repository_with(200, name: "acme/large-suite")

      small_queries = queries_against("spec_observations") do
        get repository_path(small, repeated_description: looped)
      end
      large_queries = queries_against("spec_observations") do
        get repository_path(large, repeated_description: looped)
      end

      # The large page renders a full list of the cap, and costs what the three-example page cost.
      expect(rows.size).to eq(SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      # An absolute ceiling too: equality alone would still hold if both pages regressed to a
      # fixed-but-wasteful number of passes over the same table. EIGHT reads serve this page with a
      # description open — the seven the page already took (the ranking and its coverage aggregate
      # for "Slowest tests", one grouped aggregate each for the by-file and by-directory rollups,
      # the cross-run panel's gating probe, and the two the repeated-description RANKING takes: the
      # grouped read and, separately because the grouping excludes them in its WHERE clause, the
      # count of rows carrying no description) and ONE for this panel. The list and both figures in
      # its caption come back on that one read: the counts are windows on it rather than a second
      # aggregate.
      expect(large_queries.size).to eq(8)
    end

    # The whole drill-down is off the default page's budget. A reader who never opens a description
    # pays exactly what they paid before this panel existed.
    it "asks nothing of the table when no description was asked for" do
      repository = repository_with(200, name: "acme/unopened-suite")

      opened = queries_against("spec_observations") do
        get repository_path(repository, repeated_description: looped)
      end
      unopened = queries_against("spec_observations") { get repository_path(repository) }

      expect(unopened.size).to eq(opened.size - 1)
      expect(unopened.size).to eq(7)
    end
  end
end
