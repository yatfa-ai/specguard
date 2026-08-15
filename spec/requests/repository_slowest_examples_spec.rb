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

  # One row as a reader meets it: the label, the two coordinate lines under it, the duration, and
  # what CI reported happened to it. Whitespace-collapsed, because a label and a location assembled
  # across two ERB tags are two readings on the page whatever the source did with indentation.
  #
  # The two coordinate lines are told apart by POSITION and never by what they say: for an ordinary
  # example they read nearly the same, and telling them apart by text would pass on a cell that
  # printed one of them twice. The run-in line is ALWAYS rendered — a path, or "not reported" — so
  # it is the last span of the cell, and a definition site exists only where there are two.
  def rows
    panel.all("tbody tr").map do |row|
      label_cell, duration_cell, outcome_cell = row.all("td")
      sites = label_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }
      ran_in = sites.last
      location = sites.first if sites.size > 1
      label = label_cell.text.gsub(/\s+/, " ").strip
      [ran_in, location].compact.each { |site| label = label.delete_suffix(site).strip }

      { label: label, location: location, ran_in: ran_in, duration: duration_cell.text.strip,
        outcome: outcome_cell.text.strip, outcome_class: outcome_cell.find("span")[:class] }
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

  # The rung these rows used to stop short of. Every row in this panel is an outlier, and the
  # reader's next question — is this ONE test slow, or is the whole file — has a panel further down
  # the same page that nothing in this cell reached. It was reachable from every other per-example
  # listing SpecGuard renders and not from the first one.
  #
  # The coordinate the panel already printed is not a workaround for that: `#location_label` is the
  # DEFINITION site and the drill-in is keyed on the INCLUDING file, so for a shared example group
  # the path on the page is not the path that opens. The examples below turn on exactly that row.
  #
  # Local methods rather than constants, for the reason
  # spec/requests/repository_drill_down_carry_spec.rb spells out: a constant assigned inside an
  # `RSpec.describe` block lands on `Object`, where a sibling file assigning the same name would
  # decide the value both files read — and spec/requests/repository_spec_file_examples_spec.rb
  # already holds `ORDER_SPEC` there.
  describe "the file each ranked example ran in" do
    def order_spec = "spec/models/order_spec.rb"

    def refund_spec = "spec/models/refund_spec.rb"

    # Two files, so a link asserted to reach one has another it could have reached instead, and the
    # second file carries two rows so "the open file is marked" cannot pass by marking one row.
    def two_file_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 1, file_path: order_spec),
                          example_spec(name: "Refund settles the original charge", duration: 4.0,
                                       line_number: 2, file_path: refund_spec),
                          example_spec(name: "Refund is valid with a charge", duration: 1.0,
                                       line_number: 3, file_path: refund_spec)])
      repository
    end

    def links = panel.all("tbody tr a")

    # The rows of the destination panel, as text. Used to compare the panel reached from HERE against
    # the same panel reached from the by-file rollup, which is the only assertion that can say the
    # two entry points open the same thing rather than two links that merely look alike.
    def spec_file_panel_rows
      Capybara.string(response.body).find("#spec-file-examples").all("tbody tr")
              .map { |row| row.text.gsub(/\s+/, " ").strip }
    end

    it "links each row's file into the spec-file drill-down" do
      get repository_path(two_file_run)

      href = panel.first("tbody tr").find("a", text: order_spec)[:href]

      expect(href).to include("spec_file=#{CGI.escape(order_spec)}")
      expect(href).to include("#spec-file-examples")
    end

    # The definition site is not replaced by the file that ran the example; the cell states both.
    it "still names where the example is defined, beside the file that ran it" do
      get repository_path(two_file_run)

      expect(rows.first[:location]).to eq("#{order_spec}:1")
      expect(rows.first[:ran_in]).to eq(order_spec)
    end

    # A list of choices with one of them taken — the same mark the sibling listings carry, so a
    # reader arriving back at this ranking is told which row they are already looking at.
    it "marks the rows whose file is already open, and only those" do
      get repository_path(two_file_run, spec_file: refund_spec)

      expect(links.map { |link| [link.text, link["aria-current"]] })
        .to eq([[order_spec, nil], [refund_spec, "true"], [refund_spec, "true"]])
    end

    # THE row this link exists for, and the one the printed coordinate cannot serve. `spec_file_path`
    # is the INCLUDING file and `file_path` the definition site; they differ exactly here, so the
    # path this cell printed before is a `spec/support/` file and the file that opens is one the cell
    # never named.
    it "links the file that RAN a shared example group rather than the file defining it" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "behaves like an auditable record", duration: 9.0,
                                       line_number: 7,
                                       file_path: "spec/support/shared_examples.rb",
                                       spec_file_path: order_spec, id: "./#{order_spec}[1:1:1]")])

      get repository_path(repository)

      expect(rows.first[:location]).to eq("spec/support/shared_examples.rb:7")
      expect(rows.first[:ran_in]).to eq(order_spec)
      expect(links.first[:href]).to include("spec_file=#{CGI.escape(order_spec)}")
      # And never the two halves of different files printed as one pair, which would point at
      # whatever sits on line 7 of the including file.
      expect(panel).to have_no_text("#{order_spec}:7")
    end

    # `spec_file_path` is NULLABLE in the schema. `Ingest::ObservationRecorder#attributes` populates
    # it by falling back to `file_path`, so neither the producer nor the fixture can write a nil —
    # which is exactly why the column is set directly here. A defensive branch nothing exercises is a
    # branch that gets deleted as dead, and the cell it guards would otherwise link to nowhere.
    it "says so rather than linking nowhere where a row has no including file" do
      repository = two_file_run
      SpecObservation.where(line_number: 1).update_all(spec_file_path: nil)

      get repository_path(repository)

      expect(rows.first[:ran_in]).to eq("not reported")
      expect(panel.first("tbody tr")).to have_no_css("a")
      # The definition site is NOT NULL and is what such a row is read by.
      expect(rows.first[:location]).to eq("#{order_spec}:1")
    end

    # Opening a file from here is not a request to close a branch, an area or a description the
    # reader opened separately — the carry-through rule
    # spec/requests/repository_drill_down_carry_spec.rb owns, asserted at this link end-to-end:
    # the href carries the three other asks AND the page it lands on still has all three open.
    it "carries every other open ask through the link, and through following it" do
      description = "Order refuses a negative quantity"
      get repository_path(two_file_run, branch: "main", spec_directory: "spec/models",
                                        repeated_description: description)

      href = panel.first("tbody tr").find("a", text: order_spec)[:href]

      expect(href).to include("branch=main")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
      expect(href).to include("repeated_description=#{CGI.escape(description)}")

      get href.split("#").first

      page = Capybara.string(response.body)
      expect(page).to have_css("#spec-file-examples")
      expect(page).to have_css("#spec-directory-files")
      expect(page).to have_css("#repeated-description-examples")
    end

    # Two entry points, one destination. Asserting the href alone would pass on a link that reached a
    # panel narrowed differently from the one the by-file rollup opens; this follows both and
    # compares what the reader actually gets.
    it "opens the same file panel the by-file rollup opens" do
      get repository_path(two_file_run)

      from_slowest = panel.first("tbody tr").find("a", text: order_spec)[:href]
      from_rollup = Capybara.string(response.body).find("#spec-file-durations")
                            .find("a", text: order_spec)[:href]

      get from_slowest.split("#").first
      via_slowest = spec_file_panel_rows
      get from_rollup.split("#").first
      via_rollup = spec_file_panel_rows

      expect(via_slowest).to eq(via_rollup)
      # Falsifiable: two empty panels are equal to each other and prove nothing.
      expect(via_slowest.size).to eq(1)
    end
  end

  # The outcome half of the panel — the read this slice adds. `spec_observations.outcome` is
  # written on every example row of every ingest and was, until now, read by nothing: the page
  # ranked ten wall clocks and could not say whether any of them passed. `#slowest_in` still does
  # not filter on outcome and must not — a failed example that burned sixty seconds spent that time
  # — so the whole job here is that the reader can tell the run's most expensive test from its most
  # broken one.
  describe "what the ranked examples reported" do
    def outcome_run(specs)
      repository = create_repository(user: @user)
      ingest(repository, specs)
      get repository_path(repository)
    end

    it "reports each ranked example's outcome, in the word CI sent" do
      outcome_run([example_spec(name: "blew up", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "skipped", duration: 5.0, line_number: 2, outcome: "pending"),
                   example_spec(name: "fine", duration: 1.0, line_number: 3, outcome: "passed")])

      expect(rows.map { |row| row[:outcome] }).to eq(%w[failed pending passed])
    end

    # THE row this column exists for. `outcome` is nullable — the client sends
    # `result&.status&.to_s`, so an example that never ran carries none — and a blank cell, or one
    # silently wearing a pass's colour, is "the client said nothing" made byte-identical to "this
    # test passed" at the head of a list of the suite's slowest tests.
    it "reads a row with no outcome as not-reported, and not in the colour a pass wears" do
      outcome_run([example_spec(name: "silent", duration: 9.0, line_number: 1, outcome: nil),
                   example_spec(name: "fine", duration: 1.0, line_number: 2, outcome: "passed")])

      silent, passed = rows

      expect(silent[:outcome]).to eq("not reported")
      expect(silent[:outcome_class]).not_to eq(passed[:outcome_class])
      # Named tokens, not merely "different": a nil must not land on the success tone, and the
      # difference between two rows would survive it landing on any other colour at all.
      expect(silent[:outcome_class]).to include("text-app-content-secondary")
      expect(passed[:outcome_class]).to include("text-app-success")
    end

    it "colours a failure as a failure rather than leaving it to be read" do
      outcome_run([example_spec(name: "blew up", duration: 9.0, line_number: 1, outcome: "failed")])

      expect(rows.first[:outcome_class]).to include("text-app-error")
    end

    # Nothing platform-side validates this string — `Ingest::Payload` does not — so an
    # unrecognised value is echoed and left uncoloured rather than folded into a pass.
    it "echoes an outcome it does not recognise without colouring it as a pass" do
      outcome_run([example_spec(name: "odd", duration: 9.0, line_number: 1, outcome: "aborted")])

      expect(rows.first[:outcome]).to eq("aborted")
      expect(rows.first[:outcome_class]).not_to include("text-app-success")
    end

    # One grain up: nothing on this page said whether the latest run was red, so every figure the
    # panel prints was computed off a run that may have aborted a third of the way through.
    # Counted off the rows THIS RUN wrote, never off `TestRun#total_specs_count`.
    it "states how many of the rows it recorded reported failed and pending" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 5.0, line_number: 2, outcome: "pending"),
                   example_spec(name: "three", duration: 3.0, line_number: 3, outcome: "passed"),
                   example_spec(name: "four", duration: 1.0, line_number: 4, outcome: "passed")])

      expect(basis_line).to have_text("Every one of the 4 examples this run recorded reported an " \
                                      "outcome: 1 failed, 1 pending", normalize_ws: true)
    end

    # The remainder is stated as neither of the two counted names and specifically not as a pass.
    # Nothing validates the string, so "2 passed" would be a verdict over a value nobody checked.
    # The `0 pending` here is an HONEST zero and is printed: it sits on a run that DID report
    # outcomes, so it counts pendings rather than silence — which is the distinction the
    # no-outcomes example below turns on.
    it "words the remainder as something other than failed or pending, never as passes" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 3.0, line_number: 2, outcome: "passed"),
                   example_spec(name: "three", duration: 1.0, line_number: 3, outcome: "passed")])

      expect(basis_line).to have_text("1 failed, 0 pending, and 2 reported something other than either",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("2 passed")
    end

    it "counts the rows that said nothing separately from the ones that did" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 3.0, line_number: 2, outcome: nil),
                   example_spec(name: "three", duration: 1.0, line_number: 3, outcome: nil)])

      expect(basis_line).to have_text("1 of the 3 examples this run recorded reported an outcome: " \
                                      "1 failed and 0 pending. The other 2 reported none.",
                                      normalize_ws: true)
    end

    # VACUOUS GREEN, refused explicitly. A run whose every row carries a nil outcome has a
    # legitimate `failed_count` of 0 — and printing that zero renders "this run said nothing" in
    # the words of "everything passed". The count must not appear at all on such a run.
    it "says a run that reported no outcome at all did not say, rather than printing zero failures" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: nil),
                   example_spec(name: "two", duration: 1.0, line_number: 2, outcome: nil)])

      expect(basis_line).to have_text("Not one of the 2 examples this run recorded reported an " \
                                      "outcome", normalize_ws: true)
      expect(basis_line).to have_no_text("0 failed")
      expect(rows.map { |row| row[:outcome] }).to eq(["not reported", "not reported"])
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size.
    it "counts outcomes off its own rows rather than the run's suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1, outcome: "failed")],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of the 1 example this run recorded reported an " \
                                      "outcome: 1 failed", normalize_ws: true)
      expect(basis_line).to have_no_text("4,000")
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

    # The composition appears in THIS branch too, deliberately. There is no ranking here and so no
    # Outcome column, but "nothing was timed" is a fact about durations and says nothing whatever
    # about how those examples ended — and a delivery carrying no timings and a failure is exactly
    # the run that would otherwise disclose nothing at all.
    it "still says what those examples reported, having nothing to rank them by" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1, outcome: "failed"),
                          example_spec(name: "nor this", duration: nil, line_number: 2, outcome: "passed")])

      get repository_path(repository)

      expect(panel).to have_text("Every one of the 2 examples this run recorded reported an " \
                                 "outcome: 1 failed, 0 pending", normalize_ws: true)
    end

    # And the same Vacuous Green refusal as the ranked branch: no timings AND no outcomes is a run
    # that said nothing, not a run with no failures.
    it "does not print a zero failure count where those examples reported no outcome either" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1, outcome: nil),
                          example_spec(name: "nor this", duration: nil, line_number: 2, outcome: nil)])

      get repository_path(repository)

      expect(panel).to have_text("Not one of the 2 examples this run recorded reported an outcome",
                                 normalize_ws: true)
      expect(panel).to have_no_text("0 failed")
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
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

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
      # ranking, one aggregate — and the other two are the rollup panels below it: the "Heaviest
      # spec files" grouped read and the "Heaviest spec directories" one that takes the same rows
      # up to the code area. Both of those budgets are asserted in
      # spec/requests/repository_spec_file_durations_spec.rb. The fifth is the cross-run panel's
      # gating probe, which on this single-run fixture establishes that outcomes cannot be compared
      # and asks nothing further; its own budget is asserted in
      # spec/requests/repository_unstable_tests_spec.rb.
      #
      # RECOUNTED AT 7 by SPGD-344, which added the "Descriptions this run recorded more than once"
      # panel: TWO further reads of this table, both over this same run's rows. The first groups
      # them by DESCRIPTION — a grain no panel on this page could reach, since the only two
      # `GROUP BY name` reads in the application are narrowed to failures — and the second counts
      # the rows that carry no description, which the first has to exclude in its WHERE clause and
      # therefore cannot count for itself. Its own budget, including that the two stay two as the
      # number of repeated descriptions grows, is asserted in
      # spec/requests/repository_repeated_descriptions_spec.rb.
      # Page-wide rather than panel-scoped on purpose: what must not grow is the number of times
      # ONE page walks this table, and only a count taken across the whole request can say that.
      expect(large_queries.size).to eq(7)
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
