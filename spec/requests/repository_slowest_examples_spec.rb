# frozen_string_literal: true

require "rails_helper"

# The "Slowest tests" panel on repositories#show — the first surface SpecGuard renders off
# `spec_observations`, and the first answer this product has ever given about a single TEST rather
# than about a shard, a run or a suite.
#
# Its own file, for the reason spec/requests/repository_suite_trajectory_spec.rb states for itself:
# the Overview/API-keys file is edited by sibling slices, and every example here needs the same
# per-example fixture.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand, with the string-keyed hashes `Ingest::Payload` hands it. The two states this
# panel turns on — a timed example and an untimed one — are states the RECORDER produces from what
# a real client sends (`result&.run_time` is nil for an example that never ran), and a hand-built
# fixture would be asserting against a shape nothing in production writes.
RSpec.describe "Repository slowest tests", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#slowest-examples")

  def panel?
    Capybara.string(response.body).has_css?("#slowest-examples")
  end

  # ELEMENT-scoped, never panel-scoped: the coverage sentence has three states that share most of
  # their words, so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted.
  def basis_line = panel.find("#slowest-examples-basis")

  # One row as a reader meets it: the label, the location line under it (absent for a row whose
  # label already IS its location), and the duration. Whitespace-collapsed, because a label and a
  # location assembled across two ERB tags are two readings on the page whatever the source did
  # with indentation.
  def rows
    panel.all("tbody tr").map do |row|
      label_cell, duration_cell = row.all("td")
      location = label_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }.first
      label = label_cell.text.gsub(/\s+/, " ").strip
      label = label.delete_suffix(location).strip if location

      { label: label, location: location, duration: duration_cell.text.strip }
    end
  end

  def row_labels = rows.map { |row| row[:label] }

  # One ingested run, through the producer. `specs` are the wire hashes a client POSTs; the
  # recorder reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire. `duration:` and `name:` are passed at every call site, nils included —
  # an untimed and an unnamed example are both states this file turns on, and the shared builder
  # substitutes a default for a nil `name:`, so the value is merged in rather than passed through.
  def example_spec(name:, duration:, line_number:, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  describe "a run whose examples were timed" do
    it "ranks them slowest first, with the duration each one took" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Invoice finalize locks the line items",
                                       duration: 0.42, line_number: 1),
                          example_spec(name: "Ledger rebuild walks every entry",
                                       duration: 9.5, line_number: 2),
                          example_spec(name: "User signs in", duration: 3.0, line_number: 3)])

      get repository_path(repository)

      expect(row_labels).to eq(["Ledger rebuild walks every entry",
                                "User signs in",
                                "Invoice finalize locks the line items"])
      expect(rows.map { |row| row[:duration] }).to eq(["9.50s", "3.00s", "0.42s"])
      # Every named row also says where to go and look, at the coordinate the line number belongs to.
      expect(rows.map { |row| row[:location] }).to eq(["spec/models/invoice_spec.rb:2",
                                                       "spec/models/invoice_spec.rb:3",
                                                       "spec/models/invoice_spec.rb:1"])
    end

    # Bounded by `SpecObservation::SLOWEST_LIMIT`: this is a list of the worst offenders, not a
    # rendering of the suite.
    it "lists no more than the ten slowest, however many the run recorded" do
      repository = create_repository(user: @user)
      specs = (1..40).map { |i| example_spec(name: "example #{i}", duration: i.to_f, line_number: i) }
      ingest(repository, specs)

      get repository_path(repository)

      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(row_labels.first).to eq("example 40")
      expect(row_labels.last).to eq("example 31")
    end

    # `name` is nullable — the client sends `nil` for an example it could not describe, and
    # `Ingest::ObservationRecorder` stores that faithfully. A blank cell here is a row the reader
    # can neither identify nor go and find.
    it "falls back to the example's file and line where the client sent no name" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: nil, duration: 4.0, line_number: 88,
                                       file_path: "spec/models/ledger_spec.rb")])

      get repository_path(repository)

      expect(row_labels).to eq(["spec/models/ledger_spec.rb:88"])
      # The fallback already IS the location, so the row is not made to wear it twice.
      expect(rows.first[:location]).to be_nil
    end

    it "says the ranking covers everything, where every recorded example reported a duration" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1),
                          example_spec(name: "two", duration: 2.0, line_number: 2)])

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of the 2 examples this run recorded reported a duration",
                                      normalize_ws: true)
    end
  end

  # THE hazard this slice exists to refuse. `duration_seconds` is nullable by design, and
  # `duration_seconds: :desc` is NULLS FIRST in Postgres — so the naive ranking does not merely
  # include the example that never ran, it names it as the slowest test in the suite.
  describe "a run mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1),
                          example_spec(name: "also never ran", duration: nil, line_number: 2),
                          example_spec(name: "slow one", duration: 8.0, line_number: 3),
                          example_spec(name: "quick one", duration: 0.25, line_number: 4)])
      repository
    end

    # Both halves are asserted because they fail differently: an ordering fixed to `NULLS LAST`
    # with no exclusion passes "not at the head" and still lists the untimed rows at the bottom of
    # a list captioned "slowest", where they read as the fastest tests in the suite.
    it "leaves the untimed examples out, and specifically not at the head of the list" do
      get repository_path(mixed_run)

      expect(row_labels.first).to eq("slow one")
      expect(row_labels).to eq(["slow one", "quick one"])
    end

    # The panel states what it ranked over, because ten rows print identically whether they are the
    # worst of everything or the worst of half of it.
    it "states its coverage against the rows it ranked, and says what it excluded" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("Ranked over the 2 of 4 examples this run recorded that reported " \
                                      "a duration; 2 reported none and stayed out of the ranking",
                                      normalize_ws: true)
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size — that
    # figure is re-derived by SUM over shard reports and the two can legitimately differ.
    it "counts the rows it ranked rather than the run's own suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1),
                          example_spec(name: "two", duration: nil, line_number: 2)],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(basis_line).to have_text("Ranked over the 1 of 2 examples", normalize_ws: true)
      expect(basis_line).to have_no_text("4,000")
    end
  end

  describe "a run that recorded examples and timed none of them" do
    it "renders an empty state rather than a list of zeroes" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1),
                          example_spec(name: "also never ran", duration: nil, line_number: 2)])

      get repository_path(repository)

      expect(panel).to have_text("No timings on this run", normalize_ws: true)
      expect(panel).to have_text("recorded 2 examples and a duration for none of them",
                                 normalize_ws: true)
      # A zero here would be the panel inventing the measurement it is missing.
      expect(panel).to have_no_css("tbody tr")
      expect(panel).to have_no_text("0.00s")
    end
  end

  # A run with no per-example rows at all — everything ingested before those rows existed, and
  # every client that sends no per-example detail. There is no per-test grain to disclose, and an
  # empty panel on every such run would read as a finding about the suite when it is a fact about
  # the payload. The Overview's never-ingested empty state is this page's one statement of absence.
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

  # The whole point of ranking in SQL against the composite index is that the page costs the same
  # on a 20,000-example suite as on a 20-example one. A `has_many` walked in the view is exactly
  # the shape that ships green on a three-row fixture and takes the page down on a real suite.
  #
  # Defined here rather than extracted, following spec/requests/repositories_spec.rb, which defines
  # its own copy per describe for the same reason: the guard is about THIS page's budget and reads
  # at the point of use.
  describe "what the panel costs" do
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

    it "costs the same number of queries at 200 examples as at 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      ingest(small, (1..3).map { |i| example_spec(name: "small #{i}", duration: i.to_f, line_number: i) })
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      ingest(large, (1..200).map { |i| example_spec(name: "large #{i}", duration: i.to_f, line_number: i) },
             commit_sha: "feedfacecafe0002")

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      # Both pages render the panel — the large one renders a full ten rows — and cost the same.
      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      # An absolute ceiling too: equality alone would still hold if both pages regressed to a
      # fixed-but-wasteful number of passes over the same table. This panel is two of these — one
      # ranking, one aggregate — and the third is the "Heaviest spec files" panel's single grouped
      # rollup, whose own budget is asserted in spec/requests/repository_spec_file_durations_spec.rb.
      # Page-wide rather than panel-scoped on purpose: what must not grow is the number of times
      # ONE page walks this table, and only a count taken across the whole request can say that.
      expect(large_queries.size).to eq(3)
    end
  end

  # The paragraph one section up on this page used to declare this question unanswerable, in a
  # comment addressed to future authors. The rows it said did not exist are what this panel reads,
  # so the claim has to go — a stale disclosure is a live instruction not to build the thing that
  # is now built. What it must NOT lose is the rule the claim was there to justify: the shard prose
  # still may not imply a per-test fact.
  describe "the shard prose the panel sits below" do
    it "no longer tells its authors the schema cannot answer which tests are slow" do
      source = Rails.root.join("app/views/repositories/show.html.erb").read

      expect(source).not_to include("stays unanswerable")
      expect(source).not_to include("Nothing in the schema records how long any single")
      # The rule the retired claim existed to justify is still stated.
      expect(source).to include("About SHARDS, never about tests")
    end
  end
end
