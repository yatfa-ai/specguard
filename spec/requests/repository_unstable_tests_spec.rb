# frozen_string_literal: true

require "rails_helper"

# The "Tests whose outcome changed" panel on repositories#show — the first read this application
# makes of `spec_observations` ACROSS runs, and the first answer it gives about a test's HISTORY
# rather than about one run of it.
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
    it "leaves out the test that reported the same outcome in every run" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      expect(row_names).not_to include("User signs in")
    end

    # A test that failed in EVERY run of the window is broken, not unstable. The panel's own words
    # for its scope, and the reason the candidate ordering sheds this end of the list first.
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
    it "states the window every figure was drawn from" do
      repository = repository_with(%w[passed failed passed])

      get repository_path(repository)

      expect(basis_line).to have_text("Across the last 3 runs on main, every one of which reported " \
                                      "an outcome for at least one example", normalize_ws: true)
    end

    # The matching rule is the one DECISION on this panel rather than a measurement, and a reader
    # cannot check the list against their own repository without it.
    it "states the rule the tests were matched by" do
      repository = repository_with(%w[passed failed])

      get repository_path(repository)

      expect(basis_line).to have_text("matched across those runs by their description alone",
                                      normalize_ws: true)
      expect(basis_line).to have_text("a renamed test starts a new one", normalize_ws: true)
    end

    # Where the panel stops looking, said rather than left to be discovered. The search begins at
    # the runs' failures, so variance that never involved one is out of scope.
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
    it "does not report a test that alternated between outcomes without ever failing" do
      repository = repository_with(%w[passed pending passed pending])

      get repository_path(repository)

      expect(rows).to be_empty
      expect(none_state).to have_text("No example failed in any of the 4 runs", normalize_ws: true)
    end

    # The words are echoed, never reworded and never folded into a verdict — nothing platform-side
    # validates this string, so quoting what arrived is the only reading that cannot be wrong.
    it "echoes an outcome word it does not recognise rather than reading it as a pass" do
      repository = repository_with(%w[failed flaked])

      get repository_path(repository)

      expect(rows.first[:outcomes]).to eq(%w[failed flaked])
      expect(panel).to have_css(".text-app-content-secondary", text: "flaked")
    end

    # Silence inside a population that reported is not a pass and is not covered by the words
    # beside it. It wears `SpecObservation#outcome_label`'s own vocabulary for that reason.
    it "counts the runs that recorded the test and said nothing, as silence rather than as a pass" do
      repository = repository_with(["failed", "passed", nil, nil])

      get repository_path(repository)

      expect(rows.first[:outcomes]).to eq(["failed", "passed", "not reported ×2"])
    end
  end

  # Criterion 2 — the Vacuous Green refusal. `outcome` is nullable, so a window whose client sends
  # none produces exactly the empty list a perfectly stable window does.
  describe "a window in which fewer than two runs reported an outcome" do
    it "says the comparison cannot be made, over a window that reported nothing at all" do
      repository = repository_with([nil, nil, nil])

      get repository_path(repository)

      expect(incomparable).to have_text("at least two runs that reported them", normalize_ws: true)
      expect(incomparable).to have_text("Of the 3 runs on main, not one of them said how any " \
                                        "example ended", normalize_ws: true)
    end

    it "says it again over a window where exactly one run reported" do
      repository = repository_with([nil, "failed", nil])

      get repository_path(repository)

      expect(incomparable).to have_text("Of the 3 runs on main, one of them said how an example " \
                                        "ended", normalize_ws: true)
    end

    # The whole point of the clause: no zero, and no empty list wearing the shape of a result. The
    # honest zero and the basis paragraph are BOTH withheld, because both are claims about a
    # comparison that did not happen.
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
    it "says it over a single run that reported everything" do
      repository = repository_with(%w[failed])

      get repository_path(repository)

      expect(incomparable).to have_text("one run's outcome cannot have changed from anything",
                                        normalize_ws: true)
    end

    # A window with no per-example rows at all is not this state — it is a repository with no
    # cross-run test history to discuss, and the panel stays off rather than explaining itself.
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
    it "words the zero against the runs that reported, where nothing failed at all" do
      repository = repository_with(%w[passed passed passed])

      get repository_path(repository)

      expect(none_state).to have_text("No example failed in any of the 3 runs on main that " \
                                      "reported outcomes", normalize_ws: true)
      expect(none_state).to have_text("That is a comparison this window supported", normalize_ws: true)
    end

    # A different fact from "nothing failed", and one a reader with a permanently red test needs
    # said differently: things failed, and they always failed.
    it "words it differently where things failed and always failed" do
      repository = repository_with(%w[failed failed])

      get repository_path(repository)

      expect(none_state).to have_text("1 description failed somewhere in the 2 runs on main that " \
                                      "reported outcomes, and not one of them reported any other " \
                                      "outcome anywhere in them", normalize_ws: true)
    end

    # The zero is only ever a zero of the population it counted, so the window sentence is rendered
    # over it exactly as it is over a populated list.
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
    it "never pools the unnamed rows into one test of their own" do
      get repository_path(unnamed_window)

      expect(rows.size).to eq(1)
      expect(basis_line).to have_no_text("3 tests")
    end

    # The clause is about THIS window and appears only when there is something to say. "0 rows
    # carried no description" is a sentence about arithmetic.
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

    it "reports it as two examples sharing a description, not as an outcome change" do
      get repository_path(shared_description_window)

      expect(row_names).not_to include("Order total sums the lines")
      expect(shared_section).to have_text("Order total sums the lines", normalize_ws: true)
      expect(shared_section).to have_text("6 examples under this description across 3 of 3 runs",
                                          normalize_ws: true)
    end

    it "says why the matching rule could not rule on it" do
      get repository_path(shared_description_window)

      expect(shared_section).to have_text("A description is not a key within a single run",
                                          normalize_ws: true)
      expect(shared_section).to have_text("calling them flaky would be a false positive " \
                                          "manufactured by the matching rule", normalize_ws: true)
    end

    # Not silently dropped either. A dropped group is a silence the reader has no way to notice —
    # the mutation that turns this example red is deleting the section rather than the label.
    it "does not leave the window looking like an honest zero" do
      get repository_path(shared_description_window)

      expect(section?("unstable-tests-shared")).to be(true)
      expect(shared_section).to have_text("1 description varied in outcome across this window",
                                          normalize_ws: true)
    end

    # The zero directly above the section has to be worded against it. "Not one of them reported
    # any other outcome" is FALSE over this window — its shared description reported two — and it
    # would be printed inches above the section saying so.
    it "words the zero above it against what the section reports, rather than contradicting it" do
      get repository_path(shared_description_window)

      expect(none_state).to have_text("No description belonging to a single example changed its " \
                                      "outcome across the 3 runs on main that reported outcomes",
                                      normalize_ws: true)
      expect(none_state).to have_no_text("not one of them reported any other outcome")
    end

    # The section is a disclosure, not a fixture of the page: a window with no ambiguous group
    # renders none of it.
    it "renders no such section where every description was one example per run" do
      get repository_path(repository_with(%w[passed failed]))

      expect(section?("unstable-tests-shared")).to be(false)
    end
  end

  # Criterion 6 — per the project's semantic-identity rule a test that MOVED is the same test and
  # keeps its history, so a group spanning two files is a disclosure rather than an error.
  describe "a test recorded under more than one spec file" do
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

    it "discloses that it examined only part of what failed, and which part" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(truncated_window(5))

      expect(basis_line).to have_text("7 descriptions failed somewhere in this window",
                                      normalize_ws: true)
      expect(basis_line).to have_text("the 5 that failed fewest times were the ones compared " \
                                      "across runs", normalize_ws: true)
      expect(basis_line).to have_text("the other 2 are not represented above", normalize_ws: true)
    end

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
    def uniformly_red_window(limit)
      repository = create_repository(user: @user)
      2.times do |run_index|
        specs = (0..(limit + 1)).map do |i|
          example_spec(name: "candidate #{format("%04d", i)}", outcome: "failed", line_number: i + 1)
        end
        ingest(repository, specs, commit_sha: "run#{format("%010d", run_index)}",
                                  at: (30 - run_index).days.ago)
      end
      repository
    end

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
    it "says of the descriptions it never examined that nothing here is a finding about them" do
      stub_const("SpecObservation::UNSTABLE_CANDIDATE_LIMIT", 5)

      get repository_path(uniformly_red_window(5))

      expect(none_state).to have_text("The other 2 descriptions that failed in this window were " \
                                      "never compared across runs, so nothing here is a finding " \
                                      "about them", normalize_ws: true)
      expect(none_state).to have_no_text("7 descriptions failed somewhere in the")
      expect(none_state).to have_no_text("not one of them reported any other outcome")
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
    # hedge the panel wears permanently. `have_no_text("among the")` is what reddens on a branch
    # that stopped consulting `#truncated?` and qualified every zero unconditionally.
    it "leaves both zeroes unqualified where every failing description was examined" do
      get repository_path(repository_with(%w[failed failed]))

      expect(none_state).to have_text("1 description failed somewhere in the 2 runs on main that " \
                                      "reported outcomes, and not one of them reported any other " \
                                      "outcome", normalize_ws: true)
      expect(none_state).to have_no_text("nothing here is a finding about them")
    end

    # The disclosure appears only when the cap actually bit.
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

    # An ABSOLUTE count, not a difference against a control. Seven reads of this table serve this
    # page in the state that costs the most: two for the "Slowest tests" panel, one for "Heaviest
    # spec files", and four for this one — the gating probe, the candidate narrowing, the
    # composition of those candidates, and the unnamed-row count. Equality against a smaller
    # fixture alone would still hold if both pages regressed to a fixed-but-wasteful number of
    # passes over the same table.
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
      expect(large_queries.size).to eq(7)
    end

    # The candidate narrowing is what makes the composition affordable, and its `IN` list is capped
    # — so the number of round trips cannot follow how red the suite went either.
    it "costs the same reads on a window where every test failed in every run" do
      repository = create_repository(user: @user)
      4.times do |index|
        specs = (1..300).map do |i|
          example_spec(name: "red #{i}", outcome: i.even? || index.zero? ? "failed" : "passed",
                       line_number: i, id: "./spec/models/red_spec.rb[1:#{i}]")
        end
        ingest(repository, specs, commit_sha: "red#{format("%011d", index)}", at: (30 - index).days.ago)
      end

      expect(queries_against("spec_observations") { get repository_path(repository) }.size).to eq(7)
    end

    # The gate is what it says it is: a window that cannot be compared asks nothing past the probe
    # that established it, so the state that says the least also costs the least.
    it "asks nothing past the gating probe on a window that cannot be compared" do
      repository = repository_with([nil, nil, nil])

      queries = queries_against("spec_observations") { get repository_path(repository) }

      # Three of these belong to the panels above, which read the latest run regardless; the fourth
      # is this panel's gating probe, and there is no fifth.
      expect(queries.size).to eq(4)
      expect(queries.none? { |sql| sql.include?("GROUP BY") && sql.include?("name") }).to be(true)
    end
  end

  # `UI::*` components and `app-*` tokens only. The lint's own no-drift guard is project-wide and
  # already lives in spec/lib/spec_guard/design_system_lint_spec.rb — a second copy of it here would
  # be one more thing to keep in step and would say nothing about THIS panel. What that guard cannot
  # see is markup that avoids every banned pattern while still hand-rolling something the component
  # library already renders, so what is asserted here is that the badges came from the component.
  it "renders its outcome words through the badge component rather than by hand" do
    get repository_path(repository_with(%w[passed failed]))

    expect(panel).to have_css("span.rounded-full.text-xs.font-semibold", text: "failed")
    expect(panel).to have_css("span.bg-app-error-surface", text: "failed")
  end

  # Read-only suite telemetry, outside the `keys.manage` gate — the same class of information as
  # the panels above it. Nothing here is credential metadata and nothing here actions anything.
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
