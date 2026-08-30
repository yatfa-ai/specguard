# frozen_string_literal: true

require "rails_helper"

# The "Descriptions this run recorded more than once" panel on repositories#show — which
# DESCRIPTIONS more than one example of ONE run carried, ranked by the wall clock those examples
# cost between them.
#
# Its own file, for the reason every sibling panel spec states for itself: every example here needs
# the same per-example fixture, and the Overview/API-keys file is edited by sibling slices.
#
# The grain is unlike every panel above it. Those roll one run's rows up by where the code LIVES —
# the example, its file, its area — and none of them can see that two of those rows say the same
# thing. `GROUP BY name` exists twice in the whole application and both are narrowed to failures, so
# on a green suite nothing had ever grouped examples by what they claim to test. That is what this
# panel is, and it is why none of its assertions can be satisfied by a rollup of the panels above.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand: an untimed example is `result&.run_time` coming back nil on a real client, an
# unnamed one is `presence_of(spec["name"])` coming back nil on a producer that sends no
# description, and two examples sharing a description in one run is a shape the RECORDER produces
# from a table-driven loop. A hand-built fixture would assert against a shape nothing in production
# writes.
RSpec.describe "Repository repeated descriptions", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#repeated-descriptions")

  def panel? = Capybara.string(response.body).has_css?("#repeated-descriptions")

  # ELEMENT-scoped, never panel-scoped: the basis paragraph has several states that share most of
  # their words, so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted.
  def basis_line = panel.find("#repeated-descriptions-basis")

  # One row as a reader meets it: the description and the files it ran in, how many examples share
  # it, what the total was summed over, and the total.
  def rows
    panel.all("tbody tr").map do |row|
      description, examples, coverage, duration = row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { description: description, examples: examples, coverage: coverage, duration: duration }
    end
  end

  # The description alone, without the file line rendered under it.
  def row_names
    panel.all("tbody tr").map { |row| row.first("td").text.gsub(/\s+/, " ").strip.split(" in spec/").first }
  end

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` and `name:` are passed at every call site, nils included —
  # an untimed example and an unnamed one are both states this file turns on, and the shared builder
  # substitutes a default for a nil `name:`, so it is merged in rather than passed through.
  def example_spec(name:, duration:, line_number:, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  # A repository whose latest run recorded the given `[name, duration]` pairs, one example each.
  def repository_with(pairs, **attrs)
    repository = create_repository(user: @user, **attrs)
    specs = pairs.each_with_index.map do |(name, duration), index|
      example_spec(name: name, duration: duration, line_number: index + 1)
    end
    ingest(repository, specs)
    repository
  end

  describe "a run that recorded the same description more than once" do
    # Built so the ranking by COST and a ranking by group SIZE disagree, which is the whole reason
    # this panel is ordered the way it is: three examples costing 90 seconds outrank eight costing
    # two. A third description is carried by a single example, so `HAVING COUNT(*) > 1` has
    # something real to exclude.
    def mixed_run
      repository_with([["a slow case in a loop", 30.0], ["a slow case in a loop", 30.0],
                       ["a slow case in a loop", 30.0]] +
                      Array.new(8) { ["a fast case in a loop", 0.25] } +
                      [["a test nobody wrote twice", 5.0]])
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "list repeated only", "behavior": "only the two descriptions carried by more than one example of the run appear, and the single-example description is excluded", "layer": "request"}
    it "lists only the descriptions more than one example of the run recorded" do
      get repository_path(mixed_run)

      expect(row_names).to eq(["a slow case in a loop", "a fast case in a loop"])
    end

    # THE assertion that fails if this were ranked by how many examples share the description — the
    # eight-example group would head the list. Item 5 of the roadmap is redundancy weighed against
    # duration, and the ordering is where that is decided.
    # @intent: {"entity": "GET /repositories/:id", "action": "rank by cost", "behavior": "the three-example group totalling 1m 30s outranks the eight-example group at 2.00s, so the ordering follows summed duration and not group size", "layer": "request"}
    it "ranks the groups by what they cost rather than by how many examples share the name" do
      get repository_path(mixed_run)

      expect(rows.map { |row| row[:duration] }).to eq(["1m 30s", "2.00s"])
      expect(rows.map { |row| row[:examples] }).to eq(["3", "8"])
    end

    # Every figure on the row, checked against direct SQL of the same grouping rather than against
    # the fixture's arithmetic — a panel that lost or double-counted a group's rows is still a
    # plausible-looking table, and only the database's own answer catches it.
    # @intent: {"entity": "GET /repositories/:id", "action": "match direct sql", "behavior": "the rendered example counts and description names equal a direct SpecObservation group-by-name having count greater than one over the same run", "layer": "request"}
    it "matches direct SQL of the same query, figure for figure" do
      repository = mixed_run
      get repository_path(repository)

      run = repository.latest_test_run
      expected = SpecObservation.where(test_run_id: run.id).group(:name)
                                .having("COUNT(*) > 1").count
                                .sort_by { |name, _count| name }

      expect(rows.map { |row| row[:examples].to_i }.sort)
        .to eq(expected.map { |_name, count| count }.sort)
      expect(row_names.sort).to eq(expected.map(&:first))
    end

    # The files are what let a reader go and look. Named rather than counted, because "spans 2
    # files" sends them looking without saying where.
    # @intent: {"entity": "GET /repositories/:id", "action": "name group files", "behavior": "the row reads in spec/models/invoice_spec.rb and spec/models/ledger_spec.rb, naming both files the group's examples ran in", "layer": "request"}
    it "names the spec files the group's examples ran in" do
      repository = repository_with([["shared by two files", 1.0], ["shared by two files", 1.0]])
      SpecObservation.where(test_run_id: repository.latest_test_run.id).order(:line_number).last
                     .update!(spec_file_path: "spec/models/ledger_spec.rb")

      get repository_path(repository)

      expect(panel.find("tbody tr").text)
        .to include("in spec/models/invoice_spec.rb and spec/models/ledger_spec.rb")
    end

    # The claim boundary, and the reason this panel is allowed to exist at all. A shared description
    # is equally a table-driven loop, a shared example group, or the same test written twice, and
    # nothing in these rows decides which — so the panel presents and does not judge, exactly as the
    # outcome column echoes rather than rewords.
    # @intent: {"entity": "GET /repositories/:id", "action": "present without verdict", "behavior": "the basis line says presented for review and not as a finding of duplication, offers the loop-or-shared-group explanation, and the word duplicate appears nowhere", "layer": "request"}
    it "presents the groups for review rather than as a finding of duplication" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("Presented for review and not as a finding of duplication",
                                      normalize_ws: true)
      expect(basis_line).to have_text("a table-driven loop or a shared example group put them there",
                                      normalize_ws: true)
      expect(panel).to have_no_text("duplicate", normalize_ws: true)
    end

    # Bounded by `SpecObservation::REPEATED_DESCRIPTIONS_LIMIT` — its own constant, not a neighbour's:
    # the population it ranks is neither the run's files nor its examples.
    # @intent: {"entity": "GET /repositories/:id", "action": "cap at costliest ten", "behavior": "a 25-group run lists exactly REPEATED_DESCRIPTIONS_LIMIT rows, from group 25 at the head down to group 16", "layer": "request"}
    it "lists no more than the costliest ten, however many the run repeated" do
      pairs = (1..25).flat_map { |i| [["group #{format('%02d', i)}", i.to_f]] * 2 }

      get repository_path(repository_with(pairs))

      expect(rows.size).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
      expect(row_names.first).to eq("group 25")
      expect(row_names.last).to eq("group 16")
    end

    # A capped list that does not disclose its cap is read as the whole story. `rows.size` cannot
    # say what the list is the head OF, because it is the truncated figure.
    # @intent: {"entity": "GET /repositories/:id", "action": "disclose repeated count", "behavior": "the basis line reads The 10 costliest of the 25 descriptions, so a capped list cannot read as the whole story", "layer": "request"}
    it "says how many descriptions the run repeated, not just how many it lists" do
      pairs = (1..25).flat_map { |i| [["group #{format('%02d', i)}", i.to_f]] * 2 }

      get repository_path(repository_with(pairs))

      expect(basis_line).to have_text("The 10 costliest of the 25 descriptions", normalize_ws: true)
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "state completeness", "behavior": "with only two repeated descriptions the basis reads All 2 descriptions this run recorded under more than one example", "layer": "request"}
    it "says the list is complete when nothing was cut" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("All 2 descriptions this run recorded under more than one example",
                                      normalize_ws: true)
    end
  end

  describe "what the totals were measured over" do
    # @intent: {"entity": "GET /repositories/:id", "action": "state full coverage", "behavior": "the row's coverage cell reads 2 of 2 and the caption adds that every example under every description listed reported a duration", "layer": "request"}
    it "says every listed total covers the whole of its group, where every example was timed" do
      get repository_path(repository_with([["twice over", 1.0], ["twice over", 2.0]]))

      expect(rows.map { |row| row[:coverage] }).to eq(["2 of 2"])
      expect(basis_line).to have_text("Every example under every description listed reported a duration",
                                      normalize_ws: true)
    end

    # `SUM` skips NULLs silently, so a half-measured group is indistinguishable as a number from a
    # complete one. The per-row fraction is the answer, and the caption is what tells a reader the
    # column is a denominator rather than decoration.
    # @intent: {"entity": "GET /repositories/:id", "action": "state partial coverage", "behavior": "the two rows read 2 of 3 and 1 of 2 while the caption totals 3 of 5 examples reporting a duration across every repeated description", "layer": "request"}
    it "states the coverage of each group and of the repeated population as a whole" do
      repository = repository_with([["partly timed", 4.0], ["partly timed", nil], ["partly timed", 2.0],
                                    ["also partly timed", 1.0], ["also partly timed", nil]])

      get repository_path(repository)

      expect(rows.map { |row| row[:coverage] }).to eq(["2 of 3", "1 of 2"])
      expect(basis_line).to have_text("Across every repeated description this run holds, 3 of 5 " \
                                      "examples reported one", normalize_ws: true)
    end

    # `SUM(...) DESC` is NULLS FIRST in Postgres, so the naive ordering would name the group nobody
    # measured the most expensive repetition on the page. And an unmeasured total says so in words
    # rather than wearing the spelling of a zero.
    # @intent: {"entity": "GET /repositories/:id", "action": "sort untimed last", "behavior": "the group nothing timed sorts beneath the timed one and its duration cell reads not reported, never a zero", "layer": "request"}
    it "sorts a group nothing timed to the end and refuses to print it as a zero" do
      repository = repository_with([["never timed", nil], ["never timed", nil],
                                    ["timed", 0.5], ["timed", 0.5]])

      get repository_path(repository)

      expect(row_names).to eq(["timed", "never timed"])
      expect(rows.last[:duration]).to eq("not reported")
    end
  end

  describe "rows that carried no description" do
    # A null name cannot be grouped: pooling every unnamed example would invent the largest
    # repetition on the page out of rows that share nothing. Excluded, and the exclusion stated.
    def partly_unnamed_run
      repository_with([["a real repetition", 1.0], ["a real repetition", 1.0],
                       [nil, 9.0], [nil, 9.0], [nil, 9.0]])
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "exclude unnamed rows", "behavior": "only the named repetition is listed and the basis states that 3 of the 5 examples this run recorded carried no description", "layer": "request"}
    it "excludes them from the grouping and says how many rows it excluded" do
      get repository_path(partly_unnamed_run)

      expect(row_names).to eq(["a real repetition"])
      expect(basis_line).to have_text("3 of the 5 examples this run recorded carried no description",
                                      normalize_ws: true)
    end

    # Rendered only when there are any: "0 examples carried no description" is a sentence about
    # arithmetic rather than about this run.
    # @intent: {"entity": "GET /repositories/:id", "action": "stay silent when named", "behavior": "where every row carried a description the basis carries no carried-no-description sentence", "layer": "request"}
    it "says nothing about unnamed rows when every row carried a description" do
      get repository_path(repository_with([["named", 1.0], ["named", 1.0]]))

      expect(basis_line).to have_no_text("carried no description")
    end

    # The Vacuous Green gate. A producer that sends no descriptions at all stores a nil on every row,
    # and such a run produces exactly the empty ranking a suite of entirely unique descriptions does
    # — "no repetition" would be "nobody told us" wearing the spelling of "there is no redundancy".
    # @intent: {"entity": "GET /repositories/:id", "action": "refuse vacuous green", "behavior": "an all-unnamed run renders the unnamed section saying This run reported no test descriptions and that all 3 examples arrived without one, with no table rows", "layer": "request"}
    it "refuses to call a run with no descriptions at all a run with no repetition" do
      get repository_path(repository_with([[nil, 1.0], [nil, 2.0], [nil, 3.0]]))

      expect(panel).to have_css("#repeated-descriptions-unnamed")
      expect(panel).to have_text("This run reported no test descriptions", normalize_ws: true)
      expect(panel).to have_text("All 3 examples this run recorded arrived without a description",
                                 normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end
  end

  describe "a run with nothing to report" do
    # The honest zero, and it is only reachable behind a run that DID describe its examples.
    # @intent: {"entity": "GET /repositories/:id", "action": "state honest zero", "behavior": "three unique descriptions render the none section reading No description was recorded twice in this run, with the every-example-unique basis beside it", "layer": "request"}
    it "says no description was recorded twice, where every description is unique" do
      get repository_path(repository_with([["one", 1.0], ["two", 2.0], ["three", 3.0]]))

      expect(panel).to have_css("#repeated-descriptions-none")
      expect(panel).to have_text("No description was recorded twice in this run", normalize_ws: true)
      expect(basis_line).to have_text("Every one of the 3 examples this run described carries a " \
                                      "description no other example of the run carries",
                                      normalize_ws: true)
    end

    # Repetition exists and not one of its examples was timed. There is a list and no ranking, and a
    # column of "not reported" under a heading promising "costliest first" would be a ranking of
    # nothing. Stated in descriptions counted before the cap, never by summing the rows on hand.
    # @intent: {"entity": "GET /repositories/:id", "action": "decline to rank untimed", "behavior": "a repeated description with no timed examples renders the untimed section naming the 1 description under more than one example, with no table rows", "layer": "request"}
    it "declines to rank the repetitions where the run timed none of them" do
      get repository_path(repository_with([["untimed twice", nil], ["untimed twice", nil]]))

      expect(panel).to have_css("#repeated-descriptions-untimed")
      expect(panel).to have_text("This run recorded 1 description under more than one example",
                                 normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    # The other half of that state, and the half a `have_no_css("tbody tr")` cannot see: the basis
    # paragraph is a claim ABOUT the ranking — it says "costliest first" and names an "Examples
    # timed" column as the denominator of every total — so on the run that produces neither it must
    # be ABSENT rather than reworded. A paragraph describing a table that is not on the page is the
    # one failure this panel's empty state exists to prevent, and it is invisible to any assertion
    # made on the table alone.
    # @intent: {"entity": "GET /repositories/:id", "action": "make no ranking claim", "behavior": "the untimed state renders no basis paragraph at all, so neither costliest first nor the Examples-timed column appears", "layer": "request"}
    it "makes no claim about a ranking where there is nothing ranked" do
      get repository_path(repository_with([["untimed twice", nil], ["untimed twice", nil]]))

      expect(panel).to have_no_css("#repeated-descriptions-basis")
      expect(panel).to have_no_text("costliest first", normalize_ws: true)
      expect(panel).to have_no_text("Examples timed", normalize_ws: true)
    end

    # The state where the two silences MEET, and the one no example reached before: repetition the
    # run never timed, alongside rows it never described. The example above pins that the ranking
    # paragraph is ABSENT here — and that paragraph used to be this state's only account of the
    # excluded rows, so removing it took the account with it and no assertion noticed. Without this
    # example the disclosure can disappear from this state again under a green suite, which is
    # exactly what happened once.
    #
    # The panel's whole account of this run is built on 2 of its 5 rows. Saying so is the ticket's
    # honesty constraint and the rule `RepeatedDescriptions`' class comment states, and it is true of
    # this state no less than of the states that render a table. Asserted element-scoped on the id
    # this state owns, per the header rule — and paired with the absence of the ranking paragraph, so
    # a fix that restored the disclosure by restoring the false claims with it fails here.
    # @intent: {"entity": "GET /repositories/:id", "action": "account for unnamed rows", "behavior": "the untimed section's own basis says 3 of the 5 examples carried no description at all while the ranking paragraph and its claims stay absent", "layer": "request"}
    it "still answers for the rows carrying no description where it timed nothing it grouped" do
      get repository_path(repository_with([["untimed twice", nil], ["untimed twice", nil],
                                           [nil, nil], [nil, nil], [nil, nil]]))

      expect(panel).to have_css("#repeated-descriptions-untimed")
      expect(panel).to have_no_css("#repeated-descriptions-basis")
      expect(panel.find("#repeated-descriptions-untimed-basis"))
        .to have_text("3 of the 5 examples this run recorded carried no description at all",
                      normalize_ws: true)
      expect(panel).to have_no_text("costliest first", normalize_ws: true)
      expect(panel).to have_no_text("Examples timed", normalize_ws: true)
    end

    # Under the same condition the basis paragraph's clause is rendered under: "0 examples carried no
    # description" is a sentence about arithmetic rather than about this run.
    # @intent: {"entity": "GET /repositories/:id", "action": "stay silent when named", "behavior": "the untimed state over an all-named run renders no untimed-basis element and no carried-no-description wording", "layer": "request"}
    it "says nothing about unnamed rows in that state when every row carried a description" do
      get repository_path(repository_with([["untimed twice", nil], ["untimed twice", nil]]))

      expect(panel).to have_css("#repeated-descriptions-untimed")
      expect(panel).to have_no_css("#repeated-descriptions-untimed-basis")
      expect(panel).to have_no_text("carried no description", normalize_ws: true)
    end

    # The discrimination that keeps the fix above from being a blanket "no timings, no paragraph".
    # A run whose every description is unique timed nothing repeated either, and its paragraph
    # promises no ranking — it states the honest zero's own denominator and is the only place the
    # rows that carry no description are answered for. Deleting the `any?` half of the view's
    # condition passes every assertion above and fails this one.
    # @intent: {"entity": "GET /repositories/:id", "action": "keep zero paragraph", "behavior": "a unique-description run that timed nothing renders the none section rather than the untimed one, and keeps its every-example-unique basis", "layer": "request"}
    it "keeps the honest zero's paragraph on a unique-description run that timed nothing" do
      get repository_path(repository_with([["one", nil], ["two", nil]]))

      expect(panel).to have_css("#repeated-descriptions-none")
      expect(panel).to have_no_css("#repeated-descriptions-untimed")
      expect(basis_line).to have_text("Every one of the 2 examples this run described carries a " \
                                      "description no other example of the run carries",
                                      normalize_ws: true)
    end

    # No per-example rows at all — a run ingested before those rows existed, or a client that sends
    # no per-example detail. There is no description grain to discuss and the panel does not appear
    # to discuss it, which is the line every single-run panel on this page draws with `recorded?`.
    # @intent: {"entity": "GET /repositories/:id", "action": "omit without rows", "behavior": "a run recorded with an empty specs array renders no repeated-descriptions panel", "layer": "request"}
    it "does not render at all for a run that wrote no per-example rows" do
      repository = create_repository(user: @user)
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0009", branch: "main", total_specs_count: 5,
          annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: []
      )

      get repository_path(repository)

      expect(panel?).to be(false)
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "omit without runs", "behavior": "a repository with no runs at all renders no repeated-descriptions panel", "layer": "request"}
    it "does not render at all for a repository with no runs" do
      get repository_path(create_repository(user: @user))

      expect(panel?).to be(false)
    end
  end

  describe "which run it reads" do
    # Anchored on the LATEST run, exactly as every panel above it is, and specifically not on
    # `?branch=` — that ask re-anchors the "Suite growth" chart alone, and a reader who opened a
    # branch's trajectory did not ask this panel to describe a different run.
    # @intent: {"entity": "GET /repositories/:id", "action": "ignore branch ask", "behavior": "with feature and main runs ingested, asking branch=feature/x still lists the main run's on-main description", "layer": "request"}
    it "reads the latest run and does not follow the branch ask" do
      repository = create_repository(user: @user)
      ingest(repository,
             [example_spec(name: "on the feature branch", duration: 9.0, line_number: 1),
              example_spec(name: "on the feature branch", duration: 9.0, line_number: 2)],
             commit_sha: "feedfacecafe0010", branch: "feature/x")
      ingest(repository,
             [example_spec(name: "on main", duration: 1.0, line_number: 1),
              example_spec(name: "on main", duration: 1.0, line_number: 2)],
             commit_sha: "feedfacecafe0011", branch: "main")

      get repository_path(repository, branch: "feature/x")

      expect(row_names).to eq(["on main"])
    end
  end

  describe "what the panel costs the page" do
    # `queries_against` comes from spec/support/query_capture.rb.

    # An EQUALITY across two suite sizes, which is the guard an absolute count cannot give: the
    # failure this panel could plausibly acquire is a per-group follow-up — one trip to fetch the
    # files of each listed description, or to count each group's timed rows — and that is a read
    # count that GROWS with the number of groups while staying constant against any fixed baseline.
    #
    # TWO reads, and the second is not slack. The ranking excludes null names in its WHERE clause,
    # so no window over it could ever have counted the rows it dropped; the caption's exclusion
    # figure and its Vacuous Green gate therefore need a second aggregate, which
    # `SpecObservation.description_presence_in` is. Both are single grouped passes over one run's
    # rows.
    # @intent: {"entity": "GET /repositories/:id", "action": "cost two reads", "behavior": "a 400-example run costs the same spec_observations read count as a 4-example one, of which exactly one statement carries both GROUP BY and HAVING", "layer": "request"}
    it "costs the same two reads at 400 examples as at 4" do
      small = repository_with([["s", 1.0], ["s", 1.0], ["t", 1.0], ["t", 1.0]],
                              github_full_name: "acme/small-suite")
      large = repository_with((1..200).flat_map { |i| [["large #{i}", i / 10.0]] * 2 },
                              github_full_name: "acme/large-suite")
      get repository_path(small)

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      expect(large_queries.size).to eq(small_queries.size)
      expect(
        large_queries.count { |sql| sql.include?("GROUP BY") && sql.include?("HAVING") }
      ).to eq(1)
    end
  end
end
