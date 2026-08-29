# frozen_string_literal: true

require "rails_helper"

# The `directory_run_growth` pair on `GET /api/v1/repository` — the agent-readable half of the
# "Areas that grew or shrank" panel `repositories#show` renders with NO PARAMETER AT ALL, and the
# one question about growth this endpoint could not be asked: *which areas moved in the push I just
# made*.
#
# ITS OWN FILE, BESIDE `repository_directory_growth_spec.rb` RATHER THAN INSIDE IT, and the two are
# not near-copies. That file covers the WINDOW pair — `SpecDirectoryWindowGrowth`, the two endpoints
# of a thirty-run branch window, served only under `?branch=`. This one covers the RUN-OVER-RUN
# parent — `SpecDirectoryGrowth`, the latest run against the previous run on its own branch, served
# unconditionally. They share a row serializer and a SQL shape and nothing else: the states differ,
# the gate differs, and the fixture that makes one falsifiable (a window with a decoy in its middle)
# says nothing about the other, which reads only the two newest rows.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule the sibling files state, and for the same reason: every state this
# pair turns on is a state the recorder produces from what a real client sends. A run with a suite
# size and no per-example rows is a client that reports only totals; an area is the parent directory
# of the `spec_file_path` a real payload carried.
RSpec.describe "GET /api/v1/repository — directory_run_growth", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON blocks off the
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

  # The two keys under test, always read together: the contract block explains the rows block, and
  # reading either alone is how a `null` gets asserted without its reason.
  def blocks(**)
    body = get_repository(**)
    [body["directory_run_growth_window"], body["directory_run_growth"]]
  end

  # One ingested CI run, through the producer — the sibling file's helper verbatim, including the
  # `total:` seam for the one state a real client produces and a naive fixture cannot: a run that
  # reports a suite size and sends no per-example detail at all.
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

  # THE TWO-RUN FIXTURE THIS FILE TURNS ON, oldest first, and every property of it is load bearing:
  #
  # * `spec/models` GREW by 3 and `spec/services` SHRANK by 3, so the SIGN of every `change` is a
  #   fact the fixture can be wrong about — a symmetric pair would serialize identically under a
  #   comparison taken backwards and would pin nothing at all.
  # * The two movements are EQUAL IN MAGNITUDE, so the `ABS(...) DESC` ranking is decided by the
  #   `path ASC` tie-break, which is the half of the order a client is told it can reproduce.
  # * `spec/jobs` holds 2 examples in both runs, so the list carries an area that did not move —
  #   `change: 0`, where the panel prints `±0`.
  # * BOTH RUNS RECORD 8 ROWS IN TOTAL, so the two `total_specs` figures `history` serves are
  #   IDENTICAL and three areas still moved. That is this pair's whole reason to exist, stated as a
  #   fixture: no arrangement of the totals already served can reach these figures.
  #
  # ⭐ AND THERE IS NO THIRD RUN, deliberately — the difference from the sibling file's fixture. The
  # window pair needs a decoy in the middle to prove it spans the ENDS; this pair compares the two
  # NEWEST rows, so a third run is added only by the examples that are about which two rows get
  # picked.
  def adjacent_runs(repo: repository, branch: "main")
    ingest_areas({ "spec/models" => 1, "spec/services" => 5, "spec/jobs" => 2 },
                 commit_sha: "previous0001", branch: branch, at: 20.days.ago, repo: repo)
    ingest_areas({ "spec/models" => 4, "spec/services" => 2, "spec/jobs" => 2 },
                 commit_sha: "latest000001", branch: branch, at: 10.days.ago, repo: repo)
  end

  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }

  # ⭐ CRITERION 1 — THE WHOLE POINT OF THE TICKET, AND THE ONE THING THE SIBLING PAIR CANNOT DO.
  describe "a plain unparameterised request" do
    before { adjacent_runs }

    # No `?branch=`, no `?spec_directory=`, nothing. The dashboard answers this question with no
    # parameter and this endpoint served `directory_growth: null` for exactly the same request.
    # @intent: { entity: "directory_run_growth", action: "serve growth without a branch ask", behavior: "a plain unparameterised request carries a comparable window block and the run-over-run rows, the question the window pair needs a branch to answer", layer: "request" }
    it "carries growth on a request that names no branch at all" do
      window, block = blocks

      expect(window).to include("state" => "comparable", "comparable" => true)
      expect(block["rows"].map { |row| row["path"] })
        .to eq(%w[spec/models spec/services spec/jobs])
    end

    # The operands the panel's labels are built from, and nothing that has been worded. Read through
    # `serialized_directory_growth_row`, which is SHARED VERBATIM with the window pair — so this is
    # also the assertion that the shared row serializer reaches this block unchanged.
    # @intent: { entity: "directory_run_growth", action: "serve each area operands and states", behavior: "every row carries baseline_count, anchor_count, change, moved, new_area and removed_area so a client builds its own labels from numbers", layer: "request" }
    it "serves each area's two operands, their difference and the three states of it" do
      _window, block = blocks

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

    # ANCHOR IS THE LATEST RUN AND BASELINE IS THE PREVIOUS ONE, which is the direction every
    # `change` above is signed in. Both halves flip together if the two runs are handed to
    # `SpecDirectoryGrowth.for` in the wrong order, so both are stated: swapping the arguments turns
    # `spec/models` from `+3` into `-3` AND swaps these two shas.
    # @intent: { entity: "directory_run_growth", action: "anchor on the latest run", behavior: "anchor is the newest run and baseline its predecessor on the same branch, so every change sign survives an argument swap in the growth object", layer: "request" }
    it "anchors on the latest run and baselines on the previous one, so every change carries its true sign" do
      window, block = blocks

      expect(row_at(block, "spec/models")["change"]).to eq(3)
      expect(row_at(block, "spec/services")["change"]).to eq(-3)
      expect(window).to include("anchor_commit_sha" => "latest000001",
                                "baseline_commit_sha" => "previous0001")
      # And the anchor is the run `latest_run` names, in the same body — the two blocks cannot be
      # describing two different runs of the same repository.
      expect(get_repository["latest_run"]["commit_sha"]).to eq(window["anchor_commit_sha"])
    end

    # The area grain is NOT DERIVABLE from what the endpoint already served, stated as an assertion
    # rather than as a claim in a comment: the two runs report the SAME `total_specs`, and three
    # areas moved between them.
    # @intent: { entity: "directory_run_growth", action: "reach underivable figures", behavior: "two runs reporting identical total_specs still show three areas moving, proving the area grain cannot be computed from the served run totals", layer: "request" }
    it "reaches figures no arrangement of the run totals it already serves can produce" do
      body = get_repository
      totals = body["history"].map { |row| row["total_specs"] }

      expect(totals.uniq).to eq([8])
      expect(body["directory_run_growth"]["rows"].map { |row| row["change"] }).to eq([3, -3, 0])
    end

    # OPERANDS, NEVER THE PANEL'S SPELLINGS. `SpecDirectoryGrowth::Row` carries `change_label`,
    # `change_reading`, `previous_count_label` and `latest_count_label` — typographic and
    # screen-reader spellings of these same numbers. A client served those would be splitting
    # strings and stripping glyphs to compare two rows.
    # @intent: { entity: "directory_run_growth", action: "serve operands never panel spellings", behavior: "no serialized string is a label the dashboard typeset, so a client compares rows arithmetically instead of splitting glyphs", layer: "request" }
    it "serves no value the panel has worded, and no glyph it has typeset" do
      window, block = blocks

      # The only strings in the rows block are area paths; the contract block's are its own tokens.
      expect(strings_in(block)).to all(start_with("spec/"))
      expect(strings_in(window)).to contain_exactly("abs_change_desc,path_asc", "previous_run_on_branch",
                                                    "single_branch", "main", "comparable",
                                                    "latest000001", "previous0001")
      # And the vocabulary being refused is real — this data makes the panel print all three of it.
      expect(strings_in(block) + strings_in(window)).not_to include("±0", "−3", "+3", "New area")
    end

    # The cap's operands, so "am I seeing all of them" is answerable. `directory_count` is counted
    # BEFORE the `LIMIT` applies (a window function runs first), and `limit` is read off the
    # constant rather than restated.
    # @intent: { entity: "directory_run_growth", action: "disclose coverage and cap operands", behavior: "directory_count, truncated, limit and both recorded counts are served, letting a client tell a full list from a cut one", layer: "request" }
    it "discloses the areas it covered, whether the list was cut, and the bound that cut it" do
      _window, block = blocks

      expect(block).to include("directory_count" => 3, "truncated" => false,
                               "limit" => SpecObservation::MOVED_DIRECTORIES_LIMIT)
      # The DENOMINATORS the recorded-rows states turn on — counted off the rows the two runs wrote,
      # deliberately not `total_specs_count`, which is re-derived by SUM over shard reports.
      expect(block).to include("baseline_recorded_count" => 8, "anchor_recorded_count" => 8)
    end
  end

  describe "a comparison covering more areas than the block lists" do
    # @intent: { entity: "directory_run_growth", action: "disclose a truncation honestly", behavior: "when areas exceed the limit the block serves only the limit rows but reports the true directory_count, the bound and truncated true", layer: "request" }
    it "discloses the cap, the total it was applied to, and the bound that produced it" do
      areas = Array.new(SpecObservation::MOVED_DIRECTORIES_LIMIT + 2) { |index| "spec/area#{index}" }
      ingest_areas(areas.index_with { 1 }, commit_sha: "previous0001", at: 20.days.ago)
      ingest_areas(areas.index_with { 3 }, commit_sha: "latest000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["rows"].length).to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(block).to include("truncated" => true,
                               "directory_count" => SpecObservation::MOVED_DIRECTORIES_LIMIT + 2,
                               "limit" => SpecObservation::MOVED_DIRECTORIES_LIMIT)
    end
  end

  # ⭐ CRITERION 6 — BRANCH-CORRECT BY CONSTRUCTION, WHICH IS WHY THIS PAIR NEEDS NO `?branch=`.
  #
  # `Repository#previous_test_run_on_branch` scopes to the LATEST RUN'S OWN branch, so the hazard
  # the window pair's gate exists to prevent cannot arise here. This is the example that says so:
  # the row immediately before the newest one in the interleaved all-branch history is a DIFFERENT
  # BRANCH, and comparing against it would report a movement no commit made.
  describe "a newest run whose immediate predecessor is on another branch" do
    before do
      ingest_areas({ "spec/models" => 1 }, commit_sha: "feature00001", branch: "feature/x",
                   at: 30.days.ago)
      ingest_areas({ "spec/models" => 99 }, commit_sha: "maininterlv1", branch: "main",
                   at: 20.days.ago)
      ingest_areas({ "spec/models" => 4 }, commit_sha: "feature00002", branch: "feature/x",
                   at: 10.days.ago)
    end

    # @intent: { entity: "directory_run_growth", action: "compare within the latest run branch", behavior: "the baseline is the previous run on the anchor run own branch, not the interleaved all-branch neighbour row that a different branch wrote", layer: "request" }
    it "compares the two newest runs on the latest run's own branch, not the interleaved row" do
      window, block = blocks

      expect(window).to include("branch" => "feature/x", "branch_scope" => "single_branch",
                                "anchor_commit_sha" => "feature00002",
                                "baseline_commit_sha" => "feature00001")
      # +3 across the branch, and NOT the −95 the interleaved `main` row would have produced.
      expect(row_at(block, "spec/models")).to include("baseline_count" => 1, "anchor_count" => 4,
                                                      "change" => 3)
      # And the row it declined to compare against really is the immediate predecessor in the
      # all-branch history this endpoint serves, so the refusal above had something to refuse.
      expect(get_repository["history"].map { |row| row["commit_sha"] })
        .to eq(%w[feature00002 maininterlv1 feature00001])
    end

    # NOT RE-ANCHORED BY `?branch=`, exactly like `latest_run` and unlike `history`. A client
    # narrowing the history has asked a question about a series, not for a different comparison —
    # and `branch` says which branch this one was actually taken on, so the two cannot be confused.
    # @intent: { entity: "directory_run_growth", action: "ignore a branch parameter for anchoring", behavior: "a branch ask narrows history but never re-anchors the comparison, which keeps naming the latest run own branch and shas", layer: "request" }
    it "keeps naming the latest run's branch under a ?branch= that names another" do
      window, block = blocks(query: { branch: "main" })

      expect(window).to include("branch" => "feature/x", "anchor_commit_sha" => "feature00002",
                                "baseline_commit_sha" => "feature00001")
      expect(row_at(block, "spec/models")["change"]).to eq(3)
      # While `history` DID narrow in the same body, so the request really did carry the parameter.
      expect(get_repository(query: { branch: "main" })["history"].map { |row| row["commit_sha"] })
        .to eq(%w[maininterlv1])
    end
  end

  # ⭐ CRITERION 3 AND CRITERION 4 — THE NINE STATES, SWEPT AT ONCE.
  #
  # Swept across one table rather than as nine examples, because the defect this guards against is
  # two states COLLAPSING INTO ONE — which no single-state example can see. `state` is the block's
  # whole answer in eight of the nine, and the sweep is what pins that the eight are eight.
  describe "the states a comparison can fail in" do
    # Each shape on its own repository, so the "latest" run of one cannot become the "previous" run
    # of another. One API key per repository, taken from the repository itself.
    def state_of(repo)
      window, block = blocks(repo: repo)
      [window["state"], window["comparable"], block]
    end

    def fresh_repository = create_repository(user: @user, github_full_name: "acme/r#{SecureRandom.hex(4)}")

    # @intent: { entity: "directory_run_growth", action: "name the applicable failure state", behavior: "the nine shapes from missing runs to unrecorded rows each get a distinct state token with comparable false and a null rows block, comparable alone serving rows", layer: "request" }
    it "names which of the nine applies, and serves no rows in any but the last" do
      # SERIALIZER-LEVEL, and NOT model states: `SpecDirectoryGrowth.for` dereferences its second
      # argument on its second line and has no nil state of its own.
      no_latest = fresh_repository
      no_previous = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => 2 }, commit_sha: "onlyrun00001", at: 10.days.ago, repo: repo)
      end
      unbranched = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => 2 }, commit_sha: "unbranched01", at: 20.days.ago, repo: repo,
                     branch: nil)
        ingest_areas({ "spec/models" => 5 }, commit_sha: "unbranched02", at: 10.days.ago, repo: repo,
                     branch: nil)
      end
      # THE THREE PRE-QUERY STATES, decided from the two runs alone.
      latest_unmeasured = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => 2 }, commit_sha: "measured0001", at: 20.days.ago, repo: repo)
        ingest(repo, [], commit_sha: "nototals0001", at: 10.days.ago, total: 0)
      end
      previous_unmeasured = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "nototals0002", at: 20.days.ago, total: 0)
        ingest_areas({ "spec/models" => 2 }, commit_sha: "measured0002", at: 10.days.ago, repo: repo)
      end
      assembled_differently = fresh_repository.tap do |repo|
        run = ingest_areas({ "spec/models" => 2 }, commit_sha: "sharded00001", at: 20.days.ago,
                           repo: repo)
        2.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 1) }
        ingest_areas({ "spec/models" => 5 }, commit_sha: "unsharded001", at: 10.days.ago, repo: repo)
      end
      # THE THREE ROW-DECIDED STATES: a run can report a suite size and write no per-example rows,
      # which is a client that posts only totals.
      neither_recorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 40)
        ingest(repo, [], commit_sha: "totalsonly02", at: 10.days.ago, total: 40)
      end
      previous_unrecorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly03", at: 20.days.ago, total: 40)
        ingest_areas({ "spec/models" => 2 }, commit_sha: "recorded0001", at: 10.days.ago, repo: repo)
      end
      latest_unrecorded = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => 2 }, commit_sha: "recorded0002", at: 20.days.ago, repo: repo)
        ingest(repo, [], commit_sha: "totalsonly04", at: 10.days.ago, total: 40)
      end
      comparable = fresh_repository.tap { |repo| adjacent_runs(repo: repo) }

      states = {
        "no_latest_run" => no_latest, "no_previous_run" => no_previous,
        "unbranched" => unbranched, "latest_unmeasured" => latest_unmeasured,
        "previous_unmeasured" => previous_unmeasured,
        "assembled_differently" => assembled_differently, "neither_recorded" => neither_recorded,
        "previous_unrecorded" => previous_unrecorded, "latest_unrecorded" => latest_unrecorded,
        "comparable" => comparable
      }.transform_values { |repo| state_of(repo) }

      expect(states).to eq(
        "no_latest_run" => ["no_latest_run", false, nil],
        "no_previous_run" => ["no_previous_run", false, nil],
        # A latest run whose client sent no branch is `no_previous_run` too — there is no branch to
        # compare on, and `Repository#previous_test_run_on_branch` refuses to pool anonymous runs
        # from every branch and every machine into one fictional history. The two shapes are told
        # apart by `branch`, asserted just below, rather than by a tenth token.
        "unbranched" => ["no_previous_run", false, nil],
        "latest_unmeasured" => ["latest_unmeasured", false, nil],
        "previous_unmeasured" => ["previous_unmeasured", false, nil],
        "assembled_differently" => ["assembled_differently", false, nil],
        "neither_recorded" => ["neither_recorded", false, nil],
        "previous_unrecorded" => ["previous_unrecorded", false, nil],
        "latest_unrecorded" => ["latest_unrecorded", false, nil],
        "comparable" => ["comparable", true, states["comparable"].last]
      )
      # ⭐ CRITERION 3, THE HALF THE TABLE ABOVE CANNOT STATE: `no_previous_run` is a DISTINCT token
      # from `previous_unmeasured`, and they are different repairs — "there is nothing to compare
      # against" against "the run we compared against reported no tests".
      expect(states["no_previous_run"].first).not_to eq(states["previous_unmeasured"].first)
      # And the two shapes of `no_previous_run` are separable by the block itself.
      expect(blocks(repo: no_previous).first["branch"]).to eq("main")
      expect(blocks(repo: unbranched).first["branch"]).to be_nil
      expect(blocks(repo: no_latest).first["branch"]).to be_nil
      # The comparable one really did compare, so "no rows in any but the last" is a refusal of
      # something real rather than nine nulls and a tenth.
      expect(states["comparable"].last["rows"].length).to eq(3)
    end

    # THE KEY-ALWAYS-PRESENT RULE, asserted where nulling the rows block could quietly break it: the
    # contract block goes to the SAME KEY SET in an absence state as in a comparison, rather than
    # going absent or going short. A block that explains a `null` is worthless if it is itself
    # absent whenever the `null` happens.
    # @intent: { entity: "directory_run_growth_window", action: "keep the contract key set constant", behavior: "the contract block serves the same keys with no comparison as with one, so the explanation of a null never goes absent when the null happens", layer: "request" }
    it "serves the same contract keys with no comparison as with one" do
      absent = fresh_repository
      compared = fresh_repository.tap { |repo| adjacent_runs(repo: repo) }

      absent_window, absent_block = blocks(repo: absent)
      compared_window, compared_block = blocks(repo: compared)

      expect(absent_window.keys).to match_array(compared_window.keys)
      expect(absent_window).to include("state" => "no_latest_run", "comparable" => false,
                                       "branch" => nil, "anchor_commit_sha" => nil,
                                       "baseline_commit_sha" => nil,
                                       "order" => "abs_change_desc,path_asc",
                                       "tie_break_served" => true, "basis" => "previous_run_on_branch",
                                       "branch_scope" => "single_branch")
      # `null` and never an empty block of zeroes: "we could not compare" must not serialize as "we
      # compared and nothing moved" — and it must not invent the denominators either.
      expect(absent_block).to be_nil
      expect(compared_block).not_to be_nil
    end

    # ⭐ WHY THE ROWS BLOCK IS `null` RATHER THAN A BLOCK OF ZEROES, stated as the assertion that
    # would fail if it were not. `SpecDirectoryGrowth.from_tuples` returns its row-decided states
    # WITHOUT the counts it just read, so every aggregate falls back to its `0` default: serving
    # them raw would print `anchor_recorded_count: 0` for a latest run that recorded four hundred
    # rows. The state token is the actionable half, and it is served one key up.
    # @intent: { entity: "directory_run_growth", action: "withhold denominators rather than zero them", behavior: "in a row-decided state the block is null instead of printing zero counts that the dropped aggregates would have fabricated", layer: "request" }
    it "withholds the denominators in a state whose object dropped them, rather than serving zeroes" do
      ingest(repository, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 400)
      ingest_areas({ "spec/models" => 400 }, commit_sha: "recorded0001", at: 10.days.ago)

      window, block = blocks

      expect(window["state"]).to eq("previous_unrecorded")
      expect(block).to be_nil
      # The latest run really did record four hundred rows, which is the figure a zeroed block would
      # have contradicted — it is served, correctly, by the single-run grain next door.
      expect(get_repository["latest_run"]["spec_directories"]["rows"]
               .sum { |area| area["recorded_count"] }).to eq(400)
    end
  end

  # ⭐ CRITERION 5 — ADDED BESIDE, NEVER IN PLACE OF.
  describe "against the window pair it sits beside" do
    before { adjacent_runs }

    # The two pairs answer DIFFERENT QUESTIONS and are gated differently, and this is the body where
    # that is most visible: unfiltered, the window pair declines (its gate is `?branch=`) and the new
    # pair compares. Every `directory_growth*` value is stated in full rather than by `include`, so a
    # change to either key is a red example here.
    # @intent: { entity: "directory_growth pair", action: "leave the window pair untouched", behavior: "an unfiltered request still declines the branch-gated window pair and gets the run-over-run rows, with every directory_growth value byte-identical to before", layer: "request" }
    it "leaves directory_growth and directory_growth_window exactly as they were" do
      body = get_repository

      expect(body["directory_growth_window"]).to eq(
        "order" => "abs_change_desc,path_asc", "tie_break_served" => true,
        "basis" => "two_endpoints", "branch_scope" => "all_branches", "branch" => nil,
        "grouped" => false
      )
      expect(body["directory_growth"]).to be_nil
      # And the new pair answered the very request the old one declined.
      expect(body["directory_run_growth"]["rows"].length).to eq(3)
    end

    # Named, the window pair still answers exactly as it did — over its own window, with its own
    # basis token and its own state vocabulary, none of which the new pair touched.
    # @intent: { entity: "directory_growth pair", action: "serve both pairs distinctly under a branch", behavior: "with a branch ask the window pair answers over its own basis tokens and at two runs the two pairs agree on rows while their basis tokens still differ", layer: "request" }
    it "leaves the window pair's own answer alone under ?branch=" do
      body = get_repository(query: { branch: "main" })

      expect(body["directory_growth_window"]).to include("basis" => "two_endpoints",
                                                         "branch_scope" => "single_branch",
                                                         "grouped" => true)
      expect(body["directory_growth"]).to include("state" => "comparable", "window_run_count" => 2,
                                                  "covered_run_count" => 2, "runs_back" => 1,
                                                  "shortened" => false,
                                                  "anchor_commit_sha" => "latest000001",
                                                  "baseline_commit_sha" => "previous0001")
      # At two runs the two pairs necessarily agree on the rows — the window's two ENDS ARE the two
      # adjacent runs — so this is the one fixture where they can be compared directly. It is stated
      # because it is the check that the shared row serializer is genuinely shared.
      expect(body["directory_run_growth"]["rows"]).to eq(body["directory_growth"]["rows"])
      # And their BASIS tokens still differ, so a client is never told the two are one measurement.
      expect(body["directory_run_growth_window"]["basis"]).to eq("previous_run_on_branch")
    end

    # THE TWO PAIRS SEPARATE THE MOMENT A THIRD RUN EXISTS — the assertion that the example above is
    # an agreement at two runs and not a duplicated key. `spec/models` moved 1 → 9 → 4: the window
    # spans the ends (+3) and this pair spans the newest two (−5).
    # @intent: { entity: "directory_run_growth", action: "diverge from the window pair", behavior: "once a run sits between the window ends the two pairs report different operands for the same area, proving they are separate measurements", layer: "request" }
    it "answers differently from the window pair once there is a run between the ends" do
      ingest_areas({ "spec/models" => 9, "spec/services" => 2, "spec/jobs" => 2 },
                   commit_sha: "middle000001", at: 15.days.ago)

      body = get_repository(query: { branch: "main" })
      window_change = body["directory_growth"]["rows"].find { |row| row["path"] == "spec/models" }
      run_change = body["directory_run_growth"]["rows"].find { |row| row["path"] == "spec/models" }

      expect(window_change).to include("baseline_count" => 1, "anchor_count" => 4, "change" => 3)
      expect(run_change).to include("baseline_count" => 9, "anchor_count" => 4, "change" => -5)
    end
  end

  # CRITERION 1's other half, and CRITERION 7's — the API and the dashboard cannot name different
  # numbers for the same repository. Read off the RENDERED PAGE rather than off a second call to
  # `SpecDirectoryGrowth`, which would only compare the endpoint against itself.
  describe "against what repositories#show prints" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-directory-growth")
      panel.all("tbody tr").map do |row|
        path, baseline, anchor, change = row.all("td").map { |cell| cell.text.strip }
        { "path" => path, "baseline" => baseline, "anchor" => anchor, "change" => change }
      end
    end

    # @intent: { entity: "directory_run_growth", action: "match the dashboard panel figures", behavior: "the API rows and the rendered repositories#show panel name the same areas, operands and movements for the same repository and run", layer: "request" }
    it "names the same areas, with the same operands and the same movements" do
      adjacent_runs

      _window, block = blocks
      get repository_path(repository)

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
      # The panel is the one the dashboard renders with NO PARAMETER, which is the request the API
      # block was just read off too.
      expect(panel_rows.map { |row| row["change"] }).to include("±0", "−3", "+3")
    end

    # The panel prints the previous run's sha in its caption; the block serves it as a key. Same
    # run, so an agent reading the API and a human reading the page are looking at one comparison.
    # @intent: { entity: "directory_run_growth", action: "match the panel caption run", behavior: "the baseline_commit_sha the block serves is the run the panel caption prints, so both surfaces describe one comparison", layer: "request" }
    it "names the same previous run the panel's caption does" do
      adjacent_runs

      window, = blocks
      get repository_path(repository)
      caption = Capybara.string(response.body).find("#spec-directory-growth-basis").text.squish

      expect(window["baseline_commit_sha"]).to eq("previous0001")
      expect(caption).to include(window["baseline_commit_sha"].first(7))
      expect(caption).to include("the previous run on this branch")
    end
  end

  # CRITERION 7 — no `specguard-mcp` release is required, asserted as the property that makes it
  # true rather than as a claim about another repository. `src/tools/repository-overview.ts` renders
  # `JSON.stringify(overview, null, 2)` and returns the object verbatim as `structured`, so a key
  # reaches `get_repository_overview` if and only if it is a TOP-LEVEL key of this body.
  describe "what a passthrough client sees" do
    # @intent: { entity: "directory_run_growth", action: "land at the top level only", behavior: "both keys are added beside history and never nested inside latest_run, which keeps single-run facts single-run", layer: "request" }
    it "adds the pair at the top level, and nowhere else" do
      adjacent_runs

      body = get_repository

      expect(body.keys).to include("directory_run_growth_window", "directory_run_growth")
      # NEVER INSIDE `latest_run`, which is single-run facts by construction — the rule that block
      # states for itself, and the reason both growth pairs sit out here beside `history`.
      expect(body["latest_run"].keys).not_to include("directory_run_growth", "directory_run_growth_window")
      expect(strings_in(body["latest_run"])).not_to include("previous_run_on_branch")
    end
  end

  describe "what the run-over-run block costs the endpoint" do
    # ONE READ, and it is also the MEMOIZATION GUARD — the only form of one this endpoint can have.
    # `show` reads the presenter twice, once for the contract block's `state` and once for the rows,
    # so an unmemoized gate builds it twice and this count is two.
    #
    # MEASURED UNFILTERED, WHICH IS WHAT MAKES IT THIS BLOCK'S GUARD RATHER THAN A JOINT ONE. Both
    # growth blocks issue `SpecObservation.directory_growth_between`, so both land in the SAME grain
    # — `growth_grain_reads` cannot tell them apart by pattern. Unfiltered, the window pair is not
    # constructed at all, so the one read here is unambiguously this block's.
    # @intent: { entity: "directory_run_growth", action: "read the growth grain once", behavior: "an unparameterised request issues exactly one growth-grain spec_observations read, which also guards the presenter memoization", layer: "request" }
    it "reads spec_observations exactly once on an unparameterised request" do
      adjacent_runs
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key) }.length).to eq(1)
    end

    # And that one read is ALL it adds — the assertion a per-grain count cannot make, because a read
    # matching no grain's pattern is invisible to every one of them. The total is also asserted as
    # the SUM OF THE PARTS, so a read that stopped being issued and a different one that started
    # cannot cancel out into a passing number.
    # @intent: { entity: "directory_run_growth", action: "add exactly one classified read", behavior: "the per-grain partition accounts for every observation read on the request, and the total equals the sum of the classified parts", layer: "request" }
    it "adds exactly that one to the table's total, and no second" do
      adjacent_runs
      get_repository(key: api_key)

      area, file, example, description, flakiness, growth =
        observation_reads_by_grain { get_repository(key: api_key) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length]).to eq([1, 1, 2, 2, 0, 1])
      expect(observation_reads { get_repository(key: api_key) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key) })
    end

    # ⭐ CRITERION 3's COST HALF: a repository with nothing to compare asks `spec_observations`
    # NOTHING. The gate short-circuits before any read in five of the nine states — the two
    # serializer states never construct the object, and three of the model's own are decided from
    # the two runs alone.
    # @intent: { entity: "directory_run_growth", action: "skip reads with nothing to compare", behavior: "a repository whose state is decided from the runs alone issues no growth-grain read while the single-run grains keep reading", layer: "request" }
    it "reads spec_observations for this grain not at all where there is nothing to compare" do
      solo = create_repository(user: @user, github_full_name: "acme/solo")
      solo_key = solo.api_keys.create!
      ingest_areas({ "spec/models" => 2 }, commit_sha: "onlyrun00001", at: 10.days.ago, repo: solo)
      get_repository(repo: solo, key: solo_key)

      expect(growth_grain_reads { get_repository(repo: solo, key: solo_key) }).to be_empty
      # The zero above is this grain declining to read rather than the table having gone quiet — the
      # endpoint's single-run grains are untouched in the same request.
      expect(observation_reads { get_repository(repo: solo, key: solo_key) }).not_to be_empty
      expect(get_repository(repo: solo, key: solo_key)["directory_run_growth"]).to be_nil
    end

    # A repository CI has never reported on does not raise, and asks NOTHING — neither
    # `spec_observations` nor the previous-run lookup, which `Repository#previous_test_run_on_branch`
    # declines before any read when the run is nil.
    # @intent: { entity: "directory_run_growth", action: "ask nothing of a runless repository", behavior: "a repository CI never reported on answers 200 with no growth read and no previous-run lookup at all", layer: "request" }
    it "asks nothing at all of a repository with no runs" do
      empty = create_repository(user: @user, github_full_name: "acme/empty")
      empty_key = empty.api_keys.create!
      get_repository(repo: empty, key: empty_key)

      expect(response).to have_http_status(:ok)
      statements = executed_sql { get_repository(repo: empty, key: empty_key) }

      expect(growth_grain_reads { get_repository(repo: empty, key: empty_key) }).to be_empty
      expect(statements.grep(/\(test_runs\.created_at, test_runs\.id\) < /)).to be_empty
      expect(get_repository(repo: empty, key: empty_key)["directory_run_growth_window"])
        .to include("state" => "no_latest_run")
    end

    # The previous-run lookup is ONE indexed row, issued once and memoized — `show` reads it twice,
    # through the contract block's `baseline_commit_sha` and through the growth object. Matched on
    # the ROW-VALUE PREDICATE rather than on `"branch" = `, which `recent_test_runs` also emits
    # under `?branch=`: `(test_runs.created_at, test_runs.id) < (...)` is issued by
    # `Repository#previous_test_run_on_branch` and by nothing else this endpoint calls.
    # @intent: { entity: "directory_run_growth", action: "look up the previous run once", behavior: "the row-value-predicate previous-run lookup fires exactly once per request however many blocks read the baseline", layer: "request" }
    it "looks the previous run up exactly once" do
      adjacent_runs
      get_repository(key: api_key)

      statements = executed_sql { get_repository(key: api_key) }
      lookups = statements.grep(/\(test_runs\.created_at, test_runs\.id\) < /)

      expect(lookups.length).to eq(1)
      expect(get_repository(key: api_key)["directory_run_growth_window"]["baseline_commit_sha"])
        .to eq("previous0001")
    end

    # `Repository#latest_test_run` MEMOIZES NOTHING, and THREE readers now want that row —
    # `latest_run`, the contract block and the growth gate. Memoized at the controller, so the
    # endpoint pays for it once however many blocks read it.
    #
    # ASSERTED AS A TOTAL RATHER THAN PER-QUERY, because the anchor lookup and the history window
    # are the SAME SQL TEXT — both are `ORDER BY created_at DESC, id DESC LIMIT $2` over
    # `repository_id`, told apart only by a bind value the log does not carry. So the falsifiable
    # statement is the count: three reads of `test_runs` on this request — the anchor, the window,
    # and the previous-run lookup — and an unmemoized anchor makes it five.
    # @intent: { entity: "directory_run_growth", action: "select the latest run once", behavior: "test_runs is read three times total on the request and the anchor lookup is memoized at the controller however many blocks want it", layer: "request" }
    it "selects the latest run once, however many blocks read it" do
      adjacent_runs
      get_repository(key: api_key)

      statements = executed_sql { get_repository(key: api_key) }.grep(/FROM "test_runs"/)
      # `run_anchor`'s retention boundary is excluded from both counts, on the same rule the
      # row-value predicate excludes the previous-run lookup by: it is one indexed read ABOUT THE
      # ANCHORED RUN and not one of the three this example names, so folding it into the total would
      # rebaseline the number and hide the unmemoized-anchor regression the count exists to catch.
      # Told apart STRUCTURALLY — the only read carrying an OFFSET — and bounded at exactly ONE, so
      # the carve-out cannot swallow a per-row read.
      boundary = statements.grep(/OFFSET/)
      statements = statements.grep_v(/OFFSET/)
      anchor_shaped = statements.grep_v(/\(test_runs\.created_at, test_runs\.id\) < /)

      expect(boundary.length).to eq(1)
      expect(statements.length).to eq(3)
      expect(anchor_shaped.length).to eq(2)
    end

    # The cost does not follow the size of the suite: the aggregate is `GROUP BY` area over two run
    # ids in an `IN` list, and the row cap bounds what comes back. A relative pin rather than a
    # number that would need rebaselining.
    # @intent: { entity: "directory_run_growth", action: "stay flat as the suite grows", behavior: "ingesting a much larger run leaves the query count and the single growth read unchanged because the aggregate groups two run ids under a row cap", layer: "request" }
    it "costs the same one read as the suite grows" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      ingest_areas({ "spec/models" => 40, "spec/services" => 30, "spec/jobs" => 30 },
                   commit_sha: "biggerrun001", at: 1.day.ago)
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key) }.length).to eq(1)
      expect(count_queries { get_repository(key: api_key) }).to eq(baseline)
      expect(get_repository(key: api_key).dig("directory_run_growth", "anchor_recorded_count"))
        .to eq(100)
    end

    # Nor does it follow the length of the history — this pair reads the two newest rows and never
    # walks, so thirty runs cost what two do.
    # @intent: { entity: "directory_run_growth", action: "stay flat as history grows", behavior: "thirty runs cost the same single growth read as two since the pair reads only the two newest rows and never walks the history", layer: "request" }
    it "costs the same at 2 runs and at 30" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      28.times do |index|
        ingest_areas({ "spec/models" => 4, "spec/services" => 2, "spec/jobs" => 2 },
                     commit_sha: "filler0000#{format("%02d", index)}", at: (9 - (index * 0.1)).days.ago)
      end
      get_repository(key: api_key)

      expect(growth_grain_reads { get_repository(key: api_key) }.length).to eq(1)
      expect(count_queries { get_repository(key: api_key) }).to eq(baseline)
      # And the history really did grow, so the equality above is not two identical small ones.
      expect(get_repository(key: api_key)["history"].length)
        .to eq(Api::V1::RepositoriesController::HISTORY_LIMIT)
    end
  end
end
