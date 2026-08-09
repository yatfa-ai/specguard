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

    it "lists only the descriptions more than one example of the run recorded" do
      get repository_path(mixed_run)

      expect(row_names).to eq(["a slow case in a loop", "a fast case in a loop"])
    end

    # THE assertion that fails if this were ranked by how many examples share the description — the
    # eight-example group would head the list. Item 5 of the roadmap is redundancy weighed against
    # duration, and the ordering is where that is decided.
    it "ranks the groups by what they cost rather than by how many examples share the name" do
      get repository_path(mixed_run)

      expect(rows.map { |row| row[:duration] }).to eq(["1m 30s", "2.00s"])
      expect(rows.map { |row| row[:examples] }).to eq(["3", "8"])
    end

    # Every figure on the row, checked against direct SQL of the same grouping rather than against
    # the fixture's arithmetic — a panel that lost or double-counted a group's rows is still a
    # plausible-looking table, and only the database's own answer catches it.
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
    it "lists no more than the costliest ten, however many the run repeated" do
      pairs = (1..25).flat_map { |i| [["group #{format('%02d', i)}", i.to_f]] * 2 }

      get repository_path(repository_with(pairs))

      expect(rows.size).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
      expect(row_names.first).to eq("group 25")
      expect(row_names.last).to eq("group 16")
    end

    # A capped list that does not disclose its cap is read as the whole story. `rows.size` cannot
    # say what the list is the head OF, because it is the truncated figure.
    it "says how many descriptions the run repeated, not just how many it lists" do
      pairs = (1..25).flat_map { |i| [["group #{format('%02d', i)}", i.to_f]] * 2 }

      get repository_path(repository_with(pairs))

      expect(basis_line).to have_text("The 10 costliest of the 25 descriptions", normalize_ws: true)
    end

    it "says the list is complete when nothing was cut" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("All 2 descriptions this run recorded under more than one example",
                                      normalize_ws: true)
    end
  end

  describe "what the totals were measured over" do
    it "says every listed total covers the whole of its group, where every example was timed" do
      get repository_path(repository_with([["twice over", 1.0], ["twice over", 2.0]]))

      expect(rows.map { |row| row[:coverage] }).to eq(["2 of 2"])
      expect(basis_line).to have_text("Every example under every description listed reported a duration",
                                      normalize_ws: true)
    end

    # `SUM` skips NULLs silently, so a half-measured group is indistinguishable as a number from a
    # complete one. The per-row fraction is the answer, and the caption is what tells a reader the
    # column is a denominator rather than decoration.
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

    it "excludes them from the grouping and says how many rows it excluded" do
      get repository_path(partly_unnamed_run)

      expect(row_names).to eq(["a real repetition"])
      expect(basis_line).to have_text("3 of the 5 examples this run recorded carried no description",
                                      normalize_ws: true)
    end

    # Rendered only when there are any: "0 examples carried no description" is a sentence about
    # arithmetic rather than about this run.
    it "says nothing about unnamed rows when every row carried a description" do
      get repository_path(repository_with([["named", 1.0], ["named", 1.0]]))

      expect(basis_line).to have_no_text("carried no description")
    end

    # The Vacuous Green gate. A producer that sends no descriptions at all stores a nil on every row,
    # and such a run produces exactly the empty ranking a suite of entirely unique descriptions does
    # — "no repetition" would be "nobody told us" wearing the spelling of "there is no redundancy".
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
    it "declines to rank the repetitions where the run timed none of them" do
      get repository_path(repository_with([["untimed twice", nil], ["untimed twice", nil]]))

      expect(panel).to have_css("#repeated-descriptions-untimed")
      expect(panel).to have_text("This run recorded 1 description under more than one example",
                                 normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    # No per-example rows at all — a run ingested before those rows existed, or a client that sends
    # no per-example detail. There is no description grain to discuss and the panel does not appear
    # to discuss it, which is the line every single-run panel on this page draws with `recorded?`.
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

    it "does not render at all for a repository with no runs" do
      get repository_path(create_repository(user: @user))

      expect(panel?).to be(false)
    end
  end

  describe "which run it reads" do
    # Anchored on the LATEST run, exactly as every panel above it is, and specifically not on
    # `?branch=` — that ask re-anchors the "Suite growth" chart alone, and a reader who opened a
    # branch's trajectory did not ask this panel to describe a different run.
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
    def queries_against(table)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].to_s.include?(table)
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

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
