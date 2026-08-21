# frozen_string_literal: true

require "rails_helper"

# The "Where the unannotated tests are" panel on repositories#show — the rows behind the one figure
# on the Overview panel that named a problem and offered no route into it.
#
# That panel prints `total_specs_count - annotated_specs_count` as "Not visible to SpecGuard" and
# says *"SpecGuard cannot see the other N tests."* A subtraction is the whole answer it can give.
# The same rows have had a ranked worklist on the API since SPGD-591/608/623 and on the MCP bridge
# since SPGD-599; this file covers the rung the dashboard never had.
#
# Its own file rather than examples in spec/requests/repositories_spec.rb, on the precedent every
# per-example panel here sets: each of these fixtures needs `spec_observations` rows, and the
# Overview/API-keys file is edited by sibling slices.
#
# The rows are written by `Ingest::RunRecorder` rather than inserted, on this suite's standing rule —
# the `status` these counts group on is what `Ingest::Payload` validated and the recorder wrote, and
# a hand-built row could carry a status no client can send.
#
# FOUR STATES, and the whole design of the panel is that a reader can tell them apart:
#
#   run with debt                  -> the ranking
#   run whose rows carry no debt   -> "No unannotated tests in this run"      (a positive finding)
#   run with no per-example rows   -> "No per-example detail on this run"     (an absence of data)
#   no run at all                  -> no panel; the Overview says why
#
# The middle two are the pair this file exists to keep apart. They are the same empty table and
# opposite news, which is *Vacuous Green* (SPGD-78) exactly at the grain of a caption.
RSpec.describe "Repository unannotated directories", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#unannotated-directories")

  def panel? = Capybara.string(response.body).has_css?("#unannotated-directories")

  # The Overview panel one screen up. Read from this file for exactly one example — the pair that
  # asserts the two surfaces now agree about a run with no per-example rows.
  def overview = Capybara.string(response.body).find("#overview")

  # ELEMENT-scoped, never panel-scoped: the caption's two truncation branches share most of their
  # words, and a panel-level `have_text` would pass for the wrong branch with the deciding `if`
  # deleted.
  def basis_line = panel.find("#unannotated-directories-basis")

  # One row as a reader meets it: the area, its three READINGS, and the population they were counted
  # against.
  #
  # `unannotated` is not a cell any more and is DERIVED here rather than dropped. SPGD-711 split that
  # column in two — `derived` and `unreadable` — because "unannotated" and "what SpecGuard cannot see"
  # stopped being one sentence, and the sum is what every ordering example in this file was written
  # against. Reconstructing it keeps those examples asserting the quantity they were about, and the
  # two operands are on the row beside it for the examples that are about the split itself.
  def rows
    reading_rows.map do |row|
      { path: row[:path], unannotated: (row[:derived].to_i + row[:unreadable].to_i).to_s,
        recorded: row[:recorded] }
    end
  end

  # The same rows with the split left intact, for the examples that are ABOUT the split.
  def reading_rows
    panel.all("tbody tr").map do |row|
      path, authored, derived, unreadable, recorded =
        row.all("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }

      { path: path, authored: authored, derived: derived, unreadable: unreadable,
        recorded: recorded }
    end
  end

  def row_paths = rows.map { |row| row[:path] }

  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: specs.count { |spec| spec[:status] == "annotated" },
        duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  describe "a run carrying annotation debt" do
    # Built so the ranking cannot be mistaken for any other list this page renders. `spec/models`
    # holds the most unannotated examples and NOT the most examples; `spec/system` holds a single
    # unannotated example and is the smallest area; `spec/requests` is the biggest population and
    # carries the least debt. A panel ranking by size, or by the wall clock the panel above it ranks
    # by, orders these differently.
    def debt_run
      repository = create_repository(user: @user)
      ingest(repository,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1),
              unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 2),
              unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3),
              annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
              unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 5),
              annotated_spec(file_path: "spec/requests/refund_spec.rb", line_number: 6),
              annotated_spec(file_path: "spec/requests/order_spec.rb", line_number: 7),
              annotated_spec(file_path: "spec/requests/token_spec.rb", line_number: 8),
              annotated_spec(file_path: "spec/requests/user_spec.rb", line_number: 9),
              unannotated_spec(file_path: "spec/system/smoke_spec.rb", line_number: 10)])
      repository
    end

    # More areas than the panel lists, so the listed count and the run's own count are different
    # numbers and a caption cannot satisfy both by accident.
    def twenty_five_directory_run
      repository = create_repository(user: @user)
      ingest(repository, (1..25).map do |i|
        Array.new(i) do |n|
          unannotated_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", line_number: (i * 100) + n)
        end
      end.flatten)
      repository
    end

    # THE panel's claim: which AREAS the tests SpecGuard cannot see are in, most first — and both
    # operands on every row, because the count alone is the figure the Overview already had.
    it "ranks the areas by how many of their examples carry no intent, most first" do
      get repository_path(debt_run)

      expect(rows).to eq([{ path: "spec/models", unannotated: "3", recorded: "4" },
                          { path: "spec/requests", unannotated: "1", recorded: "5" },
                          { path: "spec/system", unannotated: "1", recorded: "1" }])
    end

    # The ordering is by DEBT and not by size, and the fixture is built so the two disagree:
    # `spec/requests` is the largest area on this run and sits below the smaller `spec/models`,
    # while `spec/system` — one example — is listed at all.
    it "does not rank the areas by how many examples they hold" do
      get repository_path(debt_run)

      expect(row_paths.first).to eq("spec/models")
      expect(rows.first[:recorded]).to eq("4")
      expect(rows.map { |row| row[:recorded] }).not_to eq(rows.map { |row| row[:recorded] }.sort.reverse)
    end

    # OPERANDS AND NEVER A FRACTION — `UnannotatedDirectories` states that boundary twice and it
    # governs the partial too. An area at 3 of 4 is equally a module nobody has annotated yet and a
    # module of generated specs nobody intends to, and the panel does not decide which.
    it "shows no percentage, ratio or verdict on a row" do
      get repository_path(debt_run)

      expect(panel).to have_no_text("%")
      expect(panel).to have_no_text("75")
      expect(panel).to have_no_text("3 of 4")
      expect(panel).to have_text("never a percentage", normalize_ws: true)
    end

    # An area with no debt is a ROW here, by the model's stated decision — the read groups the run's
    # whole population and applies the status filter inside the aggregate. A panel that dropped those
    # rows would describe a different population from the API block of the same name.
    it "lists an area whose examples all carry an intent at zero rather than dropping it" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1),
                          annotated_spec(file_path: "spec/system/smoke_spec.rb", line_number: 2)])

      get repository_path(repository)

      expect(rows).to eq([{ path: "spec/models", unannotated: "1", recorded: "1" },
                          { path: "spec/system", unannotated: "0", recorded: "1" }])
    end

    # Bounded by `SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT` — its own constant, not the
    # by-duration panel's: the two rank different things and a suite wanting twenty areas ranked by
    # cost has no reason to want twenty ranked by debt.
    it "lists no more than the ten carrying the most, however many areas the run touched" do
      get repository_path(twenty_five_directory_run)

      expect(rows.size).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(row_paths.first).to eq("spec/d25")
      expect(row_paths.last).to eq("spec/d16")
    end

    # A capped list that does not disclose its cap is read as the whole story. `rows.size` cannot
    # state the population — it IS the truncated figure — so the caption names what the list is the
    # head of, through `UnannotatedDirectories#truncated?`.
    it "says how many areas the run recorded examples in, not just how many it lists" do
      get repository_path(twenty_five_directory_run)

      expect(basis_line).to have_text(
        "The 10 areas SpecGuard reads least of, of the 25 this run recorded examples in — " \
        "most unreadable examples first, then most unannotated",
        normalize_ws: true
      )
    end

    # The other half of the same predicate, and the answer a `truncated?` hard-wired to `true` gets
    # wrong: a complete list captioned as a sample tells a reader there are areas it is not showing
    # them when there are none.
    it "says the list is all of them, where nothing was cut" do
      get repository_path(debt_run)

      expect(basis_line).to have_text(
        "All 3 directories this run recorded examples in — most unreadable examples first, then most unannotated",
        normalize_ws: true
      )
      expect(basis_line).to have_no_text("areas SpecGuard reads least of, of the")
    end

    # The denominator is the rows THIS RUN wrote here, never the Overview's suite size — that figure
    # is re-derived by SUM over shard reports and a client may report totals for more examples than
    # it sends detail for. The caption says so rather than leaving a reader to find it with a
    # calculator.
    it "counts each area's own rows rather than the run's reported suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1)],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(rows).to eq([{ path: "spec/models", unannotated: "1", recorded: "1" }])
      expect(panel).to have_no_text("4,000")
      expect(basis_line).to have_text("a different population from the suite size on the Overview panel above",
                                      normalize_ws: true)
    end

    # Grouped on the immediate parent of the file that RAN each example, so a shared example group's
    # debt lands on the area that included it rather than on `spec/support`, and a nested area is its
    # own row rather than counting inside its ancestor. The rollup the API serves obeys both rules;
    # this pins that the page renders the same rows.
    it "lands a shared example group's debt on the area that included it" do
      repository = create_repository(user: @user)
      shared = "spec/support/shared_examples.rb"
      ingest(repository, [unannotated_spec(file_path: shared, line_number: 4,
                                           spec_file_path: "spec/models/order_spec.rb",
                                           id: "./spec/models/order_spec.rb[1:1:1]"),
                          unannotated_spec(file_path: shared, line_number: 4,
                                           spec_file_path: "spec/models/orders/refund_spec.rb",
                                           id: "./spec/models/orders/refund_spec.rb[1:1:1]")])

      get repository_path(repository)

      expect(row_paths).to eq(["spec/models", "spec/models/orders"])
      expect(row_paths).not_to include("spec/support")
    end
  end

  # THE half of the Vacuous Green pair that is GOOD NEWS. A run whose every recorded example carries
  # an intent has nothing to rank, and a panel that vanished there would leave "nothing is
  # unannotated" indistinguishable from "SpecGuard does not track that" — the rule
  # `_rejected_ingests.html.erb` states for its own empty state.
  describe "a run whose examples all carry an intent" do
    def annotated_run
      repository = create_repository(user: @user)
      ingest(repository, [annotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1),
                          annotated_spec(file_path: "spec/system/smoke_spec.rb", line_number: 2)])
      repository
    end

    it "renders the panel and says there is no debt, rather than disappearing" do
      get repository_path(annotated_run)

      expect(panel?).to be(true)
      expect(panel).to have_text("No unannotated tests in this run", normalize_ws: true)
      expect(panel).to have_text("Every example this run recorded carries an @intent, across all 2 directories",
                                 normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    # And it does not say the other empty state's sentence, which is the whole point of there being
    # two: this run sent its detail, and the reason there is nothing to list is a finding about the
    # suite rather than a gap in the payload.
    it "does not claim the detail is missing" do
      get repository_path(annotated_run)

      expect(panel).to have_no_text("No per-example detail on this run")
    end
  end

  # The OTHER half of the pair, and the one that fails toward a false clean: a run with no
  # per-example rows produces the identical empty ranking, and rendering it as "no unannotated
  # tests" would be this page inventing a measurement out of a client's silence.
  describe "a run that recorded no per-example rows" do
    def totals_only_run
      repository = create_repository(user: @user)
      create_test_run(repository: repository, total_specs_count: 900, annotated_specs_count: 300)
      repository
    end

    it "renders the panel and says the detail is missing, not that there is no debt" do
      get repository_path(totals_only_run)

      expect(panel?).to be(true)
      expect(panel).to have_text("No per-example detail on this run", normalize_ws: true)
      expect(panel).to have_text("not that it has none", normalize_ws: true)
      expect(panel).to have_no_css("tbody tr")
    end

    it "does not claim the run is free of unannotated tests" do
      get repository_path(totals_only_run)

      expect(panel).to have_no_text("No unannotated tests in this run")
    end

    # ⭐ THE TWO SURFACES NOW AGREE ON THIS RUN, where before SPGD-711 they could not.
    #
    # The Overview used to print a five-figure "Not visible to SpecGuard" off the run's counters while
    # this panel said it had no rows to describe — two statements a reader had to reconcile. The
    # Overview reads the same `IntentReadings#recorded?` this panel gates on, so on a totals-only run
    # it declines to say how much of the suite it can read AT ALL, in the same terms this panel uses.
    #
    # What it still prints, and must: the @intent share off the counters. That is the figure the
    # client did report, and the one question this correction was required to leave answering exactly
    # as it did before.
    it "coexists with an Overview that declines to report readings and still gives the @intent share" do
      get repository_path(totals_only_run)

      expect(overview).to have_text("Carrying an @intent 300", normalize_ws: true)
      expect(overview).to have_text("33.3% — 300 of 900 tests carry an @intent", normalize_ws: true)
      expect(overview).to have_text("nothing here to say how much of the rest it can make out", normalize_ws: true)
      # And the claim that used to be made about the other 600 is made by neither surface now.
      expect(response.body).not_to include("Not visible to SpecGuard")
      expect(response.body).not_to include("SpecGuard cannot see the other")
      expect(panel).to have_text("Any count on the Overview above is taken from the run's own totals",
                                 normalize_ws: true)
    end
  end

  # A repository CI has never reported for. The Overview's "No CI run has reported yet" is this
  # page's one statement of that, and a second empty state here would invite exactly the reading that
  # branch exists to refuse: never-ingested is not measured-zero.
  describe "a repository with no run at all" do
    it "renders no panel" do
      get repository_path(create_repository(user: @user))

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
      expect(response.body).to include("No CI run has reported yet")
    end

    # And costs nothing to not render: the load is gated on the run, so a page with no run issues no
    # read of `spec_observations` at all. The page-wide budget in spec/requests/repositories_spec.rb
    # counts the query on the other side of that gate; this is the half an absolute count on a
    # fixture that HAS a run cannot see.
    it "issues no per-example read for a repository that has never reported" do
      repository = create_repository(user: @user)
      get repository_path(repository)

      expect(queries_against("spec_observations") { get repository_path(repository) }).to be_empty
    end
  end

  # The N+1 shape an absolute page budget cannot tell from an ordinary widening: the panel renders
  # one row per area, and a view that touched an association per row would cost a query per row. The
  # rows are plain Structs over a `pluck`, so this is equality across two suite sizes.
  describe "the cost of rendering it" do
    def run_with(directories:, examples_per_directory:, name:)
      repository = create_repository(user: @user, github_full_name: "acme/#{name}")
      specs = (1..directories).flat_map do |i|
        Array.new(examples_per_directory) do |n|
          unannotated_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", line_number: (i * 100) + n)
        end
      end
      ingest(repository, specs)
      repository
    end

    it "costs the same number of per-example reads at 20 areas as at 2" do
      small = run_with(directories: 2, examples_per_directory: 1, name: "two-areas")
      large = run_with(directories: 20, examples_per_directory: 5, name: "twenty-areas")

      get repository_path(small)
      small_queries = queries_against("spec_observations") { get repository_path(small) }
      get repository_path(large)
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      # Both pages rendered the panel — an equality is satisfied by two pages that render nothing.
      expect(rows.size).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
    end
  end

  # ⭐ THE THREE-WAY SPLIT SPGD-711 PUT ON EVERY ROW, and the ranking it put in front of the debt one.
  #
  # The panel used to carry one column — "Not visible to SpecGuard" over `unannotated_count` — and on
  # a suite that has never been annotated that column reads N of N for every area, under a header
  # claiming SpecGuard could see none of them. It could see almost all of them. Now each area splits
  # into what carries an `@intent`, what SpecGuard READ from the description, and what it could not
  # read at all — and only the third is a count of tests the product may describe as invisible.
  describe "how much of each area SpecGuard can read" do
    # `spec/models` is READABLE and large; `spec/workers` is small and DARK. Under the old ranking
    # the big readable area leads and the dark corner is second; under the new one it is the reverse,
    # which is the whole point — a ten-row ranking led by debt on an unannotated suite is a ranking
    # by area size.
    def reading_run
      repository = create_repository(user: @user)
      ingest(repository,
             [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
              unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1,
                               name: "Order#settle clears the outstanding balance"),
              unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 2,
                               name: "Refund#issue returns the money to the payer"),
              unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 3,
                               name: "Cart#total totals the cart"),
              unannotated_spec(file_path: "spec/workers/sweep_spec.rb", line_number: 5,
                               name: "the nightly sweep runs")])
      repository
    end

    it "splits each area into what is authored, what it read, and what it could not read" do
      get repository_path(reading_run)

      expect(reading_rows)
        .to eq([{ path: "spec/workers", authored: "0", derived: "0", unreadable: "1", recorded: "1" },
                { path: "spec/models", authored: "1", derived: "3", unreadable: "0", recorded: "4" }])
    end

    # ⭐ THE RANKING. `spec/models` carries THREE unannotated examples to `spec/workers`'s one, so the
    # old `unannotated_count DESC` order puts it first. It is second here, because SpecGuard reads
    # every one of its three and cannot read the other area's one.
    it "leads on the areas it cannot read, not on the ones carrying the most debt" do
      get repository_path(reading_run)

      expect(row_paths).to eq(["spec/workers", "spec/models"])
      # And the debt ranking is intact underneath as the tiebreak: on a run with nothing unreadable,
      # the area carrying the most unannotated examples leads exactly as it did before.
      repository = create_repository(user: @user, github_full_name: "acme/all-readable")
      ingest(repository,
             [unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 1,
                               name: "Order#settle clears the outstanding balance"),
              unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 2,
                               name: "Refund#issue returns the money to the payer"),
              unannotated_spec(file_path: "spec/workers/sweep_spec.rb", line_number: 5,
                               name: "Sweep#run clears the expired sessions")])

      get repository_path(repository)

      expect(row_paths).to eq(["spec/models", "spec/workers"])
    end

    # The claim the column header used to make, made now about the one column that may make it — and
    # the caption saying what a derived reading is MISSING, which is the honest version of it.
    it "reserves the invisibility claim for the column that can carry it" do
      get repository_path(reading_run)

      expect(panel).to have_no_text("Not visible to SpecGuard")
      expect(panel).to have_text("Carrying an @intent", normalize_ws: true)
      expect(panel).to have_text("Read from the description", normalize_ws: true)
      expect(panel).to have_text("Not readable", normalize_ws: true)
      expect(basis_line).to have_text("Only the third column is a count of tests SpecGuard can say " \
                                      "nothing about", normalize_ws: true)
      expect(basis_line).to have_text("its layer is guessed from the directory rather than declared",
                                      normalize_ws: true)
    end

    # The three columns PARTITION each area's population, which is what makes them safe to render
    # side by side: a row whose parts did not sum to its total would be three columns of a four-way
    # split.
    it "splits each area exactly, with nothing counted twice and nothing left out" do
      get repository_path(reading_run)

      reading_rows.each do |row|
        expect(row[:authored].to_i + row[:derived].to_i + row[:unreadable].to_i)
          .to eq(row[:recorded].to_i)
      end
    end

    # THE PANEL AND THE JSON BLOCK ARE TWO CONSUMERS OF ONE READ, and the split must not be able to
    # differ between them — the same guard the sibling panel keeps for its rows.
    it "splits the areas the same way, in the same order, as the API's unannotated_directories block" do
      repository = reading_run
      key = repository.api_keys.create!

      get repository_path(repository)
      web = reading_rows

      get "/api/v1/repository", params: { unannotated_examples: "1" },
                                headers: { "Authorization" => "Bearer #{key.raw_token}" }
      api = response.parsed_body.dig("latest_run", "unannotated_directories", "rows").map do |row|
        { path: row["path"], authored: row["authored_count"].to_s, derived: row["derived_count"].to_s,
          unreadable: row["unreadable_count"].to_s, recorded: row["recorded_count"].to_s }
      end

      expect(web).to eq(api)
    end
  end
end
