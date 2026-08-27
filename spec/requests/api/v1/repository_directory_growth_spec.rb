# frozen_string_literal: true

require "rails_helper"

# The `directory_growth` block on `GET /api/v1/repository` — the agent-readable half of the "Areas
# that grew or shrank over the window" panel `repositories#show` renders, and the "in which areas"
# half of the roadmap's growth axis ("how the suite has grown over time and in which areas"), which
# is the half this endpoint had never been given.
#
# Its own file, beside `repository_unstable_tests_spec.rb`, on the precedent that file states for
# itself: every example here needs a multi-RUN fixture whose runs record DIFFERENT per-area
# populations, while every block in `repository_latest_run_spec.rb` is a fact about one run and
# builds a one-run repository to say so.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule both sibling files state, and for the same reason: every state this
# block turns on is a state the recorder produces from what a real client sends. A run with a suite
# size and no per-example rows is a client that reports only totals; an area is the parent directory
# of the `spec_file_path` a real payload carried.
RSpec.describe "GET /api/v1/repository — directory_growth", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON block off the
  # same data and compares them field for field. The owner is the same user on both surfaces, so the
  # two cannot be looking at two repositories.
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(repo: repository, key: nil, query: {})
    token = (key || repo.api_keys.create!).raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  # The two keys under test, always read together: the window block explains the rows block, and
  # reading either alone is how a `null` gets asserted without its reason.
  def blocks(**)
    body = get_repository(**)
    [body["directory_growth_window"], body["directory_growth"]]
  end

  # One ingested CI run, through the producer. `specs` are the wire hashes a client POSTs; the
  # recorder reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
  # Every run is stamped back in time so the window orders them the way CI produced them rather than
  # by whatever order the fixture inserted them in — which is the whole subject of this file.
  #
  # `total:` is passed separately from `specs` for the one state a real client produces and a naive
  # fixture cannot: a run that reports a suite size and sends no per-example detail at all.
  def ingest(repo, specs, commit_sha:, branch: "main", at: nil, total: nil)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    run
  end

  # `{"spec/models" => 4}` — one run's payload holding four examples in `spec/models`, each in its
  # own file so no two rows collide on the recorder's key. An AREA is the parent directory of
  # `spec_file_path` (`SpecObservation::DIRECTORY_EXPRESSION`), so the directory is what the fixture
  # controls and the file name is noise.
  def examples_in(counts)
    counts.flat_map do |directory, count|
      Array.new(count) do |index|
        unannotated_spec(file_path: "#{directory}/thing_#{index}_spec.rb", line_number: index + 1,
                         name: "#{directory} example #{index}", duration: 0.1)
      end
    end
  end

  def ingest_areas(counts, commit_sha:, at:, repo: repository, branch: "main", **)
    ingest(repo, examples_in(counts), commit_sha: commit_sha, branch: branch, at: at, **)
  end

  # THE ASYMMETRIC WINDOW this file turns on, oldest run first, and every property of it is load
  # bearing:
  #
  # * `spec/models` GREW by 3 and `spec/services` SHRANK by 3 between the two ENDS, so the sign of
  #   every `change` is a fact the fixture can be wrong about — a symmetric window would serialize
  #   identically under a window handed in newest-first and pin nothing at all.
  # * The two movements are EQUAL IN MAGNITUDE, so the `ABS(...) DESC` ranking is decided by the
  #   `path ASC` tie-break, which is the half of the order a client is told it can reproduce.
  # * `spec/jobs` holds 2 examples in every run, so the list carries an area that did not move —
  #   `change: 0` where the panel prints `±0`.
  # * BOTH ENDS RECORD 8 ROWS IN TOTAL. The run totals `history` serves are IDENTICAL at the two
  #   ends of this window, and three areas still moved. That is this block's whole reason to exist,
  #   stated as a fixture: no arrangement of the totals already served can reach these figures.
  # * The MIDDLE run is a decoy on the same shape — its own areas differ from both ends — so an
  #   implementation that compared adjacent runs rather than the two ends would report different
  #   numbers here rather than the same ones.
  def asymmetric_window(repo: repository, branch: "main")
    ingest_areas({ "spec/models" => 1, "spec/services" => 5, "spec/jobs" => 2 },
                 commit_sha: "baseline0001", branch: branch, at: 30.days.ago, repo: repo)
    ingest_areas({ "spec/models" => 2, "spec/services" => 4, "spec/jobs" => 2 },
                 commit_sha: "middle000001", branch: branch, at: 20.days.ago, repo: repo)
    ingest_areas({ "spec/models" => 4, "spec/services" => 2, "spec/jobs" => 2 },
                 commit_sha: "anchor000001", branch: branch, at: 10.days.ago, repo: repo)
  end

  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }

  describe "a branch-scoped window whose two ends recorded different areas" do
    before { asymmetric_window }

    # Criterion 1, at the row grain: the operands the panel's labels are built from, and nothing
    # that has been worded.
    it "serves each area's two operands, their difference and the three states of it" do
      _window, block = blocks(query: { branch: "main" })

      expect(row_at(block, "spec/models")).to eq(
        "path" => "spec/models", "baseline_count" => 1, "anchor_count" => 4, "change" => 3,
        "moved" => true, "new_area" => false, "removed_area" => false
      )
      expect(row_at(block, "spec/services")).to eq(
        "path" => "spec/services", "baseline_count" => 5, "anchor_count" => 2, "change" => -3,
        "moved" => true, "new_area" => false, "removed_area" => false
      )
      expect(row_at(block, "spec/jobs")).to eq(
        "path" => "spec/jobs", "baseline_count" => 2, "anchor_count" => 2, "change" => 0,
        "moved" => false, "new_area" => false, "removed_area" => false
      )
    end

    # ⭐ CRITERION 5 — THE MECHANISM ASSERTION, and the reason this file's fixture is asymmetric.
    #
    # `SpecDirectoryWindowGrowth.for` documents its parameter as OLDEST FIRST, takes `runs.last` as
    # the anchor and walks from index 0 for the baseline. `history_runs` is newest-first. Handed in
    # unreversed it does not raise: it anchors on the OLDEST run, baselines against a NEWER one, and
    # every `change` comes back sign-flipped under a block that looks perfectly well-formed.
    #
    # So this asserts the two things that flip and nothing that does not: the SIGN of each movement,
    # and WHICH of the two commits the comparison was taken FROM. Verified by mutation — dropping
    # the `.reverse` in `RepositoryOverview#spec_directory_window_growth` turns
    # `spec/models` from `+3` into `-3` and swaps the two shas, and this example goes red.
    it "anchors on the newest run and baselines on the oldest, so every change carries its true sign" do
      _window, block = blocks(query: { branch: "main" })

      # The suite GREW in `spec/models` across this window and SHRANK in `spec/services`. Both signs
      # invert under the wrong ordering, so both are stated.
      expect(row_at(block, "spec/models")["change"]).to eq(3)
      expect(row_at(block, "spec/services")["change"]).to eq(-3)
      # And the figure spans the OLDER run to the NEWER one, named so a client can go and read them.
      expect(block["anchor_commit_sha"]).to eq("anchor000001")
      expect(block["baseline_commit_sha"]).to eq("baseline0001")
      # The two shas are the two ENDS of the window `history` serves, in that direction — not two
      # adjacent runs that happen to differ.
      history = get_repository(query: { branch: "main" })["history"].map { |row| row["commit_sha"] }
      expect(history.first).to eq(block["anchor_commit_sha"])
      expect(history.last).to eq(block["baseline_commit_sha"])
      # `.reverse` and never `.reverse!`: the endpoint's own ordering contract still holds in the
      # same response body, over the same memoized array this block was drawn on.
      expect(history).to eq(%w[anchor000001 middle000001 baseline0001])
    end

    # The area grain is NOT DERIVABLE from what the endpoint already served, stated as an assertion
    # rather than as a claim in a comment: the two ends of this window report the same
    # `total_specs`, and three areas moved between them.
    it "reaches figures no arrangement of the run totals it already serves can produce" do
      body = get_repository(query: { branch: "main" })
      totals = body["history"].map { |row| row["total_specs"] }

      expect(totals.first).to eq(totals.last)
      expect(body["directory_growth"]["rows"].map { |row| row["change"] }).to eq([3, -3, 0])
    end

    # The presenter's order, NOT re-sorted here — asserted on a fixture where the ranking and the
    # alphabet disagree in the first key and agree only in the tie-break, so a serializer that
    # sorted by path could not produce it.
    it "serves the presenter's order, largest movement first, and the tie-break a client can redo" do
      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].map { |row| row["path"] })
        .to eq(["spec/models", "spec/services", "spec/jobs"])
      # `ABS(change) DESC` first — the unmoved area is last although its path sorts first — then
      # `path ASC` between the two areas that moved by the same amount. That is exactly what
      # `tie_break_served: true` claims, and it is computed here from the fields served.
      expect(block["rows"].sort_by { |row| [-row["change"].abs, row["path"]] }).to eq(block["rows"])
      expect(block["rows"].map { |row| row["path"] })
        .not_to eq(block["rows"].map { |row| row["path"] }.sort)
    end

    # Criterion 6's other half, and the honesty half of the block: the figures that say what the
    # comparison actually spanned and what it was counted off.
    it "states the window it spans, what it stepped over, and what it was counted over" do
      window, block = blocks(query: { branch: "main" })

      expect(window).to eq(
        "order" => "abs_change_desc,path_asc",
        "tie_break_served" => true,
        "basis" => "two_endpoints",
        "branch_scope" => "single_branch",
        "branch" => "main",
        "grouped" => true
      )
      expect(block).to include(
        "state" => "comparable", "comparable" => true,
        # Three runs held, three spanned, the baseline two back — and nothing stepped over, split
        # into the two conditions that would have.
        "window_run_count" => 3, "covered_run_count" => 3, "runs_back" => 2, "shortened" => false,
        "skipped_unmeasured_count" => 0, "skipped_assembled_differently_count" => 0,
        # Counted off the rows the two ends WROTE, never off `total_specs`.
        "directory_count" => 3, "truncated" => false,
        "baseline_recorded_count" => 8, "anchor_recorded_count" => 8,
        "limit" => SpecObservation::MOVED_DIRECTORIES_LIMIT
      )
    end

    # The body is the whole feature here — there is no prose copy for an agent to read the shape off
    # — so all three levels are pinned EXACTLY rather than key by key: a key added without a line in
    # this list fails here, and a listed key quietly dropped fails here too.
    it "serves exactly the keys this contract pins, on the window, the block and the rows" do
      window, block = blocks(query: { branch: "main" })

      expect(window.keys).to contain_exactly("order", "tie_break_served", "basis", "branch_scope",
                                             "branch", "grouped")
      expect(block.keys).to contain_exactly(
        "state", "comparable", "rows", "window_run_count", "covered_run_count", "runs_back",
        "shortened", "skipped_unmeasured_count", "skipped_assembled_differently_count",
        "anchor_commit_sha", "baseline_commit_sha", "directory_count", "truncated",
        "baseline_recorded_count", "anchor_recorded_count", "limit"
      )
      expect(block["rows"].map(&:keys)).to all(
        contain_exactly("path", "baseline_count", "anchor_count", "change", "moved", "new_area",
                        "removed_area")
      )
    end

    # CRITERION 4 — operands, never the panel's spellings. `SpecDirectoryWindowGrowth::Row` carries
    # `change_label` (`±0`, a U+2212 for a negative, `New area`), `change_reading` (a sentence),
    # `baseline_count_label` and `anchor_count_label` (delimited numerals), and not one of them may
    # appear here.
    #
    # NOT A VACUOUS NEGATIVE: the parity example below reads the PANEL over this same fixture and
    # asserts that `±0` and a U+2212 really are what it prints, so the vocabulary this example
    # refuses is demonstrably produced by the data rather than absent from it.
    it "serves no value the panel has worded, and no glyph it has typeset" do
      _window, block = blocks(query: { branch: "main" })

      # Every string in the block, at any depth, is one of exactly three things: the state symbol,
      # a commit sha, or an area's path. No sentence, no sign glyph, no delimited numeral.
      expect(strings_in(block))
        .to contain_exactly("comparable", "anchor000001", "baseline0001",
                            "spec/models", "spec/services", "spec/jobs")
      expect(strings_in(block)).to all(satisfy { |value| !value.match?(/[±−]|\d,\d/) })
      # And the figures a client compares are numbers rather than strings it would have to parse.
      expect(block["rows"].flat_map { |row| row.values_at("baseline_count", "anchor_count", "change") })
        .to all(be_an(Integer))
      expect(block.values_at("window_run_count", "covered_run_count", "runs_back", "directory_count",
                            "skipped_unmeasured_count", "skipped_assembled_differently_count",
                            "baseline_recorded_count", "anchor_recorded_count", "limit"))
        .to all(be_an(Integer))
      expect(block.values_at("comparable", "shortened", "truncated")).to all(be_in([true, false]))
    end
  end

  # CRITERION 7 — the API and the dashboard cannot name different numbers for the same repository
  # and branch. Read off the RENDERED PAGE rather than off a second call to
  # `SpecDirectoryWindowGrowth`, which would only compare the endpoint against itself.
  describe "against what repositories#show prints for the same branch" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-directory-window-growth")
      panel.all("tbody tr").map do |row|
        path, baseline, anchor, change = row.all("td").map { |cell| cell.text.strip }
        { "path" => path, "baseline" => baseline, "anchor" => anchor, "change" => change }
      end
    end

    it "names the same areas, with the same operands and the same movements" do
      asymmetric_window

      _window, block = blocks(query: { branch: "main" })
      get repository_path(repository, branch: "main")

      # The page prints the labels; the block serves the operands. Both readings are assembled here
      # so a drift in either surface is a red example rather than two numbers nobody compared.
      served = block["rows"].map do |row|
        { "path" => row["path"],
          "baseline" => row["baseline_count"].to_s,
          "anchor" => row["anchor_count"].to_s,
          "change" => case row["change"]
                      when 0 then "±0"
                      when ..-1 then "−#{row["change"].abs}"
                      else "+#{row["change"]}"
                      end }
      end

      expect(panel_rows).to eq(served)
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(served.length).to eq(3)
      # And the label vocabulary the JSON block refuses IS what this data makes the panel print, so
      # the "no worded values" example next door is refusing something real.
      expect(panel_rows.map { |row| row["change"] }).to include("±0", "−3", "+3")
    end
  end

  # CRITERION 2 — the branch decision, expressed as a cost. Unfiltered, `history_runs` is the
  # INTERLEAVED all-branch window, on which the walk would baseline a `main` run against a
  # `feature/x` run with the same shard count and report movement between two different pieces of
  # code.
  describe "an unfiltered window whose runs interleave two branches" do
    def interleaved_repository
      ingest_areas({ "spec/models" => 1 }, commit_sha: "mainold00001", at: 30.days.ago)
      ingest_areas({ "spec/models" => 40 }, commit_sha: "feature00001", branch: "feature/x",
                   at: 20.days.ago)
      ingest_areas({ "spec/models" => 2 }, commit_sha: "mainnew00001", at: 10.days.ago)
      repository
    end

    it "serves null rows and a window that says why, rather than a comparison across branches" do
      interleaved_repository

      window, block = blocks

      expect(window).to eq(
        "order" => "abs_change_desc,path_asc",
        "tie_break_served" => true,
        "basis" => "two_endpoints",
        "branch_scope" => "all_branches",
        "branch" => nil,
        "grouped" => false
      )
      # `null` and never an empty block of zeroes: "we refused to compare across branches" must not
      # serialize as "we compared and nothing moved".
      expect(block).to be_nil
    end

    # The gate is BEFORE the read, which is the difference between a refusal and a discarded answer.
    #
    # ⚠️ THE GRAIN NOW HAS TWO READERS, WHICH IS WHY THIS IS A DIFFERENCE AND NOT A ZERO.
    # `directory_run_growth` — the run-over-run pair added beside this one (see
    # `repository_directory_run_growth_spec.rb`) — issues the SAME `directory_growth_between`
    # aggregate, so `growth_grain_reads` cannot tell the two apart by pattern, and it is served
    # UNCONDITIONALLY: this fixture's two newest `main` runs are comparable, so one read is present
    # here whatever this block does. The window block's own contribution is therefore measured as
    # the DIFFERENCE the `?branch=` gate makes on one fixture, which is exactly the quantity this
    # example was always about.
    it "adds no read of its own for this grain, and leaves the other grains alone" do
      interleaved_repository
      get_repository(key: api_key)

      unfiltered = growth_grain_reads { get_repository(key: api_key) }.length
      named = growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length

      # Unfiltered, this block adds NOTHING to what the run-over-run pair beside it already read;
      # named, it adds exactly its one aggregate.
      expect(named - unfiltered).to eq(1)
      expect(unfiltered).to eq(1)
      # The endpoint's single-run grains are untouched at their established count, so the figure
      # above is this grain's readers being counted rather than the table going quiet. EIGHT rather
      # than seven since `directory_runtime_growth` was added: that pair is served unconditionally
      # too, but it issues `directory_runtime_growth_between` and lands in its OWN grain, so it moves
      # this total without touching the `growth` figures above.
      # ⭐ ONE MORE SINCE SPGD-711 — `latest_run.intent_readings`, an aggregate over the anchored
      # run's rows splitting them into authored, derived and unreadable. It is the only UNGATED
      # addition this endpoint has taken: every drill-in here costs nothing until a client asks, and
      # this is served on every response, because a correction a client has to opt into leaves it
      # reading `total_specs - annotated_specs` as the count of what SpecGuard cannot see. It lands
      # in its own grain (`AS run_authored_count`) and touches none of the figures above.
      expect(observation_reads { get_repository(key: api_key) }.length).to eq(9)
      expect(get_repository(key: api_key)["directory_growth"]).to be_nil
      # And the read that IS issued unfiltered belongs to the pair that answers unconditionally.
      expect(get_repository(key: api_key)["directory_run_growth"]).not_to be_nil
    end

    # And the refusal is not a claim that there was nothing to find: named, the same window compares
    # and the two branches answer differently — which is precisely the cross-branch figure the
    # unfiltered window would have manufactured.
    it "compares each branch on its own once one is named" do
      interleaved_repository

      _window, main_block = blocks(query: { branch: "main" })
      _window, feature_block = blocks(query: { branch: "feature/x" })

      expect(main_block["state"]).to eq("comparable")
      expect(row_at(main_block, "spec/models")["change"]).to eq(1)
      # One run on `feature/x`, so there is no window to compare across — and the endpoint says
      # which of the eight states that is rather than serving an empty list.
      expect(feature_block["state"]).to eq("no_earlier_run")
      expect(feature_block["rows"]).to eq([])
    end
  end

  # CRITERION 6 — every non-comparable state round-trips as its own symbol, carrying the figures it
  # actually has: the four states the walk short-circuits into before the aggregate read carry no
  # totals at all and serve them as `null`, while the three that DID read carry their true ones.
  describe "a branch-scoped window with no comparison to draw" do
    it "names the run that reported no tests, rather than serving a comparison against it" do
      ingest_areas({ "spec/models" => 2 }, commit_sha: "measured0001", at: 20.days.ago)
      ingest(repository, [], commit_sha: "emptyrun0001", at: 10.days.ago, total: 0)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "anchor_unmeasured", "comparable" => false, "rows" => [],
                               "window_run_count" => 2, "anchor_commit_sha" => "emptyrun0001",
                               "baseline_commit_sha" => nil,
                               "covered_run_count" => nil, "runs_back" => nil,
                               "directory_count" => nil, "truncated" => nil,
                               "baseline_recorded_count" => nil, "anchor_recorded_count" => nil)
    end

    it "names a window of one run as having no earlier run, not as an empty comparison" do
      ingest_areas({ "spec/models" => 2 }, commit_sha: "onlyrun00001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "no_earlier_run", "comparable" => false, "rows" => [],
                               "window_run_count" => 1,
                               "covered_run_count" => nil, "runs_back" => nil,
                               "anchor_commit_sha" => "onlyrun00001", "baseline_commit_sha" => nil,
                               "directory_count" => nil, "truncated" => nil,
                               "baseline_recorded_count" => nil, "anchor_recorded_count" => nil)
    end

    # A branch whose earlier runs all reported zero tests — a client that stopped reporting totals.
    # Distinct from the state below it, and the two are different repairs.
    it "names a window whose earlier runs measured no suite, and counts what it stepped over" do
      2.times do |index|
        ingest(repository, [], commit_sha: "unmeasured#{index}0", at: (30 - index).days.ago, total: 0)
      end
      ingest_areas({ "spec/models" => 2 }, commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "no_measured_baseline", "comparable" => false,
                               "rows" => [], "window_run_count" => 3,
                               "skipped_unmeasured_count" => 2,
                               "skipped_assembled_differently_count" => 0,
                               "covered_run_count" => nil, "runs_back" => nil,
                               "shortened" => nil,
                               "baseline_commit_sha" => nil,
                               "directory_count" => nil, "truncated" => nil,
                               "baseline_recorded_count" => nil, "anchor_recorded_count" => nil)
    end

    # A branch whose earlier runs measured a suite and were assembled differently — sharding
    # changed. `TestRun#assembled_like?` is `shard_count` equality and the walk cannot cross it.
    it "names a window whose earlier runs were assembled differently, split from the state above" do
      2.times do |index|
        run = ingest_areas({ "spec/models" => 2 }, commit_sha: "sharded000#{index}",
                           at: (30 - index).days.ago)
        3.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 2) }
      end
      ingest_areas({ "spec/models" => 5 }, commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "no_comparable_composition", "comparable" => false,
                               "rows" => [], "window_run_count" => 3,
                               "skipped_unmeasured_count" => 0,
                               "skipped_assembled_differently_count" => 2,
                               "covered_run_count" => nil, "runs_back" => nil,
                               "shortened" => nil,
                               "baseline_commit_sha" => nil,
                               "directory_count" => nil, "truncated" => nil,
                               "baseline_recorded_count" => nil, "anchor_recorded_count" => nil)
    end

    # The four states above are decided from rows already in memory, so a window with nothing to
    # compare asks `spec_observations` NOTHING — the cost claim this block makes for itself.
    it "reads nothing at this grain where the walk found no baseline" do
      2.times do |index|
        ingest(repository, [], commit_sha: "unmeasured#{index}0", at: (30 - index).days.ago, total: 0)
      end
      ingest_areas({ "spec/models" => 2 }, commit_sha: "anchor000001", at: 10.days.ago)
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }).to be_empty
      expect(get_repository(key: api_key, query: { branch: "main" }).dig("directory_growth", "state"))
        .to eq("no_measured_baseline")
    end

    # The recorded-rows states, which are decidable only FROM the aggregate — so they arrive with
    # the run they landed on and both denominators, rather than as a bare blank.
    it "names the end that recorded no per-example rows, with the baseline it landed on" do
      ingest(repository, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 400)
      ingest_areas({ "spec/models" => 2 }, commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "baseline_unrecorded", "comparable" => false,
                               "rows" => [], "baseline_commit_sha" => "totalsonly01",
                               "runs_back" => 1, "covered_run_count" => 2,
                               "baseline_recorded_count" => 0, "anchor_recorded_count" => 2)
    end

    it "names the anchor as the end with no per-example rows, with both denominators" do
      ingest_areas({ "spec/models" => 2 }, commit_sha: "baseline0001", at: 20.days.ago)
      ingest(repository, [], commit_sha: "totalsonly01", at: 10.days.ago, total: 400)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "anchor_unrecorded", "comparable" => false, "rows" => [],
                               "baseline_commit_sha" => "baseline0001",
                               "anchor_commit_sha" => "totalsonly01",
                               "baseline_recorded_count" => 2, "anchor_recorded_count" => 0)
    end

    # Both ends report a suite size and neither wrote a row — a client that sends only totals. The
    # aggregate comes back EMPTY, and for this read an empty result means exactly that: a group
    # exists here if and only if a row does.
    it "names a window neither end of which recorded rows, rather than an empty comparison" do
      ingest(repository, [], commit_sha: "totalsold001", at: 20.days.ago, total: 300)
      ingest(repository, [], commit_sha: "totalsnew001", at: 10.days.ago, total: 400)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("state" => "neither_recorded", "comparable" => false, "rows" => [],
                               "baseline_commit_sha" => "totalsold001",
                               "anchor_commit_sha" => "totalsnew001",
                               "directory_count" => 0, "baseline_recorded_count" => 0,
                               "anchor_recorded_count" => 0, "runs_back" => 1)
    end

    # An unknown branch selects zero runs, and the block is served as a populated state rather than
    # as the `null` an unfiltered request gets — the two mean different things, and `serialized_history`
    # makes exactly this argument for `history: []`.
    it "groups over an empty window for a branch with no runs, and reads nothing to do it" do
      asymmetric_window
      get_repository(key: api_key)

      window, block = blocks(key: api_key, query: { branch: "does-not-exist" })

      expect(window).to include("branch_scope" => "single_branch", "branch" => "does-not-exist",
                                "grouped" => true)
      expect(block).to include("state" => "anchor_unmeasured", "window_run_count" => 0,
                               "rows" => [], "anchor_commit_sha" => nil,
                               "covered_run_count" => nil, "runs_back" => nil)
      # "Reads nothing to do it" is now a DIFFERENCE rather than a zero: the run-over-run pair
      # beside this one issues the same aggregate unconditionally, and this repository's two newest
      # runs are comparable, so one read is present under every request here. An unknown branch adds
      # NONE OF ITS OWN — the count is the same as on a request that named no branch at all.
      unknown = growth_grain_reads { get_repository(key: api_key, query: { branch: "does-not-exist" }) }
      expect(unknown.length).to eq(growth_grain_reads { get_repository(key: api_key) }.length)
      expect(unknown.length).to eq(1)
    end

    # ⭐ THE CONTRACT THE FIVE EXAMPLES ABOVE PIN, STATED ONCE AS AN INVARIANT: the span figures AND
    # the count/completeness figures are served IF AND ONLY IF there is a baseline to count them to,
    # which is the same condition `baseline_commit_sha` is served under and is read off the same
    # `baseline_run` in the same serializer.
    #
    # `SpecDirectoryWindowGrowth#covered_run_count` is `runs_back + 1` over a `runs_back` that keeps
    # its `0` DEFAULT in every state the walk landed on no baseline in — so a serializer passing it
    # through answers "this comparison spans one run" where no comparison was taken, and the block
    # then contradicts itself two keys apart: `shortened: false` claims the span equals the window
    # while `covered_run_count: 1` against `window_run_count: 2` says it does not. The degenerate end
    # is the third row below: an unknown branch selects ZERO runs and would report a span of one over
    # a window holding none, beside an `anchor_commit_sha` of `null` in the same body.
    #
    # `shortened` IS THE FOURTH SPAN KEY and the FOURTH ROW is what makes this example falsifiable
    # for it. The first three rows reach only `no_earlier_run` and `anchor_unmeasured`, which never
    # enter the walk: their skip counters keep their `0` default and `shortened?` is benignly `false`
    # there, so an ungated `shortened` passes all three — which is exactly how it stayed ungated
    # while this example was green (SPGD-429). The `skipped` branch reaches `no_measured_baseline`,
    # which is reachable ONLY by every earlier run being skipped, so `skipped_count.positive?` — and
    # therefore `shortened?` — is necessarily TRUE there. Ungated, that row reads `true` beside three
    # nulls; the row fails unless the key is gated, and it is the only row here that can say so.
    #
    # THE FOUR COUNT/COMPLETENESS KEYS RIDE THE SAME PREDICATE and are swept here for the same
    # reason: `directory_count`, `baseline_recorded_count` and `anchor_recorded_count` are set ONLY
    # on the `from_tuples` path, which is also the only path that passes `baseline_run:`, so in the
    # three no-baseline rows they would each pass their fabricated `0` through — and `truncated`,
    # derived as `directory_count > rows.size`, would derive `false` from it. The `pair` row is what
    # keeps this from being satisfiable by nulling them everywhere: it landed on a baseline and DID
    # read the aggregate, so it owes its TRUE totals — a `0` there is counted, not defaulted, and
    # `truncated: true` is the honest reading of one covered area against a state that lists no rows.
    #
    # Swept across the four shapes AT ONCE, on four branches of one repository, because the defect
    # is the pair coming apart rather than any single state's figure — and a baseline the walk DID
    # land on still owes its true span, `shortened: false` included, which in the recorded-rows
    # states is the actionable half of the answer ("the run that recorded nothing is one back, and
    # it is this sha").
    it "counts a span only where there is a baseline to count it to, and never against none" do
      ingest_areas({ "spec/models" => 2 }, commit_sha: "loneanchor01", at: 10.days.ago,
                   branch: "solo")
      ingest(repository, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 400, branch: "pair")
      ingest_areas({ "spec/models" => 2 }, commit_sha: "pairanchor01", at: 10.days.ago,
                   branch: "pair")
      ingest(repository, [], commit_sha: "skipunmeas01", at: 20.days.ago, total: 0,
             branch: "skipped")
      ingest_areas({ "spec/models" => 2 }, commit_sha: "skipanchor01", at: 10.days.ago,
                   branch: "skipped")

      spans = %w[solo pair skipped does-not-exist].to_h do |branch|
        _window, block = blocks(query: { branch: branch })
        [branch, block.values_at("state", "baseline_commit_sha", "covered_run_count", "runs_back",
                                 "shortened", "directory_count", "truncated",
                                 "baseline_recorded_count", "anchor_recorded_count")]
      end

      expect(spans).to eq(
        "solo" => ["no_earlier_run", nil, nil, nil, nil, nil, nil, nil, nil],
        "pair" => ["baseline_unrecorded", "totalsonly01", 2, 1, false, 1, true, 0, 2],
        "skipped" => ["no_measured_baseline", nil, nil, nil, nil, nil, nil, nil, nil],
        "does-not-exist" => ["anchor_unmeasured", nil, nil, nil, nil, nil, nil, nil, nil]
      )
    end

    # The key-always-present rule, asserted where nulling the two figures above could quietly break
    # it: they go to `null` rather than going ABSENT. The exact-keys contract runs on the comparable
    # fixture, so without this the absence states — which are seven of the eight, and the ones a
    # client meets when something is wrong — would have no example stating their shape at all.
    it "serves the same key set in a state with no comparison as in one with a comparison" do
      ingest_areas({ "spec/models" => 2 }, commit_sha: "loneanchor01", at: 10.days.ago,
                   branch: "solo")
      asymmetric_window

      _window, absent = blocks(query: { branch: "solo" })
      _window, compared = blocks(query: { branch: "main" })

      expect(compared["state"]).to eq("comparable")
      expect(absent["state"]).to eq("no_earlier_run")
      expect(absent.keys).to match_array(compared.keys)
    end
  end

  # The cap, and both operands of it. `SpecObservation::MOVED_DIRECTORIES_LIMIT` bounds the ROWS;
  # `directory_count` is counted before it (a window function runs before the `LIMIT`), which is
  # what makes "am I seeing all of them" answerable at all.
  describe "a window covering more areas than the block lists" do
    it "discloses the cap, the total it was applied to, and the bound that produced it" do
      areas = Array.new(SpecObservation::MOVED_DIRECTORIES_LIMIT + 2) { |index| "spec/area#{index}" }
      ingest_areas(areas.index_with { 1 }, commit_sha: "baseline0001", at: 20.days.ago)
      ingest_areas(areas.index_with { 3 }, commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block["rows"].length).to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(block).to include("truncated" => true,
                               "directory_count" => SpecObservation::MOVED_DIRECTORIES_LIMIT + 2,
                               "limit" => SpecObservation::MOVED_DIRECTORIES_LIMIT)
      # The totals are the whole comparison's, not the listed rows' — a caption built on
      # `rows.sum` would describe ten areas under a heading about twelve.
      expect(block).to include("baseline_recorded_count" => areas.length,
                               "anchor_recorded_count" => areas.length * 3)
    end

    it "serves the cap as untripped where the comparison stayed under it" do
      asymmetric_window

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include("truncated" => false, "directory_count" => 3)
      expect(block["rows"].length).to eq(3)
    end
  end

  # An area present on ONE side only, which is the distinction a signed number alone cannot carry:
  # `+40` against a side that was never measured reads identically to an existing area that gained
  # forty examples.
  describe "an area only one end of the window recorded" do
    it "flags the area that arrived and the area that went, beside their operands" do
      ingest_areas({ "spec/models" => 2, "spec/legacy" => 4 },
                   commit_sha: "baseline0001", at: 20.days.ago)
      ingest_areas({ "spec/models" => 2, "spec/system" => 6 },
                   commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(row_at(block, "spec/system"))
        .to include("baseline_count" => 0, "anchor_count" => 6, "change" => 6,
                    "new_area" => true, "removed_area" => false, "moved" => true)
      expect(row_at(block, "spec/legacy"))
        .to include("baseline_count" => 4, "anchor_count" => 0, "change" => -4,
                    "new_area" => false, "removed_area" => true, "moved" => true)
      # And the flags are not derivable from `change` alone: `spec/models` did not move and is
      # neither, while an area at zero on a side is a real absence rather than an unmeasured one.
      expect(row_at(block, "spec/models"))
        .to include("change" => 0, "new_area" => false, "removed_area" => false)
    end
  end

  # The window the comparison SPANS can be shorter than the window it was asked over — the fact a
  # thirty-run heading over a twenty-six-run comparison would otherwise hide.
  describe "a window the walk had to step over runs in" do
    it "reports the shortened span, the runs it stepped over, and which condition rejected them" do
      ingest(repository, [], commit_sha: "unmeasured01", at: 40.days.ago, total: 0)
      run = ingest_areas({ "spec/models" => 9 }, commit_sha: "differently1", at: 30.days.ago)
      2.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 9) }
      ingest_areas({ "spec/models" => 1 }, commit_sha: "baseline0001", at: 20.days.ago)
      ingest_areas({ "spec/models" => 4 }, commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main" })

      expect(block).to include(
        "state" => "comparable", "window_run_count" => 4, "covered_run_count" => 2,
        "runs_back" => 1, "shortened" => true,
        "skipped_unmeasured_count" => 1, "skipped_assembled_differently_count" => 1,
        "baseline_commit_sha" => "baseline0001", "anchor_commit_sha" => "anchor000001"
      )
      # The figures are the ones the SPAN it reports was taken across — the run it stepped over
      # recorded nine examples in that area, which appears in no number here.
      expect(row_at(block, "spec/models")).to include("baseline_count" => 1, "anchor_count" => 4,
                                                      "change" => 3)
    end
  end

  describe "what the growth block costs the endpoint" do
    # ONE READ, and it is also the MEMOIZATION GUARD — the only form of one this endpoint can have.
    # `show` reads the presenter twice, once for the window block's `grouped` and once for the rows,
    # so an unmemoized gate builds it twice and the difference below is two.
    #
    # ⚠️ MEASURED AS A DIFFERENCE, BECAUSE THE GRAIN HAS TWO READERS. The run-over-run pair beside
    # this one (`repository_directory_run_growth_spec.rb`) issues the same
    # `directory_growth_between` aggregate and is served UNCONDITIONALLY, so a bare count here is
    # two and neither read is attributable. Unfiltered, THIS block is not constructed at all — that
    # is its own gate — so the unfiltered count is the other pair's alone and the difference is
    # exactly this block's.
    it "reads spec_observations exactly once on a comparable branch-scoped window" do
      asymmetric_window
      get_repository(key: api_key)

      unfiltered = growth_grain_reads { get_repository(key: api_key) }.length
      named = growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length

      expect(named - unfiltered).to eq(1)
      # Both terms are stated, so the difference cannot be satisfied by both blocks going quiet.
      expect([unfiltered, named]).to eq([1, 2])
    end

    # And that one read is ALL this block adds — the assertion a per-grain count cannot make,
    # because a read matching no grain's pattern is invisible to every one of them. Fourteen here is
    # the endpoint's six single-run reads, plus THREE for flakiness, plus this block's one and the
    # run-over-run pair's one, plus the RUNTIME pair's one, plus the IDENTITY grain's one: nothing
    # failed in this fixture, so `UnstableTests` finds no candidate and never issues its composition
    # read. That is a fact about this window rather than about the block, which is exactly why the
    # total is also asserted as the SUM OF THE PARTS — a read that stopped being issued and a
    # different one that started cannot cancel out into a passing number.
    #
    # ⚠️ THE IDENTITY GRAIN CONTRIBUTES ONE HERE AND NOT THREE, for the same fixture reason
    # `repository_unstable_tests_spec.rb` states beside its own total: these runs are ingested
    # without `Ingest::IdentityResolver`, so every `spec_identity_id` is NULL, `SlowestTests` stops
    # at its presence probe in `:unresolved`, and one read is its whole cost. Asserted as its own
    # term below so a fixture that starts resolving fails THERE rather than drifting this total.
    it "adds exactly that one to the table's total, and no second" do
      asymmetric_window
      get_repository(key: api_key)

      area, file, example, description, flakiness, growth =
        observation_reads_by_grain { get_repository(key: api_key, query: { branch: "main" }) }
      identity = identity_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }

      # TWO in the growth grain, and they are this block's and the run-over-run pair's — the split
      # is pinned by the difference example above, which this one cannot make. STILL TWO after
      # `directory_runtime_growth` was added: that block ranks by a SUM of durations rather than a
      # COUNT, so it is matched by its own pattern and adopted into no grain here.
      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length]).to eq([1, 1, 2, 2, 3, 2])
      expect(identity.length).to eq(1)
      expect(observation_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key, query: { branch: "main" }) })
      expect(observation_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(14)
    end

    # NO RUN-WINDOW QUERY. The block is drawn on `history_runs`, which is materialized once and
    # already read twice by `show` — a second `recent_test_runs` would be invisible to the count
    # above and would read as one more branch-scoped SELECT here.
    #
    # The branch-scoped `test_runs` selects are TWO: this window, and the run-over-run pair's
    # previous-run lookup. They are told apart by the ROW-VALUE PREDICATE, which
    # `Repository#previous_test_run_on_branch` emits and `recent_test_runs` does not — so this still
    # pins the window's count at one rather than absorbing a regression into a widened total.
    it "adds no query against test_runs, whatever the window holds" do
      asymmetric_window
      get_repository(key: api_key)

      statements = executed_sql { get_repository(key: api_key, query: { branch: "main" }) }
      branch_selects = statements.grep(/FROM "test_runs"/).grep(/"branch" = /)
      # `run_anchor`'s retention boundary is a THIRD branch-scoped select and is excluded from both
      # counts below, on the same rule the row-value predicate excludes the previous-run lookup by:
      # it is one indexed read ABOUT THE ANCHORED RUN, not part of this window, so folding it in
      # would widen the total and hide which axis moved. `TestRun#observations_retained?` emits it.
      # Told apart STRUCTURALLY — it is the only branch-scoped read carrying an OFFSET, where every
      # other selects `test_runs.*` — and bounded at exactly ONE below, so the carve-out cannot
      # swallow a per-row regression, which is the leak this example exists to catch.
      boundary_selects = branch_selects.grep(/OFFSET/)
      branch_selects = branch_selects.grep_v(/OFFSET/)
      window_selects = branch_selects.grep_v(/\(test_runs\.created_at, test_runs\.id\) < /)

      expect(boundary_selects.length).to eq(1)
      expect(window_selects.length).to eq(1)
      expect(branch_selects.length).to eq(2)
      expect(get_repository(key: api_key, query: { branch: "main" })
               .dig("directory_growth", "window_run_count")).to eq(3)
    end

    # The comparison is two run ids in an `IN` list whatever the window's length, so the cost does
    # not follow the window — the claim the panel makes for itself, asserted here as a relative pin
    # rather than as a number that would need rebaselining.
    it "costs the same at 3 runs and at the full 30-run bound" do
      asymmetric_window
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key, query: { branch: "main" }) }

      27.times do |index|
        ingest_areas({ "spec/models" => 4, "spec/services" => 2, "spec/jobs" => 2 },
                     commit_sha: "filler0000#{format("%02d", index)}", at: (9 - (index * 0.1)).days.ago)
      end
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(2)
      expect(count_queries { get_repository(key: api_key, query: { branch: "main" }) }).to eq(baseline)
      # And the window really did grow, so the equality above is not two identical small windows.
      expect(get_repository(key: api_key, query: { branch: "main" })
               .dig("directory_growth", "window_run_count"))
        .to eq(Api::V1::RepositoriesController::SINGLE_BRANCH_HISTORY_LIMIT)
    end

    # Nor does it follow the size of the suite: the aggregate is `GROUP BY` area over two runs, and
    # the row cap bounds what comes back.
    it "costs the same one read as the suite grows" do
      asymmetric_window
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key, query: { branch: "main" }) }

      ingest_areas({ "spec/models" => 40, "spec/services" => 30, "spec/jobs" => 30 },
                   commit_sha: "biggerrun001", at: 1.day.ago)
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key, query: { branch: "main" }) }.length)
        .to eq(2)
      expect(count_queries { get_repository(key: api_key, query: { branch: "main" }) }).to eq(baseline)
      expect(get_repository(key: api_key, query: { branch: "main" })
               .dig("directory_growth", "anchor_recorded_count")).to eq(100)
    end
  end
end
