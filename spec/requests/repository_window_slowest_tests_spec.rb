# frozen_string_literal: true

require "rails_helper"

# The "Slowest tests across the window" panel on repositories#show — the first surface in this
# application to rank anything by `spec_identity_id`, and therefore the first one on which A TEST
# THAT MOVED KEEPS ITS RUNTIME HISTORY.
#
# Its own file, and deliberately not an addition to spec/requests/repository_slowest_examples_spec.rb
# ("Repository slowest tests", the PER-RUN panel). The two panels sit on the same page and answer
# different questions at different grains, and every example here needs a multi-run fixture that
# file has no use for — the same split spec/requests/repository_unstable_tests_spec.rb makes
# against the same neighbour for the same reason.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` and matched to
# durable tests by `Ingest::IdentityResolver`, rather than inserted by hand with an identity already
# attached. Every state this panel turns on is one the real pipeline produces: an unresolved row is
# a run the resolver has not reached yet, a signalless row is a producer that sends no description,
# a moved test is the same name under a new path, and a reworded test is an ANNOTATED example whose
# identity is anchored on its declared intent while its `full_description` changed under it. A
# fixture that wrote `spec_identity_id` itself would be asserting against a shape nothing in
# production writes, and — worse on this panel specifically — would make the two states that must
# never be confused (`:unresolved` and an honest ranking) unreachable.
RSpec.describe "Repository window slowest tests", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#slowest-tests-window")

  def panel? = Capybara.string(response.body).has_css?("#slowest-tests-window")

  # ELEMENT-scoped, never panel-scoped. The caption, the unresolved state and the unrecorded state
  # share most of their words — "run", "durable test", the branch name — so a panel-level
  # `have_text` passes for the wrong state with the deciding branch deleted.
  def basis_line = panel.find("#slowest-tests-window-basis")

  def unresolved_state = panel.find("#slowest-tests-window-unresolved")

  def unrecorded_state = panel.find("#slowest-tests-window-unrecorded")

  def section?(id) = panel.has_css?("##{id}")

  # The row's LABEL: the test cell's text with its notes stripped off from the LAST one backwards,
  # which is the order the partial nests them in — the file line is always the final span of the
  # cell, and a reword note sits above it only where there was one. Whitespace-collapsed, because a
  # description and a note assembled across two ERB tags are two readings on the page whatever the
  # source did with indentation.
  #
  # ONE definition, read by both `rows` (which pairs the label with the row's TEXT) and
  # `row_element` (which pairs it with the row ELEMENT). It is deliberately not inlined at either
  # site: the reverse-order suffix-stripping is coupled to how the partial nests its spans, so two
  # copies would be two places that must be edited together the next time that nesting moves.
  def label_of(test_cell)
    notes = test_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }
    notes.reverse.reduce(test_cell.text.gsub(/\s+/, " ").strip) do |label, note|
      label.delete_suffix(note).strip
    end
  end

  # One row as a reader meets it: the description, the notes under it (a reword, and the file or
  # files it ran in), its window total, its single worst run, how much of the window it was seen in
  # and how much of its own history was timed.
  def rows
    panel.all("tbody tr").map do |row|
      test_cell, total_cell, slowest_cell, seen_cell, timed_cell = row.all("td")
      notes = test_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }

      { name: label_of(test_cell), notes: notes, total: total_cell.text.strip,
        slowest: slowest_cell.text.strip, seen: seen_cell.text.gsub(/\s+/, " ").strip,
        timed: timed_cell.text.strip }
    end
  end

  def row_names = rows.map { |row| row[:name] }

  def row_named(name) = rows.find { |row| row[:name] == name }

  # The same label `rows` computes, but paired with the ROW ELEMENT rather than with its text. The
  # file line carries drill-in links now, and an assertion about a link has to reach the anchor
  # itself — a text-only view of the cell renders `<a href=…>path</a>` and `path` identically, which
  # is the one distinction the examples below exist to make.
  def row_element(name)
    panel.all("tbody tr").find { |row| label_of(row.all("td").first) == name }
  end

  # The file line of one row, as an element. It is the LAST span of the test cell, which is where
  # the partial nests it and the same nesting `rows` reads its notes off.
  def file_line(name) = row_element(name).all("td").first.all("span").last

  def file_links(name) = file_line(name).all("a")

  def file_hrefs(name) = file_links(name).map { |link| link[:href] }

  # The BASE-CASE spelling of the drill-in for `path` — what the link reads as with no other ask
  # open. The point of the link is the ask it SETS, and `?anchor=` puts the reader on the
  # destination panel instead of at the top of a page they were already three rungs into.
  #
  # Deliberately NOT routed through the view's own `drill_down_path`: that helper reads the open
  # asks off controller ivars (`@trajectory_branch_request` and its five siblings), which this
  # spec's binding does not have, so calling it here would build its path from nils and only LOOK
  # coupled to the view. It agrees with the view because these examples open no other ask —
  # carry-through, where the two spellings genuinely diverge, is asserted end-to-end against a real
  # rendered page in spec/requests/repository_drill_down_carry_spec.rb rather than against this.
  def expected_file_href(repository, path, **asks)
    repository_path(repository, spec_file: path, anchor: "spec-file-examples", **asks)
  end

  # One ingested run, through the producer and then through the resolver — the two halves the
  # endpoint runs as a `202` and a job behind it. `resolve: false` is the state the endpoint has
  # answered from and the job has not reached, which is a state this panel has to render.
  def ingest(repository, specs, commit_sha:, branch: "main", at: nil, resolve: true)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: specs.count { |spec| spec[:status] == "annotated" },
        duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    Ingest::IdentityResolver.resolve(run) if resolve
    run
  end

  # One unannotated example on the wire. `name:` and `duration:` are passed at every call site,
  # nils included — an untimed example and one whose producer sends no description are both states
  # this file turns on, and the shared builder substitutes a default for a nil `name:`, so both are
  # merged in rather than passed through.
  def example_spec(name:, duration:, file_path:, line_number: 1, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  # The suite one run of the window reported, at `index`. Four tests, each chosen for one property
  # of the ranking:
  #
  # * a steady test, so there is a head to the list that nothing clever happened to;
  # * ⭐ a MOVED test — same description, a different spec file on either side of the window, which
  #   under any positional key is one history split into two halves and neither of them at its
  #   right place in the list;
  # * ⭐ a REWORDED test — an annotated example whose identity is its declared intent, so the
  #   identity is unchanged while its `full_description` is not. This is the disclosure
  #   "Tests whose outcome changed" structurally cannot make, since grouped on `name` a reword is
  #   two tests there;
  # * an UNTIMED test, so the panel has a row it must render as "not reported" rather than 0.00s.
  def window_specs(index)
    [
      example_spec(name: "Ledger rebuild walks every entry", duration: 3.0,
                   file_path: "spec/models/ledger_spec.rb", line_number: 1),
      example_spec(name: "Checkout rejects an expired card", duration: 1.0, line_number: 2,
                   file_path: index < 2 ? "spec/models/checkout_spec.rb" : "spec/billing/checkout_spec.rb"),
      annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3, duration: 0.5,
                     name: index < 2 ? "Invoice#finalize locks the line items"
                                     : "Invoice#finalize freezes every line"),
      example_spec(name: "Webhook replays a failed delivery", duration: nil,
                   file_path: "spec/models/webhook_spec.rb", line_number: 4)
    ]
  end

  # A repository whose branch window holds `runs` runs of that suite, stamped back in time so the
  # trajectory window this panel shares orders them the way CI produced them rather than by whatever
  # order the fixture inserted them in.
  #
  # ⚠️ The shas differ IN THEIR FIRST SEVEN CHARACTERS, and that is load-bearing rather than
  # cosmetic. The caption names the anchor as `commit_sha.first(7)`, so a fixture whose runs share a
  # seven-character prefix renders the same string whichever run the panel picked — and the one
  # example asserting the ⭐ partition ("the newest run decided WHICH tests are ranked") would pass
  # just as green with the partition inverted to the oldest. `run#{index}sha…` keeps the ordinal
  # inside the abbreviated form, so that assertion can distinguish the anchor from its neighbours
  # and therefore can fail.
  def window_repository(runs: 4, github_full_name: "acme/billing-service", **options)
    repository = create_repository(user: @user, github_full_name: github_full_name)
    runs.times do |index|
      ingest(repository, window_specs(index), commit_sha: "run#{index}sha#{format("%07d", index)}",
                                              at: (30 - index).days.ago, **options)
    end
    repository
  end

  # A window whose anchor ran more tests than the panel ranks at once — the only shape in which
  # `#truncated?` is true, and so the only one in which the cap's clauses and the lead sentence's
  # hedge are rendered at all.
  def capped_repository
    repository = create_repository(user: @user)
    2.times do |index|
      specs = (1..14).map do |i|
        example_spec(name: "Ledger step #{i} settles the balance", duration: i.to_f,
                     file_path: "spec/models/ledger_spec.rb", line_number: i)
      end
      ingest(repository, specs, commit_sha: "cap#{index}sha#{format("%07d", index)}",
                                at: (30 - index).days.ago)
    end
    repository
  end

  # Criterion 1 and criterion 2 together: the panel exists, it is about the WINDOW, and each row
  # states its window total beside its single worst run.
  describe "a branch window whose runs reported per-example timings" do
    it "ranks the window's tests on what they cost across the whole of it, slowest first" do
      get repository_path(window_repository)

      expect(row_names).to eq(["Ledger rebuild walks every entry",
                               "Checkout rejects an expired card",
                               "Invoice#finalize freezes every line",
                               "Webhook replays a failed delivery"])
    end

    # ⭐ The two figures side by side, and the pair is the point: 12 seconds is one twelve-second
    # test or four runs of a three-second one, and a list ordered on the sum alone cannot tell a
    # reader which they are looking at.
    it "states each test's window total beside its single longest run and the window it was seen in" do
      get repository_path(window_repository)

      steady = row_named("Ledger rebuild walks every entry")
      expect(steady[:total]).to eq("12.00s")
      expect(steady[:slowest]).to eq("3.00s")
      expect(steady[:seen]).to eq("4 of 4")
      expect(steady[:timed]).to eq("4 of 4")
    end

    # The row nothing timed reads as unmeasured in BOTH duration columns and sorts last. A zero
    # would be a measurement invented out of silence, and it would make the untimed test the
    # cheapest in the suite rather than the unknown one.
    it "renders a test nothing timed as unreported rather than as a zero" do
      get repository_path(window_repository)

      untimed = rows.last
      expect(untimed[:name]).to eq("Webhook replays a failed delivery")
      expect(untimed[:total]).to eq("not reported")
      expect(untimed[:slowest]).to eq("not reported")
      expect(untimed[:timed]).to eq("0 of 4")
    end

    # A test that ran more than once inside a single run — a table-driven loop, or a shared example
    # group — is one identity and several rows, and that is what separates "slow in four runs" from
    # "run twice in each of two".
    it "says when a test ran more than once inside a run of the window" do
      repository = create_repository(user: @user)
      2.times do |index|
        specs = 3.times.map do |case_index|
          example_spec(name: "Currency converts each supported code", duration: 2.0, line_number: 1,
                       file_path: "spec/models/currency_spec.rb",
                       id: "./spec/models/currency_spec.rb[1:#{case_index}]")
        end
        ingest(repository, specs, commit_sha: "loop#{format("%09d", index)}",
                                  at: (30 - index).days.ago)
      end

      get repository_path(repository)

      row = row_named("Currency converts each supported code")
      expect(row[:total]).to eq("12.00s")
      expect(row[:seen]).to eq("2 of 2 6 rows, so it ran more than once in at least one of them")
    end
  end

  # ⭐ CRITERION 3 — the guarantee this whole read exists for, at the grain a reader meets it.
  describe "a test whose file or description changed inside the window" do
    # Under any positional key this is TWO rows of 2 seconds each, neither at the head of the list.
    # It is one row of 4, and it says where the history it summed came from.
    it "keeps a moved test in one row and names both files it was recorded under" do
      get repository_path(window_repository)

      moved = row_named("Checkout rejects an expired card")
      expect(rows.count { |row| row[:name] == "Checkout rejects an expired card" }).to eq(1)
      expect(moved[:total]).to eq("4.00s")
      expect(moved[:seen]).to eq("4 of 4")
      expect(moved[:notes])
        .to eq(["recorded under spec/billing/checkout_spec.rb and spec/models/checkout_spec.rb"])
    end

    # The same guarantee on the other axis, and the one the outcome panel on this page structurally
    # cannot make. The descriptions come back as a SET, so neither is "the current one" and the row
    # lists the other rather than promoting one and discarding the rest.
    it "keeps a reworded test in one row and names the other description it wore" do
      get repository_path(window_repository)

      reworded = row_named("Invoice#finalize freezes every line")
      expect(reworded[:total]).to eq("2.00s")
      expect(reworded[:seen]).to eq("4 of 4")
      expect(reworded[:notes]).to eq(["also recorded as Invoice#finalize locks the line items",
                                      "spec/models/invoice_spec.rb"])
    end

    # A test that never moved says nothing about moving — the disclosure is about this window, not
    # a decoration every row wears.
    it "says nothing about a move or a reword for a test that did neither" do
      get repository_path(window_repository)

      expect(row_named("Ledger rebuild walks every entry")[:notes])
        .to eq(["spec/models/ledger_spec.rb"])
    end
  end

  # The file line as a DESTINATION rather than as a label. Every row on this panel is an outlier a
  # reader wants to act on, and their next question — is this one test slow, or the whole file —
  # already has a panel on this same page answering it. Until this shipped the row named the file
  # and stopped there, while the per-run panel two panels up linked the identical value.
  #
  # The link is keyed on `spec_file_path`: `SpecObservation.slowest_identity_candidates_in`
  # aggregates that column into `file_paths` and `SpecObservation.in_file` is keyed on it, so the
  # string on screen IS the key the destination consumes. These examples assert the ANCHOR and its
  # href, never the cell's text — the two are indistinguishable in a text-only reading, which is
  # exactly the state this panel was in before.
  describe "following a row's file to the examples in it" do
    it "links the file a test ran in to that file's examples on this page" do
      repository = window_repository

      get repository_path(repository)

      expect(file_links("Ledger rebuild walks every entry").map(&:text))
        .to eq(["spec/models/ledger_spec.rb"])
      expect(file_hrefs("Ledger rebuild walks every entry"))
        .to eq([expected_file_href(repository, "spec/models/ledger_spec.rb")])
    end

    # ⭐ EVERY file of a moved row, not the first one sorted. The moved test is the single
    # disclosure this whole read exists for, and linking only `files_seen.first` would make the
    # half of its history that lives in the other file the half a reader cannot reach — while the
    # row goes on naming it, which reads as an offer.
    it "links every file a moved test was recorded under, not only the first" do
      repository = window_repository

      get repository_path(repository)

      expect(file_links("Checkout rejects an expired card").map(&:text))
        .to eq(["spec/billing/checkout_spec.rb", "spec/models/checkout_spec.rb"])
      expect(file_hrefs("Checkout rejects an expired card"))
        .to eq([expected_file_href(repository, "spec/billing/checkout_spec.rb"),
                expected_file_href(repository, "spec/models/checkout_spec.rb")])
    end

    # ⭐ THE REGRESSION GUARD for the escaping trap this change is built on. `Array#to_sentence`
    # returns a plain String and NOT a SafeBuffer, so joining `link_to` output through it and
    # printing the result renders visible `&lt;a href=…&gt;` — markup a reader sees as text and
    # cannot click. Capybara's `.text` decodes those entities, so a text-only assertion reads the
    # escaped markup as a perfectly ordinary sentence and passes: this one goes at the RAW BODY,
    # which is the only place the two spellings differ.
    it "renders a moved row's links as real anchors rather than as escaped markup" do
      get repository_path(window_repository)

      expect(response.body).to include("spec/billing/checkout_spec.rb</a>")
      expect(response.body).not_to include("&lt;a")
      # And the sentence reading survives the join — the connector is what `to_sentence` was kept
      # for, and `safe_join` has none.
      expect(file_line("Checkout rejects an expired card").text.gsub(/\s+/, " ").strip)
        .to eq("recorded under spec/billing/checkout_spec.rb and spec/models/checkout_spec.rb")
    end

    # `spec_file_path` is NULLABLE and the aggregate is `ARRAY_AGG(…) FILTER (WHERE … IS NOT NULL)`,
    # so a test every row of which reported no file comes back with an EMPTY array rather than a
    # nil. `Ingest::ObservationRecorder` falls back to `file_path`, so neither the producer nor the
    # fixture can write that nil — which is why the column is set directly here. A defensive branch
    # nothing exercises is a branch that gets deleted as dead, and the cell it guards would
    # otherwise offer a link to nowhere.
    it "says the file was not reported rather than linking nowhere where no row carried one" do
      repository = window_repository
      SpecObservation.joins(:test_run)
                     .where(test_runs: { repository_id: repository.id })
                     .where(file_path: "spec/models/webhook_spec.rb")
                     .update_all(spec_file_path: nil)

      get repository_path(repository)

      expect(file_line("Webhook replays a failed delivery").text.strip).to eq("not reported")
      expect(file_line("Webhook replays a failed delivery")).to have_no_css("a")
    end

    # The open file marked as open, so a reader who has already drilled in is told which of the
    # paths in front of them is the one the destination panel below is describing. On a MOVED row
    # this is the only thing separating the two links.
    it "marks the path already open as the current one and leaves its sibling unmarked" do
      repository = window_repository

      get repository_path(repository, spec_file: "spec/models/checkout_spec.rb")

      current = file_links("Checkout rejects an expired card")
                .select { |link| link[:"aria-current"] == "true" }
      expect(current.map(&:text)).to eq(["spec/models/checkout_spec.rb"])
      expect(file_links("Ledger rebuild walks every entry").first[:"aria-current"]).to be_nil
    end

    # ⭐ A file the ANCHOR run never recorded is an ordinary answer, not an error. `files_seen` is
    # aggregated across the WINDOW while the destination is anchored on the newest run, so a moved
    # test's older file is a path the anchor has nothing for by construction — and
    # `SpecFileExamples` says so in its own class comment. The row links it anyway, because the
    # alternative is a moved test navigable on one of its two files, and the destination answers
    # with its named empty state. Not a 500 and not a blank panel.
    it "lands on the destination's named empty state for a file the anchor run did not record" do
      repository = window_repository

      get repository_path(repository)
      older_file = file_hrefs("Checkout rejects an expired card")
                   .find { |href| href.include?(CGI.escape("spec/models/checkout_spec.rb")) }
      get older_file

      expect(response).to have_http_status(:ok)
      destination = Capybara.string(response.body).find("#spec-file-examples")
      expect(destination).to have_text("No examples for this file", normalize_ws: true)
      expect(destination).to have_text("This run recorded no examples in " \
                                       "spec/models/checkout_spec.rb", normalize_ws: true)
    end

    # No link comes out of a state that has no rows. The three non-`:ranked` states render a
    # sentence about why there is no ranking, and a drill-in emitted from one of them would be an
    # offer to open a file the panel has just said it cannot name.
    it "emits no file link from the state where the anchor's rows are not identified yet" do
      get repository_path(window_repository(resolve: false))

      expect(panel.has_css?("tbody tr")).to be(false)
      expect(panel).to have_no_css("a[href*='spec_file=']")
    end

    it "emits no file link from the state where the newest run recorded no per-example detail" do
      repository = create_repository(user: @user)
      ingest(repository, [], commit_sha: "empty000000001", at: 2.days.ago)

      get repository_path(repository)

      expect(section?("slowest-tests-window-unrecorded")).to be(true)
      expect(panel).to have_no_css("a[href*='spec_file=']")
    end
  end

  # ⭐ CRITERION 4 — the four states, and the one that must never read as "nothing is slow".
  describe "the states in which there is no ranking to show" do
    # THE POST-INGEST STATE. The newest run wrote its rows and the resolver has not reached them,
    # which is what every run looks like for the seconds after it lands. Rendered as an empty list
    # this is "nobody has told us which tests these are" wearing the spelling of "everything is
    # fast", and only the wording separates them.
    it "says the window's tests have not been identified yet rather than showing an empty ranking" do
      get repository_path(window_repository(resolve: false))

      expect(panel?).to be(true)
      expect(panel.has_css?("tbody tr")).to be(false)
      expect(unresolved_state)
        .to have_text("has been matched to a durable test yet", normalize_ws: true)
      expect(unresolved_state).to have_text("recorded 4 rows", normalize_ws: true)
      expect(section?("slowest-tests-window-unrecorded")).to be(false)
    end

    # The unresolved state must not be readable as a statement about how fast this suite is — the
    # single sentence the whole four-state split exists for.
    it "does not report the unidentified window as a suite with nothing slow in it" do
      get repository_path(window_repository(resolve: false))

      expect(unresolved_state).to have_text("which is a different fact from a suite in which " \
                                            "nothing is slow", normalize_ws: true)
    end

    # A different absence, and one nothing is going to clear on its own: the newest run reported no
    # per-example detail at all, so there is no per-test grain here to rank at any identity.
    it "says the newest run reported no per-example detail when it wrote no rows" do
      repository = create_repository(user: @user)
      ingest(repository, [], commit_sha: "empty000000001", at: 2.days.ago)

      get repository_path(repository)

      expect(unrecorded_state).to have_text("reported no per-example detail at all", normalize_ws: true)
      expect(section?("slowest-tests-window-unresolved")).to be(false)
      expect(panel.has_css?("tbody tr")).to be(false)
    end

    # The fourth state as a READER meets it. `SlowestTests` names `:no_runs`, but the assignment in
    # `RepositoriesController#show` sits inside `if trajectory_runs.any?`, so a repository with no
    # window renders no panel at all rather than a titled panel explaining itself — and the
    # Overview's "No CI run has reported yet" is this page's one statement of that fact. The branch
    # is still written in the partial, for the reason stated there.
    it "renders no panel at all for a repository with no runs in the window" do
      get repository_path(create_repository(user: @user))

      expect(panel?).to be(false)
    end
  end

  # ⭐ CRITERION 5 — every figure in the caption comes off the object, and the three disclosures
  # that make the list readable are all stated.
  describe "what the caption states about the list" do
    it "names the window, the ordering and the matching rule" do
      get repository_path(window_repository)

      expect(basis_line).to have_text("The 4 tests that cost this suite the most wall clock " \
                                      "across the last 4 runs on main, ordered on that window " \
                                      "TOTAL — not on any single run of it.", normalize_ws: true)
      expect(basis_line).to have_text("matched across those runs by the durable identity",
                                      normalize_ws: true)
      expect(basis_line).to have_text("a test that MOVED keeps its history here, and so does one " \
                                      "that was reworded", normalize_ws: true)
    end

    # ⭐ The partition, which no row can disclose: WHICH tests are here at all was decided by one
    # run, so a test that run did not report is absent however slow it was while it existed.
    it "names the run that decided which tests are ranked" do
      get repository_path(window_repository)

      # `run3sha` is the LAST of the fixture's four runs and the abbreviation of no other one of
      # them, so this fails if the anchor is ever taken from either end of the window but the newest.
      expect(basis_line).to have_text("decided by run3sha, the newest run in this window",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("run0sha")
    end

    # The population the ranking covers, stated as a fraction off `SpecObservation.coverage_fraction`
    # — the seam every one-sided coverage label on this application goes through.
    it "states how much of what the newest run identified carried a timing" do
      get repository_path(window_repository)

      expect(basis_line).to have_text("Ranked over the 3 of 4 rows that run resolved to a durable " \
                                      "test that reported a duration; 1 reported none",
                                      normalize_ws: true)
    end

    # And says so as a completeness where it IS complete, rather than leaving a reader to infer it
    # from two equal numbers.
    it "says the ranking covers everything where every identified row was timed" do
      repository = create_repository(user: @user)
      2.times do |index|
        ingest(repository, [example_spec(name: "Ledger rebuild walks every entry", duration: 3.0,
                                         file_path: "spec/models/ledger_spec.rb")],
               commit_sha: "timed#{format("%09d", index)}", at: (30 - index).days.ago)
      end

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of the 1 row that run resolved to a durable test " \
                                      "reported a duration", normalize_ws: true)
      expect(basis_line).to have_no_text("reported none")
    end

    # Rows the anchor wrote that no test could be matched to — the signalless tail a producer that
    # sends no description leaves behind, which `Ingest::IdentityResolver` never stamps. Excluded
    # from the ranking, so the exclusion is stated: a list drawn from part of a run with nothing
    # saying which part is a claim about a population the reader cannot see.
    it "discloses the anchor's rows that are not matched to any test" do
      repository = create_repository(user: @user)
      2.times do |index|
        ingest(repository,
               [example_spec(name: "Ledger rebuild walks every entry", duration: 3.0,
                             file_path: "spec/models/ledger_spec.rb", line_number: 1),
                example_spec(name: nil, duration: 0.4, file_path: "spec/models/anon_spec.rb",
                             line_number: 2)],
               commit_sha: "anon#{format("%010d", index)}", at: (30 - index).days.ago)
      end

      get repository_path(repository)

      expect(basis_line).to have_text("1 row that run recorded has not been matched to a durable " \
                                      "test yet and is not in this ranking", normalize_ws: true)
    end

    # Nothing is said where nothing was excluded — a clause reading "0 rows carried no durable
    # identity" is a sentence about arithmetic rather than about this window.
    it "says nothing about exclusions where every row was matched and every candidate examined" do
      get repository_path(window_repository)

      expect(basis_line).to have_no_text("not been matched to a durable test yet")
      expect(basis_line).to have_no_text("not represented above")
    end

    # ⭐ The cap, and the SECOND edge it has that no sibling panel does: it bites on each test's
    # duration in the anchor run while the list is then ordered on the window total, so a test that
    # is cheap today and was expensive across the window falls through it.
    it "discloses the cap and the two different orderings it sits between" do
      get repository_path(capped_repository)

      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(basis_line).to have_text("14 durable tests that run resolved — more than this panel " \
                                      "ranks at once — so the 10 slowest OF THOSE were the ones " \
                                      "whose window history was summed, and the other 4 are not " \
                                      "represented above", normalize_ws: true)
      expect(basis_line).to have_text("a test that is cheap today and was expensive across the " \
                                      "window falls through it", normalize_ws: true)
    end

    # And the superlative the cap has withdrawn is withdrawn in the lead sentence too, rather than
    # asserted there and taken back below: under truncation the ordering that CHOSE these rows is
    # the anchor run's, so "The 10 tests that cost this suite the most" is the one thing this list
    # is not.
    it "does not claim the capped list is the window's most expensive tests" do
      get repository_path(capped_repository)

      expect(basis_line).to have_text("10 of the tests that cost this suite the most wall clock " \
                                      "across the last 2 runs on main", normalize_ws: true)
      expect(basis_line).to have_no_text("The 10 tests that cost this suite")
    end

    # ⭐ The one paragraph in which the two exclusion clauses are rendered SIDE BY SIDE, and the
    # reason the truncation clause names its population rather than saying "tests ran in that run".
    # `#candidate_count` is drawn from `.slowest_identity_candidates_in`, which cannot see an
    # unresolved row at all — so the sentence declining to call those rows tests and the sentence
    # counting the anchor's population are talking about numbers that differ by exactly them, and a
    # figure claiming to count everything that RAN would contradict its own neighbour by 2.
    it "counts the anchor's resolved tests, not its rows, where both exclusions apply at once" do
      repository = create_repository(user: @user)
      2.times do |index|
        named = (1..14).map do |i|
          example_spec(name: "Ledger step #{i} settles the balance", duration: i.to_f,
                       file_path: "spec/models/ledger_spec.rb", line_number: i)
        end
        anonymous = (1..2).map do |i|
          example_spec(name: nil, duration: 0.4, file_path: "spec/models/anon_spec.rb",
                       line_number: i)
        end
        ingest(repository, named + anonymous,
               commit_sha: "both#{index}sha#{format("%07d", index)}", at: (30 - index).days.ago)
      end

      get repository_path(repository)

      expect(basis_line).to have_text("2 rows that run recorded have not been matched to a " \
                                      "durable test yet and are not in this ranking",
                                      normalize_ws: true)
      # 14, not the 16 rows the run wrote: the two clauses of one paragraph agree on what an
      # unmatched row is instead of one of them folding it back in as a test.
      expect(basis_line).to have_text("14 durable tests that run resolved — more than this panel " \
                                      "ranks at once", normalize_ws: true)
      expect(basis_line).to have_no_text("16")
      expect(basis_line).to have_no_text("tests ran in that run")
    end
  end

  # ⭐ CRITERION 1's other half. The two panels sit on one page and a reader has to be able to tell
  # which grain each speaks at, so neither the id, the title nor the first sentence may be shared.
  describe "beside the per-run panel it must not be confused with" do
    it "renders both panels, separately identifiable, each naming its own grain" do
      get repository_path(window_repository)

      page = Capybara.string(response.body)
      expect(page).to have_css("#slowest-examples")
      expect(page).to have_css("#slowest-tests-window")
      expect(page.find("#slowest-examples")).to have_text("slowest tests of the run named above",
                                                          normalize_ws: true)
      expect(panel).to have_text("across the last 4 runs on main", normalize_ws: true)
    end

    # The per-run panel is ONE run's ranking and this one is the window's, so the same suite gives
    # them different totals. A page on which both printed the same figures would be a page with one
    # panel rendered twice.
    it "reports the window total here and the single-run duration there for the same test" do
      get repository_path(window_repository)

      per_run = Capybara.string(response.body).find("#slowest-examples").all("tbody tr").first
      expect(per_run.all("td")[1].text.strip).to eq("3.00s")
      expect(row_named("Ledger rebuild walks every entry")[:total]).to eq("12.00s")
    end
  end

  # ⭐ CRITERION 6 — the window is HANDED OVER, not re-queried. `queries_against` comes from
  # spec/support/query_capture.rb.
  describe "what the panel costs the page" do
    # The chart, the outcome panel, the area-movement panel and this one all read the same loaded
    # runs. The trajectory window is ONE statement against `test_runs`, and this example is what
    # would fail if this panel ever fetched "the last thirty runs on this branch" for itself —
    # which is the drift that would let two panels on one page caption different windows.
    #
    # Matched on `shards_recorded`, the correlated subquery `Repository#suite_size_trajectory`
    # primes its points from, rather than on the shape of an ordered `test_runs` read: this page
    # makes several of those (the anchor, "Recent runs", the branch selector), so a loose pattern
    # would count them and could not tell a second window from a neighbour that already existed.
    it "adds no query against test_runs for its own window" do
      repository = window_repository

      window_reads = queries_against("shards_recorded") { get repository_path(repository) }

      expect(window_reads.size).to eq(1)
    end

    # THREE reads at most, and none of them grows with the length of the window or the size of the
    # suite: the gate over one run, the capped candidate step over that same run, and the
    # composition over those candidates only. A thirty-run window of a two-hundred-example suite
    # costs the same as a three-run window of three.
    it "costs the same reads at 30 runs of 200 examples as at 3 runs of 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      3.times do |index|
        specs = (1..3).map do |i|
          example_spec(name: "small #{i}", duration: i.to_f, line_number: i,
                       file_path: "spec/models/small_spec.rb")
        end
        ingest(small, specs, commit_sha: "small#{format("%09d", index)}", at: (30 - index).days.ago)
      end
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      30.times do |index|
        specs = (1..200).map do |i|
          example_spec(name: "large #{i}", duration: i.to_f, line_number: i,
                       file_path: "spec/models/large_spec.rb")
        end
        ingest(large, specs, commit_sha: "large#{format("%09d", index)}", at: (30 - index).days.ago)
      end

      small_queries = queries_against("spec_identity_id") { get repository_path(small) }
      large_queries = queries_against("spec_identity_id") { get repository_path(large) }

      # The large page really is rendering the panel populated — an equal count over two empty
      # panels would be equal and worthless.
      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      expect(large_queries.size).to eq(3)
    end

    # A window whose newest run has nothing to rank asks ONE question and stops — the gate, and
    # neither of the two steps behind it.
    it "asks one question and stops where the newest run recorded nothing" do
      repository = create_repository(user: @user)
      ingest(repository, [], commit_sha: "empty000000001", at: 2.days.ago)

      queries = queries_against("spec_identity_id") { get repository_path(repository) }

      expect(section?("slowest-tests-window-unrecorded")).to be(true)
      expect(queries.size).to eq(1)
    end
  end
end
