# frozen_string_literal: true

require "rails_helper"

# The "Tests whose outcome changed" panel on repositories#show — the first read this application
# makes that matches a test to ITSELF across runs, and the first answer it gives about a test's
# HISTORY rather than about one run of it. "Areas that grew or shrank" spans two runs before it but
# pairs nothing inside them: it subtracts two per-area counts and matches no tests.
#
# Its own file, alongside the siblings that each took one panel of this page
# (repository_slowest_examples_spec.rb, repository_spec_file_durations_spec.rb,
# repository_suite_trajectory_spec.rb): every example here needs the same multi-run fixture, and
# the Overview/API-keys file is edited by sibling slices.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand. Every state this panel turns on is a state the RECORDER produces from what a
# real client sends — a nil `outcome` is `result&.status` coming back nil, a nil `name` is a
# producer that sends no description, and two examples sharing a description in one run is an
# ordinary table-driven loop. A hand-built fixture would be asserting against shapes nothing in
# production writes.
RSpec.describe "Repository unstable tests", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#unstable-tests")

  def panel?
    Capybara.string(response.body).has_css?("#unstable-tests")
  end

  # ELEMENT-scoped, never panel-scoped. The window sentence, the incomparable state and the honest
  # zero share most of their words — "runs", "outcome", the branch name — so a panel-level
  # `have_text` passes for the wrong state with the deciding branch deleted.
  def basis_line = panel.find("#unstable-tests-basis")

  def incomparable = panel.find("#unstable-tests-incomparable")

  def none_state = panel.find("#unstable-tests-none")

  def shared_section = panel.find("#unstable-tests-shared")

  def section?(id) = panel.has_css?("##{id}")

  # One row as a reader meets it: the description, the note under it when the description was
  # recorded under more than one file, how much of the window it was seen in, how much of that it
  # failed, and the words the runs used. Whitespace-collapsed, because a name and a file note
  # assembled across two ERB tags are two readings on the page whatever the source did with
  # indentation.
  def rows
    panel.all("tbody tr").map do |row|
      name_cell, seen_cell, failed_cell, outcome_cell = row.all("td")
      files = name_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }.first
      name = name_cell.text.gsub(/\s+/, " ").strip
      name = name.delete_suffix(files).strip if files

      { name: name, files: files, seen: seen_cell.text.strip, failed: failed_cell.text.strip,
        outcomes: outcome_cell.all("span span").map { |badge| badge.text.strip } }
    end
  end

  def row_names = rows.map { |row| row[:name] }

  # One ingested run, through the producer. `specs` are the wire hashes a client POSTs; the
  # recorder reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
  #
  # Every run is stamped back in time so the trajectory window — which this panel shares — orders
  # them the way CI produced them rather than by whatever order the fixture inserted them in.
  def ingest(repository, specs, commit_sha:, branch: "main", at: nil)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    # Resolved inline, because this panel now GROUPS on the durable identity (SPGD-758): an
    # unresolved row is excluded from the matching rather than keyed by its description. Resolving
    # here is the shape the endpoint's own pipeline produces one job later, and without it every
    # row this file seeds would be an exclusion rather than a test.
    Ingest::IdentityResolver.resolve(run)
    run
  end

  # One example on the wire. `outcome:` and `name:` are passed at every call site, nils included —
  # an unreported outcome and an unnamed example are both states this file turns on, and the shared
  # builder substitutes a default for a nil `name:`, so both are merged in rather than passed
  # through.
  def example_spec(name:, outcome:, line_number: 1, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: 0.1)
      .merge({ name: name, outcome: outcome }.merge(attrs))
  end

  # A repository whose window holds one run per entry of `outcomes_per_run`, each run reporting the
  # given outcome for the named test plus a second test that reports the same way — so a window of
  # nils is a window that reported NOTHING, which is the state half this file turns on, and a
  # window of words is comparable by construction.
  def repository_with(outcomes_per_run, name: "Invoice finalize locks the line items", **attrs)
    repository = create_repository(user: @user)
    outcomes_per_run.each_with_index do |outcome, index|
      ingest(repository,
             [example_spec(name: name, outcome: outcome, line_number: 1, **attrs),
              example_spec(name: "User signs in", outcome: outcome.nil? ? nil : "passed",
                           line_number: 2, file_path: "spec/models/user_spec.rb")],
             commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
    end
    repository
  end

  # Criterion 1 — the whole point of the slice. A test that failed in some runs of the window and
  # passed in others is NAMED, with the window it was measured over, the share of it that failed,
  # and the words CI used.
  describe "a window holding a test that failed in some runs and not others" do
    # @intent: {"entity": "SpecObservation", "action": "rank outcome-changing test", "behavior": "a test that failed 2 of its 5 runs is the sole row, seen 5 of 5, failed 2 of 5, with outcome words failed and passed", "layer": "request"}
    it "names the test, the runs compared, the runs it failed, and the outcome words seen" do
      repository = repository_with(%w[passed failed passed passed failed])

      get repository_path(repository)

      expect(row_names).to eq(["Invoice finalize locks the line items"])
      expect(rows.first[:seen]).to eq("5 of 5")
      expect(rows.first[:failed]).to eq("2 of 5")
      expect(rows.first[:outcomes]).to eq(%w[failed passed])
    end

    # The test that never varied is not on the list — the panel names what CHANGED, and a stable
    # test rendered beside a flaky one is the signal buried in the population it was drawn from.
    # @intent: {"entity": "SpecObservation", "action": "omit stable test", "behavior": "the always-passing companion test never appears in the panel's rows", "layer": "request"}
    it "leaves out the test that reported the same outcome in every run" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      expect(row_names).not_to include("User signs in")
    end

    # A test that failed in EVERY run of the window is broken, not unstable. The panel's own words
    # for its scope, and the reason the candidate ordering sheds this end of the list first.
    # @intent: {"entity": "SpecObservation", "action": "omit always-failing test", "behavior": "a test failed in all 3 runs yields an empty list and the none state says not one of them reported any other outcome", "layer": "request"}
    it "leaves out the test that failed in every run" do
      repository = repository_with(%w[failed failed failed])

      get repository_path(repository)

      expect(panel?).to be(true)
      expect(rows).to be_empty
      expect(none_state).to have_text("not one of them reported any other outcome", normalize_ws: true)
    end

    # The denominator is the runs the test APPEARED in, never the length of the window. A test
    # added halfway through failed in one of the three runs that ran it, and dividing by six would
    # report a stability it was never measured for.
    # @intent: {"entity": "SpecObservation", "action": "denominate by appearance", "behavior": "a test in 3 of 6 window runs reports seen 3 of 6 and failed 1 of 3, dividing by appearances rather than window length", "layer": "request"}
    it "measures the failures against the runs the test appeared in, not against the window" do
      repository = create_repository(user: @user)
      6.times do |index|
        specs = [example_spec(name: "User signs in", outcome: "passed", line_number: 2,
                              file_path: "spec/models/user_spec.rb")]
        if index >= 3
          specs << example_spec(name: "Invoice finalize locks the line items",
                                outcome: index == 4 ? "failed" : "passed")
        end
        ingest(repository, specs, commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      get repository_path(repository)

      expect(rows.first[:name]).to eq("Invoice finalize locks the line items")
      expect(rows.first[:seen]).to eq("3 of 6")
      expect(rows.first[:failed]).to eq("1 of 3")
    end

    # The window is the one the "Suite growth" panel is drawn on, branch and all. Outcomes compared
    # across branches are outcomes of different code, so a feature branch's failure is not this
    # branch's flake.
    # @intent: {"entity": "SpecObservation", "action": "compare within branch", "behavior": "a feature-branch failure leaves the main-anchored list empty with the basis saying on main, while asking for feature/x gets the incomparable state naming that branch", "layer": "request"}
    it "compares only the runs on the branch the page is anchored to" do
      repository = repository_with(%w[passed passed passed])
      ingest(repository,
             [example_spec(name: "Invoice finalize locks the line items", outcome: "failed")],
             commit_sha: "sidebranch01", branch: "feature/x", at: 40.days.ago)

      get repository_path(repository)

      expect(basis_line).to have_text("on main", normalize_ws: true)
      expect(rows).to be_empty

      # And the same failure IS a change once the reader asks for that branch — except that branch
      # holds one run, so what they are told is that it cannot be compared, rather than a zero.
      get repository_path(repository, branch: "feature/x")

      expect(incomparable).to have_text("on feature/x", normalize_ws: true)
    end

    # The window states what it was: how many runs, on which branch, and how many of them said
    # anything at all about how their examples ended. The third figure is the one a length cannot
    # substitute for.
    # @intent: {"entity": "SpecObservation", "action": "state comparison window", "behavior": "the basis line reads Across the last 3 runs on main, every one of which reported an outcome for at least one example", "layer": "request"}
    it "states the window every figure was drawn from" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      expect(basis_line).to have_text("Across the last 3 runs on main, every one of which reported " \
                                      "an outcome for at least one example", normalize_ws: true)
    end

    # The matching rule is the one DECISION on this panel rather than a measurement, and a reader
    # cannot check the list against their own repository without it.
    # @intent: {"entity": "SpecObservation", "action": "state matching rule", "behavior": "the basis says tests are matched across those runs by their durable identity and that an unannotated test is identified by description, so a rewording starts a new one", "layer": "request"}
    it "states the rule the tests were matched by" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository)

      expect(basis_line).to have_text("matched across those runs by their durable identity",
                                      normalize_ws: true)
      expect(basis_line).to have_text("an unannotated test is identified by its description, so " \
                                      "a reworded unannotated test starts a new one",
                                      normalize_ws: true)
    end

    # Where the panel stops looking, said rather than left to be discovered. The search begins at
    # the runs' failures, so variance that never involved one is out of scope.
    # @intent: {"entity": "SpecObservation", "action": "state reporting boundary", "behavior": "the basis says the search starts from what failed and that variance without ever failing is not reported by this panel", "layer": "request"}
    it "states the boundary it does not report past" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository)

      expect(basis_line).to have_text("The search starts from what failed", normalize_ws: true)
      expect(basis_line).to have_text("without ever failing is outcome variance this panel does " \
                                      "not report", normalize_ws: true)
    end

    # The scope claim above, made true. A test that alternated between two non-failing outcomes is
    # exactly what the narrowing cannot see, and a panel that quietly listed it would be describing
    # a population it does not read.
    # @intent: {"entity": "SpecObservation", "action": "omit non-failing variance", "behavior": "a passed-pending alternation yields no rows and the none state says No example failed in any of the 4 runs", "layer": "request"}
    it "does not report a test that alternated between outcomes without ever failing" do
      repository = repository_with(%w[passed pending passed pending])

      get repository_path(repository)

      expect(rows).to be_empty
      expect(none_state).to have_text("No example failed in any of the 4 runs", normalize_ws: true)
    end

    # The words are echoed, never reworded and never folded into a verdict — nothing platform-side
    # validates this string, so quoting what arrived is the only reading that cannot be wrong.
    # @intent: {"entity": "SpecObservation", "action": "echo unknown outcome", "behavior": "the unrecognised word flaked is echoed as its own badge beside failed rather than read as a pass", "layer": "request"}
    it "echoes an outcome word it does not recognise rather than reading it as a pass" do
      repository = repository_with(%w[failed flaked])

      get repository_path(repository)

      expect(rows.first[:outcomes]).to eq(%w[failed flaked])
      expect(panel).to have_css(".text-app-content-secondary", text: "flaked")
    end

    # Silence inside a population that reported is not a pass and is not covered by the words
    # beside it. It wears `SpecObservation#outcome_label`'s own vocabulary for that reason.
    # @intent: {"entity": "SpecObservation", "action": "count silent runs", "behavior": "two nil outcomes render as a single not reported \u00d72 entry after failed and passed", "layer": "request"}
    it "counts the runs that recorded the test and said nothing, as silence rather than as a pass" do
      repository = repository_with(["failed", "passed", nil, nil])

      get repository_path(repository)

      expect(rows.first[:outcomes]).to eq(["failed", "passed", "not reported ×2"])
    end
  end

  # Criterion 2 — the Vacuous Green refusal. `outcome` is nullable, so a window whose client sends
  # none produces exactly the empty list a perfectly stable window does.
  describe "a window in which fewer than two runs reported an outcome" do
    # @intent: {"entity": "SpecObservation", "action": "refuse all-silent window", "behavior": "a nil-only window renders the incomparable state saying not one of the 3 runs on main said how any example ended and This one said nothing", "layer": "request"}
    it "says the comparison cannot be made, over a window that reported nothing at all" do
      repository = repository_with([nil, nil, nil])

      get repository_path(repository)

      expect(incomparable).to have_text("at least two runs that reported them", normalize_ws: true)
      expect(incomparable).to have_text("Of the 3 runs on main, not one of them said how any " \
                                        "example ended", normalize_ws: true)
      # The silence explanation belongs to THIS state and is asserted present only here, so that
      # the `have_no_text` controls below are the absence of something the suite knows renders.
      expect(incomparable).to have_text("This one said nothing", normalize_ws: true)
    end

    # The gate is false in two states, not one, and the second is not silence: the window reported,
    # and holds one run to have reported it. The explanation must move with the leading clause —
    # "This one said nothing" over a window that DID say something is the Vacuous Green hazard
    # mirrored, a report read as silence, and it contradicts the "Slowest tests" panel drawn from
    # the same window directly above. Asserted here in BOTH directions, because a clause asserted
    # present and never asserted absent where it does not apply is how the false one shipped green.
    # @intent: {"entity": "SpecObservation", "action": "refuse single-report window", "behavior": "with exactly one reporting run the incomparable state says that report is real but the only one here, and never claims This one said nothing", "layer": "request"}
    it "says it again over a window where exactly one run reported" do
      repository = repository_with([nil, "failed", nil])

      get repository_path(repository)

      expect(incomparable).to have_text("Of the 3 runs on main, one of them said how an example " \
                                        "ended", normalize_ws: true)
      expect(incomparable).to have_text("That report is real — it is simply the only one here",
                                        normalize_ws: true)
      expect(incomparable).to have_text("A second run that reports is what this window is short of",
                                        normalize_ws: true)
      expect(incomparable).to have_no_text("This one said nothing", normalize_ws: true)
    end

    # The whole point of the clause: no zero, and no empty list wearing the shape of a result. The
    # honest zero and the basis paragraph are BOTH withheld, because both are claims about a
    # comparison that did not happen.
    # @intent: {"entity": "SpecObservation", "action": "withhold zero when silent", "behavior": "over an all-silent two-run window neither the none state, the basis nor any row renders, and no 0-tests figure appears", "layer": "request"}
    it "prints no zero and no list over it" do
      repository = repository_with([nil, nil])

      get repository_path(repository)

      expect(section?("unstable-tests-none")).to be(false)
      expect(section?("unstable-tests-basis")).to be(false)
      expect(panel).to have_no_css("tbody tr")
      expect(panel.text).not_to match(/\b0 (tests|descriptions)\b/)
    end

    # One run cannot be compared against itself however much it reported, which is the arithmetic
    # the gate exists for rather than a nullability detail.
    #
    # This is the state where reading the report as silence is worst: the "Slowest tests" panel
    # directly above is drawn from the same window and says every example of that run reported an
    # outcome. Two panels on one page cannot disagree about whether CI said anything, so the
    # absence is asserted here as well as on the multi-run window above — one red example would
    # not show that both states have reach.
    # @intent: {"entity": "SpecObservation", "action": "refuse single-run window", "behavior": "one fully-reporting run renders the incomparable state saying one run's outcome cannot have changed from anything, never This one said nothing", "layer": "request"}
    it "says it over a single run that reported everything" do
      repository = repository_with(%w[failed])

      get repository_path(repository)

      expect(incomparable).to have_text("one run's outcome cannot have changed from anything",
                                        normalize_ws: true)
      expect(incomparable).to have_text("A second run that reports is what this window is short of",
                                        normalize_ws: true)
      expect(incomparable).to have_no_text("This one said nothing", normalize_ws: true)
    end

    # A window with no per-example rows at all is not this state — it is a repository with no
    # cross-run test history to discuss, and the panel stays off rather than explaining itself.
    # @intent: {"entity": "SpecObservation", "action": "omit panel without examples", "behavior": "a repository whose two runs recorded no per-example rows answers 200 with no panel rendered", "layer": "request"}
    it "renders no panel at all for a window that recorded no examples" do
      repository = create_repository(user: @user)
      2.times do |index|
        create_test_run(repository: repository, commit_sha: "bare#{index}", branch: "main",
                        total_specs_count: 10, created_at: (10 - index).days.ago)
      end

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # Criterion 3 — the honest zero, reachable only behind the clause above, and worded against the
  # runs it was drawn from rather than the length of the window.
  describe "a window that reported outcomes and held nothing unstable" do
    # @intent: {"entity": "SpecObservation", "action": "word clean zero", "behavior": "an all-passing window's none state says No example failed in any of the 3 runs on main that reported outcomes and that the comparison was supported", "layer": "request"}
    it "words the zero against the runs that reported, where nothing failed at all" do
      repository = repository_with(%w[passed passed passed])

      get repository_path(repository)

      expect(none_state).to have_text("No example failed in any of the 3 runs on main that " \
                                      "reported outcomes", normalize_ws: true)
      expect(none_state).to have_text("That is a comparison this window supported", normalize_ws: true)
    end

    # A different fact from "nothing failed", and one a reader with a permanently red test needs
    # said differently: things failed, and they always failed.
    # @intent: {"entity": "SpecObservation", "action": "word always-failed zero", "behavior": "an always-failing window's none state says 1 description failed somewhere in the 2 runs on main and never reported any other outcome anywhere in them", "layer": "request"}
    it "words it differently where things failed and always failed" do
      repository = repository_with(%w[failed failed])

      get repository_path(repository)

      expect(none_state).to have_text("1 description failed somewhere in the 2 runs on main that " \
                                      "reported outcomes, and not one of them reported any other " \
                                      "outcome anywhere in them", normalize_ws: true)
    end

    # The zero is only ever a zero of the population it counted, so the window sentence is rendered
    # over it exactly as it is over a populated list.
    # @intent: {"entity": "SpecObservation", "action": "state zero's window", "behavior": "even over an empty result the basis still reads Across the last 2 runs on main", "layer": "request"}
    it "still states the window the zero was drawn from" do
      repository = repository_with(%w[passed passed])

      get repository_path(repository)

      expect(basis_line).to have_text("Across the last 2 runs on main", normalize_ws: true)
    end
  end

  # Criterion 4 — a null description cannot be matched to itself across runs, so it is excluded
  # from the matching and the exclusion is counted and stated.
  describe "rows that carried no description" do
    def unnamed_window
      repository = create_repository(user: @user)
      3.times do |index|
        ingest(repository,
               [example_spec(name: "Invoice finalize locks the line items",
                             outcome: index == 1 ? "failed" : "passed"),
                example_spec(name: nil, outcome: "failed", line_number: 9,
                             file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "exclude unnamed rows", "behavior": "the 3 unnamed rows stay out of the ranking while the basis counts them and says two of those are not known to be one test", "layer": "request"}
    it "excludes them from the matching and says how many rows it excluded" do
      get repository_path(unnamed_window)

      expect(row_names).to eq(["Invoice finalize locks the line items"])
      expect(basis_line).to have_text("3 rows in this window carried no description",
                                      normalize_ws: true)
      expect(basis_line).to have_text("two of those are not known to be one test", normalize_ws: true)
    end

    # Counted in ROWS and worded that way. An unnamed row is precisely a row this panel cannot say
    # is a test, so reporting a number of "tests" would be the identity claim the exclusion
    # declines to make.
    # @intent: {"entity": "SpecObservation", "action": "never pool unnamed rows", "behavior": "the list holds only the named test's single row and the basis never says 3 tests", "layer": "request"}
    it "never pools the unnamed rows into one test of their own" do
      get repository_path(unnamed_window)

      expect(rows.size).to eq(1)
      expect(basis_line).to have_no_text("3 tests")
    end

    # One unnamed row is an ordinary window: `unnamed_row_count_in` is a plain count with no floor,
    # and `comparable?` is a predicate over RUNS, so a window can be comparable while holding a
    # single null-name row. The sentence counts it and then states the rule ABOUT IT — "two of
    # those" would quantify over a population this window does not have, and "pooled into one" is
    # vacuous when there is nothing to pool.
    def single_unnamed_window
      repository = create_repository(user: @user)
      3.times do |index|
        examples = [example_spec(name: "Invoice finalize locks the line items",
                                 outcome: index == 1 ? "failed" : "passed")]
        if index.zero?
          examples << example_spec(name: nil, outcome: "failed", line_number: 9,
                                   file_path: "spec/models/ledger_spec.rb")
        end
        ingest(repository, examples,
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "word single exclusion", "behavior": "one unnamed row reads 1 row in this window carried no description, excluded from the matching rather than pooled into a test", "layer": "request"}
    it "states the exclusion in the singular when exactly one row carried no description" do
      get repository_path(single_unnamed_window)

      expect(row_names).to eq(["Invoice finalize locks the line items"])
      expect(basis_line).to have_text("1 row in this window carried no description",
                                      normalize_ws: true)
      expect(basis_line).to have_text(
        "a null description is not known to be one test with itself across runs, so it is " \
        "excluded from the matching rather than pooled into a test", normalize_ws: true
      )
    end

    # The defect this pins: a hardcoded numeral in the second clause that does not derive from the
    # count in the first, so the sentence counted 1 and quantified over 2 in one breath.
    # @intent: {"entity": "SpecObservation", "action": "keep singular grammar", "behavior": "the single-unnamed-row window's basis never says two of those nor the ungrammatical 1 rows", "layer": "request"}
    it "never quantifies over two rows when only one carried no description" do
      get repository_path(single_unnamed_window)

      expect(basis_line).to have_no_text("two of those")
      expect(basis_line).to have_no_text("1 rows")
    end

    # The clause is about THIS window and appears only when there is something to say. "0 rows
    # carried no description" is a sentence about arithmetic.
    # @intent: {"entity": "SpecObservation", "action": "omit unnamed clause", "behavior": "a fully-named window's basis says nothing about rows carrying no description", "layer": "request"}
    it "says nothing about unnamed rows when every row carried a description" do
      get repository_path(repository_with(%w[passed failed]))

      expect(basis_line).to have_no_text("carried no description")
    end
  end

  # Criterion 5 — a description carried by two examples in one run is not a key for that run, so
  # its `failed` and its `passed` are two tests rather than one that flipped.
  describe "a description carried by more than one example in a single run" do
    def shared_description_window
      repository = create_repository(user: @user)
      3.times do |index|
        ingest(repository,
               [example_spec(name: "Order total sums the lines", outcome: "failed", line_number: 1),
                example_spec(name: "Order total sums the lines", outcome: "passed", line_number: 2),
                example_spec(name: "User signs in", outcome: "passed", line_number: 3,
                             file_path: "spec/models/user_spec.rb")],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "report shared description", "behavior": "the twice-carried description is kept out of the ranked rows and its own section says 6 examples under this description across 3 of 3 runs", "layer": "request"}
    it "reports it as two examples sharing a description, not as an outcome change" do
      get repository_path(shared_description_window)

      expect(row_names).not_to include("Order total sums the lines")
      expect(shared_section).to have_text("Order total sums the lines", normalize_ws: true)
      expect(shared_section).to have_text("6 examples under this description across 3 of 3 runs",
                                          normalize_ws: true)
    end

    # @intent: {"entity": "SpecObservation", "action": "explain shared exclusion", "behavior": "the shared section says a description is not a key within a single run and that calling them flaky would be a false positive manufactured by the matching rule", "layer": "request"}
    it "says why the matching rule could not rule on it" do
      get repository_path(shared_description_window)

      expect(shared_section).to have_text("A description is not a key within a single run",
                                          normalize_ws: true)
      expect(shared_section).to have_text("calling them flaky would be a false positive " \
                                          "manufactured by the matching rule", normalize_ws: true)
    end

    # Not silently dropped either. A dropped group is a silence the reader has no way to notice —
    # the mutation that turns this example red is deleting the section rather than the label.
    # @intent: {"entity": "SpecObservation", "action": "avoid silent drop", "behavior": "the shared-description section renders and says 1 description varied in outcome across this window", "layer": "request"}
    it "does not leave the window looking like an honest zero" do
      get repository_path(shared_description_window)

      expect(section?("unstable-tests-shared")).to be(true)
      expect(shared_section).to have_text("1 description varied in outcome across this window",
                                          normalize_ws: true)
    end

    # The zero directly above the section has to be worded against it. "Not one of them reported
    # any other outcome" is FALSE over this window — its shared description reported two — and it
    # would be printed inches above the section saying so.
    # @intent: {"entity": "SpecObservation", "action": "align zero with section", "behavior": "the zero above the section reads no single-example description changed its outcome across the 3 runs, never the contradicting not-one-of-them wording", "layer": "request"}
    it "words the zero above it against what the section reports, rather than contradicting it" do
      get repository_path(shared_description_window)

      expect(none_state).to have_text("No description belonging to a single example changed its " \
                                      "outcome across the 3 runs on main that reported outcomes",
                                      normalize_ws: true)
      expect(none_state).to have_no_text("not one of them reported any other outcome")
    end

    # The section is a disclosure, not a fixture of the page: a window with no ambiguous group
    # renders none of it.
    # @intent: {"entity": "SpecObservation", "action": "omit shared section", "behavior": "a window of one-example-per-run descriptions renders no shared-description section", "layer": "request"}
    it "renders no such section where every description was one example per run" do
      get repository_path(repository_with(%w[passed failed]))

      expect(section?("unstable-tests-shared")).to be(false)
    end
  end

  # Criterion 6 — per the project's semantic-identity rule a test that MOVED is the same test and
  # keeps its history, so a group spanning two files is a disclosure rather than an error.
  describe "a test recorded under more than one spec file" do
    # @intent: {"entity": "SpecObservation", "action": "label spanning files", "behavior": "a test recorded under two files is the sole row wearing the note recorded under both spec/billing and spec/models invoice_spec paths", "layer": "request"}
    it "labels the group with the files its history spans" do
      repository = create_repository(user: @user)
      [["spec/models/invoice_spec.rb", "passed"],
       ["spec/models/invoice_spec.rb", "failed"],
       ["spec/billing/invoice_spec.rb", "passed"]].each_with_index do |(file_path, outcome), index|
        ingest(repository,
               [example_spec(name: "Invoice finalize locks the line items", outcome: outcome,
                             file_path: file_path)],
               commit_sha: "run#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      get repository_path(repository)

      expect(row_names).to eq(["Invoice finalize locks the line items"])
      expect(rows.first[:files])
        .to eq("recorded under spec/billing/invoice_spec.rb and spec/models/invoice_spec.rb")
    end

    # The label is a disclosure and not a fixture of every row — a test that stayed put does not
    # wear a note saying which single file it was in.
    # @intent: {"entity": "SpecObservation", "action": "label single file nothing", "behavior": "a test whose history sits in one file carries no file note on its row", "layer": "request"}
    it "labels nothing on a test whose history sits in one file" do
      get repository_path(repository_with(%w[passed failed]))

      expect(rows.first[:files]).to be_nil
    end
  end

  # Criterion 7 — the candidate cap is a catastrophe valve, and a cap that does not disclose itself
  # turns "we looked at everything" and "we looked at the first two hundred" into the same panel.
  describe "a window in which more descriptions failed than the panel examines" do
    # Two runs, each reporting a failure for `limit + 2` distinct descriptions, of which exactly one
    # ALSO passes in the second run. The one that varied fails once and every other candidate fails
    # twice, so the fewest-failures-first ordering keeps it — which is the property that ordering
    # exists for, asserted rather than reasoned about.
    def truncated_window(limit)
      repository = create_repository(user: @user)
      2.times do |run_index|
        specs = (0..(limit + 1)).map do |i|
          outcome = (i.zero? && run_index == 1) ? "passed" : "failed"
          example_spec(name: "candidate #{format("%04d", i)}", outcome: outcome, line_number: i + 1)
        end
        ingest(repository, specs, commit_sha: "run#{format("%010d", run_index)}",
                                  at: (30 - run_index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "disclose candidate cap", "behavior": "with 7 failing descriptions capped at 5 the basis says the 5 that failed fewest times were compared across runs and the other 2 are not represented above", "layer": "request"}
    it "discloses that it examined only part of what failed, and which part" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(truncated_window(5))

      expect(basis_line).to have_text("7 descriptions failed somewhere in this window",
                                      normalize_ws: true)
      expect(basis_line).to have_text("the 5 that failed fewest times were the ones compared " \
                                      "across runs", normalize_ws: true)
      expect(basis_line).to have_text("the other 2 are not represented above", normalize_ws: true)
    end

    # @intent: {"entity": "SpecObservation", "action": "keep varying candidate", "behavior": "the fewest-failures-first ordering keeps candidate 0000 \u2014 the one description that varied \u2014 as the sole listed row", "layer": "request"}
    it "keeps the end of the candidate list a change could still be found in" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(truncated_window(5))

      expect(row_names).to eq(["candidate 0000"])
    end

    # The state neither example above reaches: the cap bit AND nothing among what it kept varied.
    # In `truncated_window` the varying candidate is always kept, so `#any?` is true there and the
    # honest zero is never rendered beside the truncation clause. Here every description fails in
    # both runs, so the two sentences print inches apart — and a zero that quantified over all
    # seven would assert a property of the two the clause directly above it says were never read.
    def uniformly_red_window(limit, candidates: limit + 2)
      repository = create_repository(user: @user)
      2.times do |run_index|
        specs = (0...candidates).map do |i|
          example_spec(name: "candidate #{format("%04d", i)}", outcome: "failed", line_number: i + 1)
        end
        ingest(repository, specs, commit_sha: "run#{format("%010d", run_index)}",
                                  at: (30 - run_index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "scope capped zero", "behavior": "under the cap the zero reads 5 of the 7 failing descriptions were compared across runs and not one of those reported any other outcome", "layer": "request"}
    it "words the zero against the descriptions it compared, not against everything that failed" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(uniformly_red_window(5))

      expect(rows).to be_empty
      expect(none_state).to have_text("5 of the 7 descriptions that failed somewhere in the 2 runs " \
                                      "on main that reported outcomes were the ones compared " \
                                      "across runs, and not one of those reported any other " \
                                      "outcome anywhere in them", normalize_ws: true)
    end

    # The mutation: deleting the `#truncated?` branch restores a sentence asserting a property of
    # all seven, printed under a clause saying two of them were never examined.
    # @intent: {"entity": "SpecObservation", "action": "disclaim unexamined descriptions", "behavior": "the caveat says the other 2 descriptions were never compared across runs so nothing here is a finding about them, and the all-seven zero wording never renders", "layer": "request"}
    it "says of the descriptions it never examined that nothing here is a finding about them" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(uniformly_red_window(5))

      expect(none_state).to have_text("The other 2 descriptions that failed in this window were " \
                                      "never compared across runs, so nothing here is a finding " \
                                      "about them", normalize_ws: true)
      expect(none_state).to have_no_text("7 descriptions failed somewhere in the")
      expect(none_state).to have_no_text("not one of them reported any other outcome")
    end

    # One description past the cap — `UNSTABLE_CANDIDATE_LIMIT + 1` failing descriptions — which is
    # the boundary both truncation clauses read worst at. `candidate_count` is the pre-LIMIT total,
    # so this is an ordinary state of the broadly-red suite the cap exists to survive, not a
    # contrived one, and it is the only state in which either sentence takes its singular. Both
    # clauses are pinned in one example because one window renders both: the caveat under the zero,
    # and the disclosure on the basis line.
    # @intent: {"entity": "SpecObservation", "action": "keep clauses singular", "behavior": "with exactly one unexamined description both clauses take the singular \u2014 the other 1 description was never compared and the other 1 is not represented above \u2014 with no plural forms", "layer": "request"}
    it "keeps both truncation clauses grammatical where exactly one description went unexamined" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(uniformly_red_window(5, candidates: 6))

      expect(none_state).to have_text("The other 1 description that failed in this window was " \
                                      "never compared across runs, so nothing here is a finding " \
                                      "about it", normalize_ws: true)
      expect(basis_line).to have_text("the other 1 is not represented above", normalize_ws: true)
      expect(none_state).to have_no_text("description that failed in this window were never")
      expect(basis_line).to have_no_text("the other 1 are not represented above")
    end

    # The other zero branch is a universal too — "NO description ... changed its outcome" — and is
    # reachable under the cap by the same route. Seven descriptions that fail in both runs, plus a
    # description carried by two examples per run which varies: it failed once, so the
    # fewest-failures-first ordering keeps it, and every examined candidate beside it is uniformly
    # red. The shared-description section renders, the flip list is empty, and the zero above them
    # both is a claim about five of eight candidates.
    def truncated_shared_description_window(limit)
      repository = create_repository(user: @user)
      2.times do |run_index|
        specs = (0..(limit + 1)).map do |i|
          example_spec(name: "candidate #{format("%04d", i)}", outcome: "failed", line_number: i + 1)
        end
        specs << example_spec(name: "Invoice finalize locks the line items", line_number: 90,
                              outcome: run_index.zero? ? "failed" : "passed")
        specs << example_spec(name: "Invoice finalize locks the line items", line_number: 91,
                              outcome: "passed")
        ingest(repository, specs, commit_sha: "run#{format("%010d", run_index)}",
                                  at: (30 - run_index).days.ago)
      end
      repository
    end

    # @intent: {"entity": "SpecObservation", "action": "qualify shared zero by cap", "behavior": "under the cap the shared-description zero reads among the 5 of 8 failing descriptions compared across the 2 runs and names the other 3 as never compared", "layer": "request"}
    it "qualifies the shared-description zero by the candidates it compared as well" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(truncated_shared_description_window(5))

      expect(rows).to be_empty
      expect(section?("unstable-tests-shared")).to be(true)
      expect(none_state).to have_text("No description belonging to a single example changed its " \
                                      "outcome among the 5 of 8 failing descriptions this panel " \
                                      "compared across the 2 runs on main that reported outcomes",
                                      normalize_ws: true)
      expect(none_state).to have_text("The other 3 descriptions that failed in this window were " \
                                      "never compared across runs", normalize_ws: true)
    end

    # And says none of that where the cap did not bite — the qualification is a disclosure, not a
    # hedge the panel wears permanently. What carries that here is the POSITIVE expectation: the
    # unqualified wording is a whole branch of `#unstable_tests_none_description`, so a branch
    # order that took the truncated wording unconditionally reddens on this full text (checked by
    # mutation — it reddens here and at :129 and :330, and nowhere else).
    #
    # The `have_no_text` below it is not a mutation guard, and this comment previously claimed
    # otherwise. This fixture has no shared-description rows, so `#unstable_tests_examined_scope`
    # is never called on this path at all — the guard for a scope that qualified every zero
    # unconditionally is the full-text expectation on "across the 3 runs on main" at :442, which is
    # the only example that reddens for it. `#unstable_tests_unexamined_caveat` is not reached on
    # this path either: the unqualified branch does not call it. The assertion below is a forward
    # guard on the rendered text rather than on the method — it reddens if a later change routes a
    # window the cap did not bite through a branch that appends the caveat.
    # @intent: {"entity": "SpecObservation", "action": "leave zero unqualified", "behavior": "where the cap did not bite the zero keeps its plain 1-description wording and never says nothing here is a finding about them", "layer": "request"}
    it "leaves both zeroes unqualified where every failing description was examined" do
      get repository_path(repository_with(%w[failed failed]))

      expect(none_state).to have_text("1 description failed somewhere in the 2 runs on main that " \
                                      "reported outcomes, and not one of them reported any other " \
                                      "outcome", normalize_ws: true)
      expect(none_state).to have_no_text("nothing here is a finding about them")
    end

    # The disclosure appears only when the cap actually bit.
    # @intent: {"entity": "SpecObservation", "action": "omit cap disclosure", "behavior": "an uncapped window's basis never says not represented above", "layer": "request"}
    it "discloses nothing where every failing description was examined" do
      get repository_path(repository_with(%w[passed failed]))

      expect(basis_line).to have_no_text("not represented above")
    end
  end

  # Criterion 8, the half only a page can show: the panel's cost does not follow the length of the
  # window or the size of the suite. The plans those queries are actually resolved by — index
  # scans, never a sequential scan of every run's rows — are pinned around the model calls
  # themselves in spec/models/spec_observation_spec.rb, for the reason
  # spec/requests/repository_suite_trajectory_spec.rb gives about its own budget examples: a render
  # against a render has a control walking the same code path.
  describe "what the panel costs the page" do
    # `queries_against` comes from spec/support/query_capture.rb.

    # An ABSOLUTE count, not a difference against a control. Thirteen reads of this table serve this
    # page in the state that costs the most: two for the "Slowest tests" panel, one for "Heaviest
    # spec files", one for "Heaviest spec directories", two for "Descriptions this run recorded more
    # than once", one for "Areas that grew or shrank", one for "Areas that got slower or faster",
    # one for "Areas that grew or shrank over the window", and four for this one — the gating probe,
    # the candidate narrowing, the composition of those candidates, and the unnamed-row count. Nine
    # of those thirteen belong to panels this slice did not write; what this example pins for THIS
    # panel is the four, and that they stay four. Equality against a smaller fixture alone would
    # still hold if both pages regressed to a fixed-but-wasteful number of passes over the same
    # table.
    #
    # The sixth neighbour is a two-run by-AREA comparison ranked by summed duration, the sibling of
    # the count comparison beside it: an area where an existing spec got slower gains no examples,
    # so it sorts last on that panel and off its cap, which is why the two are separate reads rather
    # than one widened one. Its own budget is pinned in
    # spec/requests/repository_spec_directory_runtime_growth_spec.rb — including that it asks
    # nothing at all where the two runs cannot be compared.
    #
    # The seventh is that count comparison asked of THIS panel's window instead of the last push:
    # the newest run against the oldest one in the window that can be compared with it. One further
    # read, constant in the length of the window because it is still two run ids — the window itself
    # is handed to it already loaded, the same rows this panel is drawn on. Its own budget, and that
    # it asks nothing where the window has no baseline, are pinned in
    # spec/requests/repository_spec_directory_window_growth_spec.rb. Both fixtures below hold more
    # than two runs on the branch, so that read names a different pair from the last-push one and is
    # a real round trip on each of them rather than a query-cache repeat.
    #
    # RECOUNTED AT 14 by SPGD-649, which added the by-area annotation panel: ONE
    # further read of this table, the same run's rows grouped by AREA on the ANNOTATION axis. It is
    # the eighth neighbour, and it is the one the enumeration above does not carry — that sentence
    # is left at thirteen because thirteen is what it correctly said at its own moment, and this
    # line is where the fourteenth is accounted for. Restated at the new total: TEN of the fourteen
    # belong to panels this slice did not write, and the four this example pins for THIS panel are
    # unchanged, which is the half the assertion is here to hold still. The added read moves with
    # neither the length of the window nor how red it went, since it reads the latest run's rows
    # only, and it is not the by-duration rollup counted above under another name: that one groups
    # the identical population and ranks it by wall clock, so neither ranking can be read off the
    # other. Its own budget is pinned in
    # spec/requests/repository_unannotated_directories_spec.rb.
    # RECOUNTED AT 15 by SPGD-728, which added the "Slowest tests across the window" panel: ONE
    # further read of this table, and it is that panel's GATING PROBE — the row count and the
    # unresolved-row count over the newest run of THIS SAME WINDOW, asked before either of the two
    # steps behind it. It is the ninth neighbour, and it is the only one of them drawn on this
    # panel's own window rather than on the latest run alone.
    #
    # ONE and not three, and the reason is worth being exact about because it is a property of the
    # fixtures rather than of the panel. Nothing in this file runs `Ingest::IdentityResolver` — the
    # job the ingest endpoint enqueues after answering `202` — so every row these fixtures write
    # carries a NULL `spec_identity_id`, the gate reports nothing resolved, and the panel stops
    # there and says so rather than rendering an empty ranking. A window whose runs HAVE been
    # resolved pays three: the gate, a capped candidate step over the newest run, and a composition
    # over those candidates only. Both figures are asserted in
    # spec/requests/repository_window_slowest_tests_spec.rb.
    #
    # Restated at the new total: ELEVEN of the fifteen belong to panels this slice did not write,
    # and the four this example pins for THIS panel are unchanged, which is the half the assertion
    # is here to hold still. The added read moves with neither the length of the window nor the
    # size of the suite, since it counts one run's rows.
    # @intent: {"entity": "SpecObservation", "action": "constant reads by scale", "behavior": "spec_observations reads total 19 on both a 3-run 3-example and a 30-run 200-example window, with the panel populated at 4 rows", "layer": "request"}
    it "costs the same four reads at 30 runs of 200 examples as at 3 runs of 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      3.times do |index|
        specs = (1..3).map do |i|
          example_spec(name: "small #{i}", line_number: i,
                       outcome: i == 1 && index == 1 ? "failed" : "passed")
        end
        ingest(small, specs, commit_sha: "small#{format("%09d", index)}", at: (30 - index).days.ago)
      end
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      30.times do |index|
        specs = (1..200).map do |i|
          example_spec(name: "large #{i}", line_number: i,
                       outcome: (i % 50).zero? && index.even? ? "failed" : "passed",
                       id: "./spec/models/large_spec.rb[1:#{i}]")
        end
        ingest(large, specs, commit_sha: "large#{format("%09d", index)}", at: (30 - index).days.ago)
      end

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      # The large page really is rendering the panel populated — an equal count over two empty
      # panels would be equal and worthless.
      expect(rows.size).to eq(4)
      expect(large_queries.size).to eq(small_queries.size)
      # RECOUNTED AT 16 by SPGD-711, which added the run's INTENT READINGS: ONE further read of
      # this table, an ungated aggregate over the same run's rows splitting them into authored,
      # derived and unreadable. It is not the by-area annotation read counted above under another
      # name — that one GROUPS and ranks, this one does neither, and it answers the Overview's own
      # sentence rather than a panel's list. Ungated unlike every drill-in on this page, because a
      # correction a client has to opt into leaves the Overview printing the subtraction it replaced.
      # Its own budget is asserted in spec/requests/api/v1/repository_intent_readings_spec.rb.
      #
      # RECOUNTED AT 19 by SPGD-758, for three reads at once: THIS panel's grouping moved to the
      # durable identity, so its fixtures now resolve inline (an unresolved row is an exclusion
      # rather than a key) and it pays a FIFTH read — the window's unresolved-row exclusion count,
      # `SpecObservation.unresolved_row_count_in` — beside the unnamed count it already paid; and
      # the slowest-tests panel over the same window, whose fixtures were already resolved by that
      # change, now passes its own gate and pays its candidate and composition reads instead of
      # stopping at it. Five for this panel, four for that one, none growing with window or suite.
      expect(large_queries.size).to eq(19)
    end

    # The candidate narrowing is what makes the composition affordable, and its `IN` list is capped
    # — so the number of round trips cannot follow how red the suite went either.
    # @intent: {"entity": "SpecObservation", "action": "constant reads when red", "behavior": "an all-red 4-run 300-example window still costs exactly 19 spec_observations reads", "layer": "request"}
    it "costs the same reads on a window where every test failed in every run" do
      repository = create_repository(user: @user)
      4.times do |index|
        specs = (1..300).map do |i|
          example_spec(name: "red #{i}", outcome: i.even? || index.zero? ? "failed" : "passed",
                       line_number: i, id: "./spec/models/red_spec.rb[1:#{i}]")
        end
        ingest(repository, specs, commit_sha: "red#{format("%011d", index)}", at: (30 - index).days.ago)
      end

      expect(queries_against("spec_observations") { get repository_path(repository) }.size).to eq(19)
    end

    # The gate is what it says it is: a window that cannot be compared asks nothing past the probe
    # that established it, so the state that says the least also costs the least.
    # @intent: {"entity": "SpecObservation", "action": "gate before grouping", "behavior": "an incomparable window costs 15 reads and none of them is the outcome-narrowed window grouping over test_run_id IN", "layer": "request"}
    it "asks nothing past the gating probe on a window that cannot be compared" do
      repository = repository_with([nil, nil, nil])

      queries = queries_against("spec_observations") { get repository_path(repository) }

      # ELEVEN of these belong to the panels above, which read the latest run (and, for the three
      # by-area comparisons, an earlier one) regardless — the tenth being the single-run annotation
      # rollup SPGD-649 added, which reads the latest run whatever the window says; the eleventh is
      # this panel's gating probe. The window comparison is among the ten and not among what the
      # gate withholds: its own gate is about SIZES and is satisfied here, where this panel's is
      # about OUTCOMES and is not — two windows of the same runs, two different questions to refuse.
      #
      # The TWELFTH is SPGD-728's, and it is a THIRD gate over this same window asked about a third
      # thing: whether the newest run's rows have been matched to durable tests yet. It withholds
      # its own two steps here for its own reason — these fixtures never run the resolver, so
      # nothing is matched — which is why one further read is all it adds. Three panels drawn on one
      # window, each asking one cheap question first and each refusing a different thing, is the
      # shape this example exists to hold: what must not appear is a FOURTH read taken before any
      # gate said yes.
      #
      # The THIRTEENTH is SPGD-711's intent readings, and it is NOT a fourth gate — it is the
      # Overview's own aggregate over the latest run, asked unconditionally because a correction a
      # client has to opt into leaves the Overview printing the subtraction it replaced. It belongs
      # with the eleven above rather than with the two gates: it reads the latest run whatever the
      # window says, and it withholds nothing because there is nothing behind it to withhold.
      #
      # THE FOURTEENTH AND FIFTEENTH are SPGD-758's fixtures resolving inline, which the identity
      # grouping requires: the slowest-tests panel over the same window now passes its own resolver
      # gate and pays its candidate and composition reads where these fixtures used to stop it at
      # the gate. They are that panel's reads on this page and not this one's — this panel still
      # asks nothing past its own probe on an incomparable window.
      expect(queries.size).to eq(15)
      # What the gate withholds is THIS panel's outcome-narrowed grouping over the WINDOW — the
      # candidate narrowing (`test_run_id IN` + `outcome = 'failed'`, grouped on the identity) and
      # the composition that follows it. The window-narrowed identity groupings that ARE on the
      # page belong to the slowest-tests panel, whose own gate these fixtures now pass (SPGD-758's
      # fixtures resolve inline), and the single-run `GROUP BY name` belongs to the "Descriptions
      # this run recorded more than once" panel — neither is something an incomparable window has
      # any reason to withhold. Discriminated on the outcome narrow rather than on the grouping
      # alone, because the grouping alone is shared by three panels on this page.
      expect(
        queries.none? do |sql|
          sql.include?("GROUP BY") && sql.include?(%(test_run_id" IN)) && sql.include?("outcome")
        end
      ).to be(true)
    end
  end

  # `UI::*` components and `app-*` tokens only. The lint's own no-drift guard is project-wide and
  # already lives in spec/lib/spec_guard/design_system_lint_spec.rb — a second copy of it here would
  # be one more thing to keep in step and would say nothing about THIS panel. What that guard cannot
  # see is markup that avoids every banned pattern while still hand-rolling something the component
  # library already renders, so what is asserted here is that the badges came from the component.
  # @intent: {"entity": "SpecObservation", "action": "use badge component", "behavior": "the failed word renders inside the rounded-full text-xs badge span carrying the bg-app-error-surface class", "layer": "request"}
  it "renders its outcome words through the badge component rather than by hand" do
    get repository_path(repository_with(%w[passed failed]))

    expect(panel).to have_css("span.rounded-full.text-xs.font-semibold", text: "failed")
    expect(panel).to have_css("span.bg-app-error-surface", text: "failed")
  end

  # Read-only suite telemetry, outside the `keys.manage` gate — the same class of information as
  # the panels above it. Nothing here is credential metadata and nothing here actions anything.
  # @intent: {"entity": "SpecObservation", "action": "serve view-only member", "behavior": "a member whose only permission is view sees the panel listing the outcome-changing test", "layer": "request"}
  it "is visible to a member with only 'view'" do
    owner_repository = repository_with(%w[passed failed])
    member = create_user(github_uid: "2002", github_handle: "member")
    create_membership(repository: owner_repository, user: member)

    sign_in_via_github(uid: "2002", nickname: "member")
    get repository_path(owner_repository)

    expect(panel?).to be(true)
    expect(row_names).to eq(["Invoice finalize locks the line items"])
  end
end
