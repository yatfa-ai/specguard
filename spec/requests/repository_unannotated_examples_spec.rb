# frozen_string_literal: true

require "rails_helper"

# The "Unannotated tests here" panel on repositories#show — the LAST rung of the annotation-debt
# ladder, and the only route on the dashboard from an area carrying debt to the NAME of one test.
#
# The Overview prints "Not visible to SpecGuard" as `total_specs_count - annotated_specs_count` and
# says *"SpecGuard cannot see the other N tests."* SPGD-649 shipped the ranking above this one,
# which names the AREAS that count is concentrated in. Neither names a test: to act on the panel the
# page had just handed them, an owner had to leave the product for
# `GET /api/v1/repository?unannotated_examples=1&spec_directory=…` with an API key.
#
# Its own file, on the precedent every per-example panel here sets: these fixtures need
# `spec_observations` rows with a MIXED annotation status, and the panels above are edited by
# sibling slices.
#
# The rows are written by `Ingest::RunRecorder` rather than inserted, on this suite's standing rule —
# the `status` this read filters on is what `Ingest::Payload` validated and the recorder wrote, and a
# hand-built row could carry a status no client can send.
#
# FOUR STATES, and telling them apart is most of what this file is for:
#
#   no narrowing asked           -> no panel, and no query (the whole panel is off the page's budget)
#   rows for the narrowing       -> the worklist
#   run wrote rows, none here    -> "Nothing unannotated here"          (a finding, with its caveat)
#   run wrote no per-example rows -> "No per-example detail on this run"  (an absence of data)
#
# The last two are the *Vacuous Green* pair (SPGD-78) at the grain of an empty state: the same empty
# table and opposite news.
RSpec.describe "Repository unannotated examples", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#unannotated-examples")

  def panel? = Capybara.string(response.body).has_css?("#unannotated-examples")

  def directories_panel = Capybara.string(response.body).find("#unannotated-directories")

  # ELEMENT-scoped, never panel-scoped: the caption's two cap branches share most of their words, so
  # a panel-level `have_text` would pass for the wrong branch with the deciding `if` deleted.
  def basis_line = panel.find("#unannotated-examples-basis")

  # One row as a reader meets it: what the test is called, where it is DEFINED, and which spec file
  # RAN it — the last being the column this worklist is ordered by.
  def rows
    panel.all("tbody tr").map do |row|
      cells = row.all("td")

      # `cells[1]` and not `cells.last`: SPGD-711 appended a "What SpecGuard reads" column, so the
      # spec-file column stopped being the last one — and a `.last` read would have gone on passing,
      # silently, against the wrong cell. That column has its own accessor below rather than a fourth
      # key here, because every `eq` in this file compares whole rows.
      { test: row_name(cells.first), defined_at: row_location(cells.first),
        spec_file: cells[1].text.gsub(/\s+/, " ").strip }
    end
  end

  # What SpecGuard reads of each listed example, in order — the derived entity, action and behavior
  # run together, or the sentence that says it read nothing.
  def row_readings
    panel.all("tbody tr").map { |row| row.all("td").last.text.gsub(/\s+/, " ").strip }
  end

  def row_names = rows.map { |row| row[:test] }

  # The example's NAME, without the definition-site line rendered under it. The two share one cell,
  # and the fallback row — a producer that sent no name — has no span at all, so a whole-cell read
  # would make every ordering assertion here an assertion about paths as well.
  def row_name(cell)
    site = cell.all("span").map(&:text).join

    cell.text.sub(site, "").gsub(/\s+/, " ").strip
  end

  def row_location(cell) = cell.all("span").map { |span| span.text.strip }.join

  # The definition-site ANCHOR in a row's first cell — the link this worklist hands the reader their
  # next action through. Exactly one per row on both label branches: a named row wears it on the
  # location line under the name, and a nameless row wears the coordinate AS the name, so a
  # cell-wide `find("a")` finds the same element either way and an example does not have to know
  # which branch built the row.
  def row_links = panel.all("tbody tr").map { |row| row.all("td").first.find("a") }

  def row_hrefs = row_links.map { |link| link[:href] }

  def blob(sha, path, line) = "https://github.com/acme/billing-service/blob/#{sha}/#{path}#L#{line}"

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: specs.count { |spec| spec[:status] == "annotated" },
        duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # Built so no assertion about "this area's unannotated examples" can pass by accident:
  #
  #   - `spec/models` holds three unannotated examples AND one annotated one, so a panel serving the
  #     area's whole population rather than its debt is red.
  #   - `spec/requests` holds an unannotated example of its own, so a panel serving the RUN's debt
  #     rather than the narrowing's is red.
  #   - the three target rows are delivered OUT of read order (refund line 9 after order line 30, and
  #     the shared example group last), so the ordering assertion is about the read.
  #   - one row is a SHARED EXAMPLE GROUP: defined in `spec/support/`, run by `spec/models`. It is
  #     the row that fails a panel pairing `spec_file_path` with `line_number`, and here that failure
  #     sends a reader to annotate a test that is not in the file it names.
  #
  # `let` and deliberately NOT constants, the point spec/requests/repository_spec_file_examples_spec.rb
  # and the API sibling both make in their own words: a constant assigned inside an `RSpec.describe`
  # block opens no constant scope and lands on `Object`, so an `ORDER_SPEC` here and the one in that
  # file are ONE constant reassigned at load — a warning today, and the day the two files want
  # different paths, whichever loaded last silently decides both. Written as constants first here,
  # which is how the warning was seen.
  #
  # `shared_group_file` rather than the `shared_examples` this fixture is a shared example group of:
  # that name is RSpec's own group-level DSL, and a `let` sitting next to it — even though the two
  # live on different objects and cannot collide — is a name a later reader has to check.
  let(:area) { "spec/models" }
  let(:order_spec) { "spec/models/order_spec.rb" }
  let(:refund_spec) { "spec/models/refund_spec.rb" }
  let(:shared_group_file) { "spec/support/shared_examples/billable.rb" }

  def debt_run
    repository = create_repository(user: @user)
    ingest(repository,
           [unannotated_spec(file_path: order_spec, line_number: 30,
                             name: "Order settles the balance"),
            unannotated_spec(file_path: refund_spec, line_number: 9,
                             name: "Refund restores the stock"),
            unannotated_spec(file_path: shared_group_file, spec_file_path: order_spec, line_number: 7,
                             id: "./#{order_spec}[1:7:1]", name: "behaves like a billable charges once"),
            annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
            unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 5,
                             name: "Checkout rejects an empty cart")])
    repository
  end

  describe "an area opened on a run carrying debt" do
    # AC1. The panel's whole claim: the tests SpecGuard cannot see IN THE PLACE THE READER PICKED,
    # by name, with enough on every row to go and open it. Asserted as a SEQUENCE (`eq`, not
    # `match_array`) because the file-navigable order is half of what the list promises — a reader
    # annotating the head and asking again must not be handed a re-shuffled list.
    it "lists the area's unannotated examples by name, with file path and line number" do
      get repository_path(debt_run, spec_directory: area)

      expect(rows).to eq(
        [{ test: "behaves like a billable charges once", defined_at: "#{shared_group_file}:7",
           spec_file: order_spec },
         { test: "Order settles the balance", defined_at: "#{order_spec}:30", spec_file: order_spec },
         { test: "Refund restores the stock", defined_at: "#{refund_spec}:9", spec_file: refund_spec }]
      )
    end

    # The narrowing is the point: the run's OTHER unannotated example is not in this list, and the
    # area's ANNOTATED one is not either. A panel serving the run's whole debt, or the area's whole
    # population, passes neither half.
    it "lists neither the run's debt outside the area nor the area's annotated examples" do
      get repository_path(debt_run, spec_directory: area)

      expect(row_names).not_to include("Checkout rejects an empty cart")
      expect(row_names).not_to include("Invoice finalize locks the line items")
      expect(rows.size).to eq(3)
    end

    # `?spec_file=` is the other narrowing, read by the same object off the same ask this page
    # already carries — so the panel opens one FILE's debt without a parameter of its own.
    it "narrows to one spec file when that is the ask" do
      get repository_path(debt_run, spec_file: refund_spec)

      expect(row_names).to eq(["Refund restores the stock"])
    end

    # Both asks are AND-ed and neither wins: a file outside the area is an honest empty intersection
    # rather than one of the two having been silently dropped. The panel says so where it happens.
    it "intersects the two asks rather than letting one of them win" do
      get repository_path(debt_run, spec_file: "spec/requests/checkout_spec.rb", spec_directory: area)

      expect(panel?).to be(true)
      expect(panel).to have_no_css("tbody tr")
      expect(panel).to have_text("Both asks narrow this list and a row must match each of them",
                                 normalize_ws: true)
    end

    # The same disclosure in the branch that HAS rows — it is a fact about what the read narrowed by,
    # not a claim about the list, so it may not live inside the caption that vanishes with the table.
    # This is the pairing that stops the assertion above from being satisfied by a sentence that only
    # ever appears over an empty one.
    it "says the same about the intersection when the two asks do overlap" do
      get repository_path(debt_run, spec_file: order_spec, spec_directory: area)

      expect(row_names).to eq(["behaves like a billable charges once", "Order settles the balance"])
      expect(panel).to have_text("Both asks narrow this list and a row must match each of them",
                                 normalize_ws: true)
    end

    # And it is said only where both asks are set — a sentence about two narrowings printed over one
    # is a clause about nothing, and it would tell a reader an ask was applied that never was.
    it "says nothing about an intersection when only one ask was made" do
      get repository_path(debt_run, spec_directory: area)

      expect(panel).to have_no_text("Both asks narrow this list")
    end

    # The definition site and the file that RAN the example are two different files on a shared
    # example group, and the row shows both. `spec_file_path` + `line_number` would be a coordinate
    # whose halves come from different files — line 7 of `order_spec.rb` is not this test — and on a
    # worklist that is a reader sent to annotate something that is not there.
    it "pairs the line number with the file the example is DEFINED in" do
      get repository_path(debt_run, spec_directory: area)

      shared = rows.first

      expect(shared[:defined_at]).to eq("#{shared_group_file}:7")
      expect(shared[:spec_file]).to eq(order_spec)
      expect(basis_line).to have_text("a different one for an example a shared example group defines elsewhere",
                                      normalize_ws: true)
    end

    # AC7. OPERANDS ONLY — no fraction, no threshold, no verdict. `UnannotatedExamples` and
    # `UnannotatedDirectories` both state that boundary and it governs this partial too.
    it "shows no percentage, fraction or verdict on a row" do
      get repository_path(debt_run, spec_directory: area)

      expect(panel).to have_no_text("%")
      expect(panel).to have_no_text("3 of 4")
      expect(panel).to have_text("Named and not scored", normalize_ws: true)
    end

    # A list that says nothing about its order is read as ranked, and this one ranks nothing:
    # `SpecObservation.unannotated_in` orders file-navigably and says in full that it is a worklist.
    it "says the list is file-navigable rather than ranked" do
      get repository_path(debt_run, spec_directory: area)

      expect(basis_line).to have_text("in the order you would open them — by spec file, then by line",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("slowest first")
    end

    # The denominator is the rows THIS RUN wrote in this area, never the Overview's suite size —
    # that figure is re-derived by SUM over shard reports, and this list is narrowed on top of it.
    it "counts the narrowed population rather than the run's reported suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 1)],
             total_specs_count: 4_000)

      get repository_path(repository, spec_directory: area)

      expect(basis_line).to have_text("All 1 example this run recorded here without an @intent",
                                      normalize_ws: true)
      expect(panel).to have_no_text("4,000")
      expect(basis_line).to have_text("a different population from the suite size on the Overview panel above",
                                      normalize_ws: true)
    end
  end

  # AC6. The cap, and both sides of the predicate the object refuses to hold. `UnannotatedExamples`
  # has no `truncated?` on purpose — a predicate no surface calls is a claim nothing has ever checked
  # — and its class comment invites the client to write `recorded_count > rows.size` WITH the spec
  # that runs it against a capped AND an uncut read. These two examples are that spec.
  describe "an area holding more debt than the worklist carries" do
    def capped_run
      repository = create_repository(user: @user)
      ingest(repository, (1..(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT + 12)).map do |n|
        unannotated_spec(file_path: "#{area}/model_#{format('%03d', n)}_spec.rb", line_number: n,
                         name: "Model #{n} does its thing")
      end)
      repository
    end

    it "lists no more than the cap and says how much of the area is not on the page" do
      get repository_path(capped_run, spec_directory: area)

      expect(rows.size).to eq(SpecObservation::UNANNOTATED_EXAMPLES_LIMIT)
      expect(basis_line).to have_text(
        "The first 100 of the 112 examples this run recorded here without an @intent", normalize_ws: true
      )
      expect(basis_line).to have_text("The other 12 are not on this page", normalize_ws: true)
    end

    # The other half of the same predicate, and the answer a `truncated?` hard-wired to `true` gets
    # wrong: a complete list captioned as a head tells a reader there are tests it is not showing
    # them when there are none.
    it "says the list is all of them, where nothing was cut" do
      get repository_path(debt_run, spec_directory: area)

      expect(basis_line).to have_text("All 3 examples this run recorded here without an @intent",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("are not on this page")
    end
  end

  # AC5, first of the two empty states. A place whose every recorded example carries an intent is the
  # state the metric exists to reach — not an error, and not missing data.
  describe "an area whose examples all carry an intent" do
    def annotated_area_run
      repository = create_repository(user: @user)
      ingest(repository, [annotated_spec(file_path: order_spec, line_number: 1),
                          unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 2)])
      repository
    end

    it "renders the panel and says there is nothing unannotated, rather than erroring" do
      get repository_path(annotated_area_run, spec_directory: area)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(true)
      expect(panel).to have_text("Nothing unannotated here", normalize_ws: true)
      expect(panel).to have_text("This run recorded no example without an @intent in spec/models",
                                 normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    # And it does not wear the OTHER empty state's sentence, which is the whole point of there being
    # two: this run sent its detail, and the reason there is nothing to list is a finding about the
    # area rather than a gap in the payload.
    it "does not claim the detail is missing" do
      get repository_path(annotated_area_run, spec_directory: area)

      expect(panel).to have_no_text("No per-example detail on this run")
    end

    # *Vacuous Green* at the grain of an empty state. A fully-annotated area and an area this run
    # recorded NOTHING in produce the same empty list, and `SpecObservation.unannotated_in` refuses
    # to tell them apart. Claiming only the first over the second would be "nothing to check" wearing
    # the spelling of "everything passed", so the state discloses the other reading and points at the
    # panel that settles it — which is on the page under the same ask.
    it "discloses that an area this run recorded nothing in arrives here too" do
      get repository_path(annotated_area_run, spec_directory: "spec/nowhere")

      expect(panel).to have_text("Nothing unannotated here", normalize_ws: true)
      expect(panel).to have_text("a population of no examples has no unannotated ones either",
                                 normalize_ws: true)
      expect(panel).to have_text("“Spec files in this directory” panel, open on the same ask",
                                 normalize_ws: true)
      expect(response.body).to include("spec-directory-files")
    end
  end

  # AC5, the other empty state — the one that fails toward a false clean. A run with no per-example
  # rows produces the identical empty list, and rendering it as "nothing unannotated" would be this
  # page inventing a measurement out of a client's silence.
  describe "a run that recorded no per-example rows" do
    def totals_only_run
      repository = create_repository(user: @user)
      create_test_run(repository: repository, total_specs_count: 900, annotated_specs_count: 300)
      repository
    end

    it "says the detail is missing, not that there is nothing unannotated" do
      get repository_path(totals_only_run, spec_directory: area)

      expect(panel?).to be(true)
      expect(panel).to have_text("No per-example detail on this run", normalize_ws: true)
      expect(panel).to have_text("not that everything there is annotated", normalize_ws: true)
      expect(panel).to have_no_text("Nothing unannotated here")
      expect(panel).to have_no_css("tbody tr")
    end
  end

  describe "a page nobody asked a narrowing of" do
    # AC4, first half. The panel does not render, so a reader who never picks an area sees exactly
    # what they saw before this shipped.
    it "renders no panel without a narrowing ask" do
      get repository_path(debt_run)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
      expect(directories_panel).to have_css("tbody tr")
    end

    # AC4, second half, and the one that matters: the READ is not taken either. Matched on
    # `unannotated_recorded_count`, the window alias `SpecObservation::UNANNOTATED_POPULATION_COUNTS`
    # projects — which is this read's fingerprint and nothing else's, so an assertion of ZERO cannot
    # be satisfied by a page that simply issued a different query. The paired non-zero is what stops
    # the zero from being vacuous: it proves the fingerprint matches when the read IS taken.
    it "issues no per-example read at all until a narrowing is asked for" do
      repository = debt_run
      get repository_path(repository)

      unasked = queries_against("unannotated_recorded_count") { get repository_path(repository) }
      asked = queries_against("unannotated_recorded_count") do
        get repository_path(repository, spec_directory: area)
      end

      expect(unasked).to be_empty
      expect(asked.size).to eq(1)
    end

    # And it stays ONE read however many rows come back — the whole list is one query with its
    # population count riding back as a window, not a row-by-row walk.
    it "costs one read whether the area holds three examples or a hundred" do
      small = debt_run
      large = create_repository(user: @user, github_full_name: "acme/large-debt")
      ingest(large, (1..100).map do |n|
        unannotated_spec(file_path: "#{area}/m#{n}_spec.rb", line_number: n)
      end)

      get repository_path(small, spec_directory: area)
      small_reads = queries_against("unannotated_recorded_count") do
        get repository_path(small, spec_directory: area)
      end
      get repository_path(large, spec_directory: area)
      large_reads = queries_against("unannotated_recorded_count") do
        get repository_path(large, spec_directory: area)
      end

      expect(rows.size).to eq(100)
      expect(large_reads.size).to eq(small_reads.size)
      expect(large_reads.size).to eq(1)
    end
  end

  # AC2. The click that closes the ladder — and the ask it must not eat on the way. The carry matrix
  # in spec/requests/repository_drill_down_carry_spec.rb owns the general rule across every link on
  # the page; this asserts the half that belongs to THIS panel: the link exists, it lands here, and
  # it is a `drill_down_path` rather than a hand-written href.
  describe "reaching the list from the ranking above it" do
    it "links each area to this panel, carrying an ask the reader already had open" do
      get repository_path(debt_run, spec_file: refund_spec)

      href = directories_panel.find("a", text: area, match: :prefer_exact)[:href]

      expect(href).to include("spec_directory=#{CGI.escape(area)}")
      expect(href).to include("spec_file=#{CGI.escape(refund_spec)}")
      expect(href).to end_with("#unannotated-examples")
    end

    # AC3. NO NEW PARAMETER: the href writes only asks this page already had, and following it opens
    # the panel. A second parameter minted for this rung would show up as a key here.
    it "opens the panel by following that link, with no parameter of its own" do
      get repository_path(debt_run)
      href = directories_panel.find("a", text: area, match: :prefer_exact)[:href]

      keys = href.split("#").first.split("?", 2).last.split("&").map { |pair| pair.split("=").first }
      get href

      expect(keys).to eq(["spec_directory"])
      expect(panel?).to be(true)
      expect(row_names).to include("Order settles the balance")
    end

    # A list of choices with one of them taken, marked the way both sibling area links mark it.
    it "marks the open area as current" do
      get repository_path(debt_run, spec_directory: area)

      link = directories_panel.find("a", text: area, match: :prefer_exact)

      expect(link["aria-current"]).to eq("true")
      expect(directories_panel.find("a", text: "spec/requests", match: :prefer_exact)["aria-current"]).to be_nil
    end
  end

  # The coordinate as a DESTINATION rather than as text. Every panel above this one hands the reader
  # a narrower question; this one hands them a task, and the task is singular and known — open that
  # file at that line and write an `@intent`. Until now the column printed where to go and stopped.
  describe "the definition site as a link" do
    it "links each row's coordinate to that line on GitHub" do
      get repository_path(debt_run, spec_directory: area)

      expect(row_hrefs).to eq([blob("feedfacecafe0001", shared_group_file, 7),
                               blob("feedfacecafe0001", order_spec, 30),
                               blob("feedfacecafe0001", refund_spec, 9)])
    end

    # The link text is the coordinate the panel already printed, so nothing about the row's identity
    # changed — the same string a reader was reading is now the thing they click.
    it "links the coordinate itself rather than adding a second control to the row" do
      get repository_path(debt_run, spec_directory: area)

      expect(row_links.map { |link| link.text.strip })
        .to eq(["#{shared_group_file}:7", "#{order_spec}:30", "#{refund_spec}:9"])
      expect(panel.all("tbody tr a").size).to eq(3)
    end

    # BOTH LABEL BRANCHES, and this is the one that is easy to miss: `#label` is
    # `name.presence || location_label`, so a row from a producer that sent no name wears the
    # coordinate AS its name and renders through the other site entirely. Linking only the location
    # line under a name would leave inert exactly the rows the fallback exists for — the ones the
    # model comment says a reader "can neither identify nor go and find".
    #
    # `name` is nullable and the client sends nil for an example it could not describe, on the same
    # precedent spec/requests/repository_slowest_examples_spec.rb pins one panel over.
    it "links the coordinate on a row that wears it as its name" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 30).merge(name: nil)])

      get repository_path(repository, spec_directory: area)

      expect(row_names).to eq(["#{order_spec}:30"])
      expect(row_hrefs).to eq([blob("feedfacecafe0001", order_spec, 30)])
      # The fallback already IS the coordinate, so the row is not made to wear it — or link it —
      # twice.
      expect(panel.all("tbody tr a").size).to eq(1)
    end

    # THE DEFINITION SITE, never the including file. `location_label` pairs `file_path` with
    # `line_number` and refuses `spec_file_path` because for a shared example group the two halves
    # come from different files; the link inherits that constraint exactly rather than reaching for
    # the column this list is ORDERED by. Line 7 of `order_spec.rb` is not this test, and on a
    # worklist that is a reader sent to annotate something that is not there.
    it "builds the link from the file the example is DEFINED in, not the file that ran it" do
      get repository_path(debt_run, spec_directory: area)

      shared = row_hrefs.first

      expect(shared).to eq(blob("feedfacecafe0001", shared_group_file, 7))
      expect(shared).not_to include(order_spec)
      # And the "Spec file" column, which is the one that legitimately shows the including file,
      # stays the plain text it was.
      expect(panel.all("tbody tr").first.all("td").last).to have_no_css("a")
    end

    # THE ANCHORED RUN'S SHA, not `main` and not the newest run. `file_path`/`line_number` are a
    # last known path rather than an identity (SPGD-114): the coordinate is accurate against the
    # tree the run that recorded it was taken from, so a page anchored on an older run via
    # `?commit_sha=` must link into THAT run's tree. Linking at `main` would send a reader to
    # whatever has since drifted onto line 30.
    it "pins the link to the run the page is anchored on rather than the newest one" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 30)],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 30)],
             commit_sha: "cccc3333dddd4444")

      get repository_path(repository, spec_directory: area, commit_sha: "aaaa1111bbbb2222")

      expect(row_hrefs).to eq([blob("aaaa1111bbbb2222", order_spec, 30)])
      expect(row_hrefs.first).not_to include("cccc3333dddd4444")
    end

    # The pairing that stops the assertion above from passing on a page that simply had one run:
    # unanchored, the same repository links at the NEWEST sha.
    it "links at the newest run's sha when no anchor was asked for" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 30)],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [unannotated_spec(file_path: order_spec, line_number: 30)],
             commit_sha: "cccc3333dddd4444")

      get repository_path(repository, spec_directory: area)

      expect(row_hrefs).to eq([blob("cccc3333dddd4444", order_spec, 30)])
    end

    # A NEW TAB, introduced here deliberately — this is the app's first link that leaves it, and the
    # reader is mid-worklist. Annotating one test and losing a hundred-row list narrowed by two asks
    # would make the panel worse to use the further through it you got. `rel` is written out rather
    # than left to the browsers that imply it.
    it "opens the file in a new tab, leaving the worklist where the reader had it" do
      get repository_path(debt_run, spec_directory: area)

      expect(row_links.map { |link| link[:target] }.uniq).to eq(["_blank"])
      expect(row_links.map { |link| link[:rel] }.uniq).to eq(["noopener noreferrer"])
    end

    # ZERO NEW QUERIES. `@repository` and `@latest_test_run` are both already loaded by the time this
    # partial renders and `#github_blob_url` is string composition, so a hundred links must cost
    # exactly what three cost. Compared across two narrowings of ONE page rather than across two
    # repositories, so nothing but the row count differs between the two budgets.
    it "costs the same number of queries for a hundred linked rows as for three" do
      repository = create_repository(user: @user)
      ingest(repository,
             (1..3).map { |n| unannotated_spec(file_path: "#{area}/m#{n}_spec.rb", line_number: n) } +
             (1..100).map { |n| unannotated_spec(file_path: "spec/requests/r#{n}_spec.rb", line_number: n) })

      get repository_path(repository, spec_directory: area)
      three = count_queries { get repository_path(repository, spec_directory: area) }
      get repository_path(repository, spec_directory: "spec/requests")
      hundred = count_queries { get repository_path(repository, spec_directory: "spec/requests") }

      expect(rows.size).to eq(100)
      expect(row_hrefs.uniq.size).to eq(100)
      expect(hundred).to eq(three)
    end
  end

  # AC9. The web panel and the JSON block are TWO CONSUMERS OF ONE READ, and this is the assertion
  # that keeps them one. `UnannotatedExamples.for` and `SpecObservation.unannotated_in` are untouched
  # by this rung: the API and the dashboard must not be able to disagree about which tests of a run
  # are unannotated, and a divergence introduced by a later "fix" to either consumer fails here.
  describe "agreement with the JSON endpoint" do
    it "names the same examples, in the same order, as the API's unannotated_examples block" do
      repository = debt_run
      key = repository.api_keys.create!

      get repository_path(repository, spec_directory: area)
      web = rows.map { |row| row[:test] }

      get "/api/v1/repository", params: { unannotated_examples: "1", spec_directory: area },
                                headers: { "Authorization" => "Bearer #{key.raw_token}" }
      api = response.parsed_body.dig("latest_run", "unannotated_examples", "rows").map { |row| row["name"] }

      expect(web).to eq(api)
      expect(web.size).to eq(3)
    end
  end

  # ⭐ WHAT SPECGUARD READS OF EACH ROW — the column SPGD-711 added, and the correction the panel's
  # own caption used to get wrong.
  #
  # Every row on this panel lacks an `@intent`. Most of them SpecGuard nonetheless READS, from the
  # `Class#method behavior` description the client sends and this platform stores; the last column
  # shows the three fields it got, so a reader can CHECK the reading rather than take a badge's word
  # for it. The rows it read nothing from come first, because the list is capped at a hundred and
  # those are the ones that must not fall off the page.
  describe "what the panel says SpecGuard reads of each test" do
    # A run whose area holds one derivable description and one that is not, plus one of each in
    # another area so the narrowing is still doing its work.
    def mixed_reading_run
      repository = create_repository(user: @user)
      ingest(repository,
             [unannotated_spec(file_path: order_spec, line_number: 30,
                               name: "Order#settle clears the outstanding balance"),
              unannotated_spec(file_path: refund_spec, line_number: 9,
                               name: "Refund restores the stock"),
              unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 5,
                               name: "Checkout rejects an empty cart")])
      repository
    end

    it "shows the entity, action and behavior it read, rather than a badge saying it read something" do
      get repository_path(mixed_reading_run, spec_directory: area)

      expect(row_readings.first)
        .to eq("Nothing — no @intent, and the description does not give an entity, an action and a behavior.")
      expect(row_readings.last).to eq("Order settle clears the outstanding balance")
    end

    # ⭐ THE ORDERING, and the reason it is not a preference: the cap is a hundred, the unreadable
    # population is the small one, and a purely alphabetical page would bury it. `refund_spec` sorts
    # AFTER `order_spec`, so a file-navigable-only order puts the derivable row first — which is what
    # this asserts against.
    it "lists the tests it could read nothing from first, ahead of the ones it read" do
      get repository_path(mixed_reading_run, spec_directory: area)

      expect(rows.map { |row| row[:test] })
        .to eq(["Refund restores the stock", "Order#settle clears the outstanding balance"])
    end

    # The caption carries the split, and it is counted off the same windows the rows came back on —
    # so it cannot describe a different slice from the table under it. It also says what a derived
    # reading is MISSING, because the honest version of "derived" is the one that does not sell it as
    # an annotation.
    it "says how many of them it read and how many it could not, and what a derived reading lacks" do
      get repository_path(mixed_reading_run, spec_directory: area)

      expect(basis_line).to have_text("SpecGuard reads 1 of them from the test's own description",
                                      normalize_ws: true)
      expect(basis_line).to have_text("The other 1 it cannot read at all, and those are listed first",
                                      normalize_ws: true)
      expect(basis_line).to have_text("no preconditions", normalize_ws: true)
      # And the claim the panel used to make about every row on it is made about none of them.
      expect(panel).to have_no_text("SpecGuard cannot see")
      expect(panel).to have_no_text("Not visible to SpecGuard")
    end

    # The good branch of the same sentence. An area SpecGuard reads entirely is not "no unannotated
    # tests" — the rows are still there and still unannotated — so the caption has to say the second
    # thing without saying the first.
    it "says there is nothing it cannot read, where there is nothing it cannot read" do
      repository = create_repository(user: @user)
      ingest(repository,
             [unannotated_spec(file_path: order_spec, line_number: 30,
                               name: "Order#settle clears the outstanding balance")])

      get repository_path(repository, spec_directory: area)

      expect(basis_line).to have_text("There is none here it cannot read at all", normalize_ws: true)
      expect(rows.size).to eq(1)
    end

    # ⭐ THE THIRD BRANCH, and it is an ordinary one rather than an exotic state. `spec/requests` is a
    # normal area to narrow to, and the `VERB /path does something` shape that lives there is the
    # canonical description `DerivedIntent` reads NOTHING out of — so an area whose unannotated
    # examples are ALL unreadable is what a reader meets on the first repository they open, not a
    # contrived fixture.
    #
    # Before this branch existed the caption made four claims about an empty set in one breath: it
    # counted a derived reading of zero, pointed at "the last column" for a reading not in it,
    # warned about what a derived reading LACKS when the page rested on none, and then said "the
    # other 2 ... are listed first" of a population that was the whole list. The Overview panel's
    # version of this sentence was branched on `derived.positive?` for exactly these reasons; this
    # is the same correction at the grain below it, which is why the negative assertions here are
    # per-clause rather than one `have_no_text` on the sentence as a whole.
    it "says it read nothing here, without a derived-reading caveat, where it read nothing" do
      repository = create_repository(user: @user)
      ingest(repository,
             [unannotated_spec(file_path: "spec/requests/ingest_spec.rb", line_number: 12,
                               name: "POST /api/v1/ingest rejects a malformed body"),
              unannotated_spec(file_path: "spec/requests/ingest_spec.rb", line_number: 40,
                               name: "POST /api/v1/ingest accepts a well-formed one")])

      get repository_path(repository, spec_directory: "spec/requests")

      expect(rows.size).to eq(2)
      expect(row_readings.uniq)
        .to eq(["Nothing — no @intent, and the description does not give an entity, an action and a behavior."])
      expect(basis_line)
        .to have_text("SpecGuard reads none of them from the test's own description", normalize_ws: true)
      # The four claims that used to be made here about nothing at all.
      expect(basis_line).to have_no_text("shown in the last column")
      expect(basis_line).to have_no_text("no preconditions")
      expect(basis_line).to have_no_text("The other")
      expect(basis_line).to have_no_text("listed first")
      # ⭐ AND THIS IS THE ONE PLACE THE "cannot see" WORDING IS TRUE, so it is the one place the
      # panel says it. The example above asserts the panel does NOT say it of a mixed area, which is
      # the correction SPGD-711 exists for; that assertion means nothing unless the wording still
      # reaches the population it was always accurate about.
      expect(basis_line).to have_text("These are the tests it genuinely cannot see", normalize_ws: true)
    end
  end
end
