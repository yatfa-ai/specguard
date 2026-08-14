# frozen_string_literal: true

require "rails_helper"

# The `directory_run_file_growth` pair on `GET /api/v1/repository` — the agent-readable half of the
# "Files that grew or shrank in this directory" panel `repositories#show` renders, and the rung
# below the pair `repository_directory_run_growth_spec.rb` covers.
#
# ITS OWN FILE, BESIDE THAT ONE RATHER THAN INSIDE IT, on the disposition those two sibling files
# already take. This pair is a DRILL-IN: it is gated on an ask that pair takes none of, it is
# capped by its own constant, and its whole subject — a file listed as new beside one listed as
# removed — is a shape the area grain cannot produce at all. What it shares with the parent is the
# comparability verdict, and the examples that matter most here are the ones asserting it is
# INHERITED rather than re-derived.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never
# inserted by hand — the rule every sibling file states, and for the same reason: every state this
# pair turns on is a state the recorder produces from what a real client sends.
RSpec.describe "GET /api/v1/repository — directory_run_file_growth", type: :request do
  # Signed in as well as keyed, because one example reads the HTML panel and the JSON blocks off the
  # same data and compares them field for field.
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
  def blocks(query: { spec_directory: "spec/models" }, **)
    body = get_repository(query: query, **)
    [body["directory_run_file_growth_window"], body["directory_run_file_growth"]]
  end

  # The sibling file's ingest helper verbatim, including the `total:` seam for the one state a real
  # client produces and a naive fixture cannot: a run that reports a suite size and sends no
  # per-example detail at all.
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

  # `{"spec/models/user_spec.rb" => 4}` — one run's payload holding four examples in that FILE. The
  # file is what this fixture controls, where the parent pair's controls the directory: an AREA is
  # the parent directory of `spec_file_path`, so a file's own path decides both.
  def examples_in(counts)
    counts.flat_map do |file_path, count|
      Array.new(count) do |index|
        unannotated_spec(file_path: file_path, line_number: index + 1,
                         name: "#{file_path} example #{index}", duration: 0.1)
      end
    end
  end

  def ingest_files(counts, commit_sha:, at:, repo: repository, branch: "main", **)
    ingest(repo, examples_in(counts), commit_sha: commit_sha, branch: branch, at: at, **)
  end

  # ⭐ THE TWO-RUN FIXTURE THIS FILE TURNS ON, oldest first, and every property of it is load
  # bearing:
  #
  # * `user_spec.rb` is NEW (absent then, 6 now) and `legacy_user_spec.rb` is REMOVED (6 then, none
  #   now) — THE RENAME SHAPE, which is the whole reason this grain exists. The area grain cannot
  #   produce it: both files are in `spec/models`, so one rung up this pair of movements is a single
  #   area at `±0` and is not even a row on that list.
  # * `order_spec.rb` GREW by 3 and `refund_spec.rb` SHRANK by 3, so the SIGN of every `change` is a
  #   fact the fixture can be wrong about — a symmetric pair would serialize identically under a
  #   comparison taken backwards and would pin nothing.
  # * Those two movements are EQUAL IN MAGNITUDE, so the `ABS(...) DESC` ranking between them is
  #   decided by the `path ASC` tie-break, which is the half of the order a client is told it can
  #   reproduce.
  # * `billing_spec.rb` holds 2 examples in both runs, so the list carries a file that did not move.
  # * `spec/services/payment_spec.rb` sits OUTSIDE the asked-for area in both runs and moves by 9 —
  #   the largest movement in the repository. It must never appear in these rows, and it is what
  #   makes "narrowed to one area" falsifiable rather than a claim about an untested predicate.
  # * BOTH RUNS RECORD 17 ROWS IN `spec/models`, so this AREA's own two denominators are identical
  #   while five of its files moved — the figures cannot be read off each other, and a caption built
  #   on them says nothing about the table. The SUITE totals do move (22 → 31), entirely outside the
  #   asked-for area, which is what keeps the area's denominators separable from the run's.
  def adjacent_runs(repo: repository, branch: "main")
    ingest_files({ "spec/models/legacy_user_spec.rb" => 6, "spec/models/order_spec.rb" => 3,
                   "spec/models/refund_spec.rb" => 6, "spec/models/billing_spec.rb" => 2,
                   "spec/services/payment_spec.rb" => 5 },
                 commit_sha: "previous0001", branch: branch, at: 20.days.ago, repo: repo)
    ingest_files({ "spec/models/user_spec.rb" => 6, "spec/models/order_spec.rb" => 6,
                   "spec/models/refund_spec.rb" => 3, "spec/models/billing_spec.rb" => 2,
                   "spec/services/payment_spec.rb" => 14 },
                 commit_sha: "latest000001", branch: branch, at: 10.days.ago, repo: repo)
  end

  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }

  # Every string these blocks serve, at any depth — the assertion surface for "operands, never the
  # labels". Walked rather than listed key by key, so a label-shaped value added to a row or to a
  # block later is caught by the same example rather than by nobody.
  def strings_in(value)
    case value
    when Hash then value.values.flat_map { |inner| strings_in(inner) }
    when Array then value.flat_map { |inner| strings_in(inner) }
    when String then [value]
    else []
    end
  end

  # ⭐ CRITERION 1 — THE DEAD END THE PARENT PAIR LEFT AN AGENT AT.
  describe "an area named under ?spec_directory=" do
    before { adjacent_runs }

    # The rows, in the order the read ranked them: absolute movement descending, `path ASC` between
    # equals. `user_spec.rb` and `legacy_user_spec.rb` both move by 6 and sort by path; `order_spec`
    # and `refund_spec` both move by 3 and sort by path; `billing_spec` did not move at all.
    it "names the files of the asked-for area, largest movement first" do
      window, block = blocks

      expect(window).to include("path" => "spec/models", "state" => "comparable",
                                "comparable" => true)
      expect(block["rows"].map { |row| row["path"] })
        .to eq(%w[spec/models/legacy_user_spec.rb spec/models/user_spec.rb
                  spec/models/order_spec.rb spec/models/refund_spec.rb
                  spec/models/billing_spec.rb])
    end

    # ⭐ THE SHAPE THIS GRAIN EXISTS FOR, and the one the rung above cannot produce. A file listed
    # as new beside one listed as removed is what a rename looks like from here — and the endpoint
    # asserts NEITHER reading, it serves both operands and both booleans and lets the caller pair
    # them. `new_file`/`removed_file` are not derivable from `change` alone, which is the point.
    it "puts a new file beside a removed one, where the area grain shows nothing at all" do
      _window, block = blocks

      expect(row_at(block, "spec/models/user_spec.rb")).to eq(
        "path" => "spec/models/user_spec.rb", "baseline_count" => 0, "anchor_count" => 6,
        "change" => 6, "moved" => true, "new_file" => true, "removed_file" => false
      )
      expect(row_at(block, "spec/models/legacy_user_spec.rb")).to eq(
        "path" => "spec/models/legacy_user_spec.rb", "baseline_count" => 6, "anchor_count" => 0,
        "change" => -6, "moved" => true, "new_file" => false, "removed_file" => true
      )
      # ⭐ AND THE AREA GRAIN, IN THE SAME BODY, HAS NOTHING TO SAY ABOUT IT: six examples left one
      # file and six arrived in another, both inside `spec/models`, so that area did not move and is
      # not on the parent list at all. This is the dead end, asserted rather than described.
      area_row = get_repository["directory_run_growth"]["rows"]
                   .find { |row| row["path"] == "spec/models" }
      expect(area_row).to include("baseline_count" => 17, "anchor_count" => 17, "change" => 0)
    end

    # The remaining three states of the row, so the six-field shape is pinned end to end.
    it "serves each file's two operands, their difference and the three states of it" do
      _window, block = blocks

      expect(row_at(block, "spec/models/order_spec.rb")).to eq(
        "path" => "spec/models/order_spec.rb", "baseline_count" => 3, "anchor_count" => 6,
        "change" => 3, "moved" => true, "new_file" => false, "removed_file" => false
      )
      expect(row_at(block, "spec/models/refund_spec.rb")).to eq(
        "path" => "spec/models/refund_spec.rb", "baseline_count" => 6, "anchor_count" => 3,
        "change" => -3, "moved" => true, "new_file" => false, "removed_file" => false
      )
      expect(row_at(block, "spec/models/billing_spec.rb")).to eq(
        "path" => "spec/models/billing_spec.rb", "baseline_count" => 2, "anchor_count" => 2,
        "change" => 0, "moved" => false, "new_file" => false, "removed_file" => false
      )
    end

    # ⭐ CRITERION 5's THIRD MUTATION — SWAPPING THE OPERANDS. Anchor is the LATEST run and baseline
    # the PREVIOUS one, which is the direction every `change` is signed in; handing the two runs to
    # `SpecDirectoryFileGrowth.for` the other way round turns `order_spec.rb` from `+3` into `−3`
    # AND turns the new file into a removed one.
    it "anchors on the latest run and baselines on the previous one" do
      _window, block = blocks

      expect(row_at(block, "spec/models/order_spec.rb")["change"]).to eq(3)
      expect(row_at(block, "spec/models/refund_spec.rb")["change"]).to eq(-3)
      expect(row_at(block, "spec/models/user_spec.rb")).to include("new_file" => true)
      expect(row_at(block, "spec/models/legacy_user_spec.rb")).to include("removed_file" => true)
      # And the run this pair anchors on is the one the SIBLING pair names in the same body, under
      # the vocabulary both share. The two blocks cannot be describing two different runs.
      expect(get_repository(query: { spec_directory: "spec/models" })
               .dig("directory_run_growth_window", "anchor_commit_sha")).to eq("latest000001")
    end

    # THE NARROW IS AN EQUALITY ON THE AREA, exactly as `SpecObservation.files_in_directory` is.
    # `spec/services/payment_spec.rb` moved by 9 — MORE than any file listed — and is absent, which
    # is what makes the predicate falsifiable: a read that dropped it would rank that file first.
    it "lists no file outside the area, however far outside it moved" do
      _window, block = blocks

      expect(block["rows"].map { |row| row["path"] }).to all(start_with("spec/models/"))
      expect(block["file_count"]).to eq(5)
      # The excluded file really did move further than every listed one, in the same two runs.
      expect(get_repository["directory_run_growth"]["rows"].find { |row| row["path"] == "spec/services" })
        .to include("change" => 9)
    end

    # The denominators are THIS AREA'S rows and deliberately not the whole-run figures the parent
    # block serves under identically-spelled names — a client mixing the two would divide an area's
    # population by the suite's. Here the two differ, which is what makes them separable at all.
    it "counts its denominators over the area, not over the run" do
      _window, block = blocks

      expect(block).to include("baseline_recorded_count" => 17, "anchor_recorded_count" => 17,
                               "file_count" => 5, "truncated" => false)
      # The parent block's identically-named keys, in the same body, are LARGER and MOVE where these
      # do not — they count every row either run wrote anywhere.
      expect(get_repository["directory_run_growth"])
        .to include("baseline_recorded_count" => 22, "anchor_recorded_count" => 31)
    end

    # OPERANDS, NEVER THE PANEL'S SPELLINGS. `SpecDirectoryFileGrowth::Row` carries `change_label`,
    # `change_reading`, `previous_count_label` and `latest_count_label` — typographic and
    # screen-reader spellings of these same numbers, including the "New file" the shape above
    # renders. A client served those would be splitting strings and stripping glyphs.
    it "serves no value the panel has worded, and no glyph it has typeset" do
      window, block = blocks

      expect(strings_in(block)).to all(start_with("spec/models/"))
      expect(strings_in(window)).to contain_exactly("spec/models", "abs_change_desc,path_asc",
                                                    "previous_run_on_branch", "comparable")
      # And the vocabulary being refused is real — this data makes the panel print all of it.
      expect(strings_in(block) + strings_in(window))
        .not_to include("±0", "−3", "+3", "New file", "File removed")
    end

    # The bound is this key's OWN constant — not the areas' ten and not the durations drill-down's
    # fifty — and it is served on the ALWAYS-PRESENT block, so a caller that got `null` can still
    # learn what a populated answer would have been capped at.
    it "discloses the bound that would cut the list, on the block that is always there" do
      window, block = blocks

      expect(window["limit"]).to eq(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      expect(window["limit"]).not_to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(block).not_to have_key("limit")
      # And it is still served where there is nothing to cut.
      expect(blocks(repo: create_repository(user: @user, github_full_name: "acme/bare")).first)
        .to include("limit" => SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
    end
  end

  describe "an area holding more files than the block lists" do
    it "serves the limit's worth of rows, and says how many files the comparison covered" do
      files = Array.new(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT + 2) do |index|
        "spec/models/thing_#{index}_spec.rb"
      end
      ingest_files(files.index_with { 1 }, commit_sha: "previous0001", at: 20.days.ago)
      ingest_files(files.index_with { 3 }, commit_sha: "latest000001", at: 10.days.ago)

      window, block = blocks

      expect(block["rows"].length).to eq(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      expect(block).to include("truncated" => true,
                               "file_count" => SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT + 2)
      # ⭐ COUNTED BEFORE THE `LIMIT`, so the caption a client builds cannot disagree with the rows
      # it was handed: `file_count` exceeds the rows on hand, and the denominators cover every file
      # the comparison covered rather than the ones that fit.
      expect(block["file_count"]).to be > block["rows"].length
      expect(block["anchor_recorded_count"])
        .to eq((SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT + 2) * 3)
      expect(window["limit"]).to eq(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
    end
  end

  # ⭐ THE TWO WAYS THE ROWS BLOCK CAN BE `null`, AND THE KEY THAT TELLS THEM APART.
  describe "the ask" do
    before { adjacent_runs }

    # ⭐ CRITERION 2 — no ask, no keys' worth of content and no query. `path: null` is the spelling
    # of "you did not ask", and it is a different fact from "the comparison refused", which the very
    # next example produces on the same repository.
    it "serves null rows with a null path when no area was named" do
      window, block = blocks(query: {})

      expect(window).to include("path" => nil, "state" => "comparable", "comparable" => true)
      expect(block).to be_nil
      # ⭐ AND THAT IS THE DISCRIMINATOR DOING WORK: `comparable` is TRUE here — the two runs
      # compare fine — so a client reading `comparable` alone would expect rows. The reason there
      # are none is the null `path`, and nothing else in the body says so.
      expect(window["comparable"]).to be(true)
    end

    # A malformed shape is NO ASK AT ALL — `RequestedSpecDirectoryParam`'s rule, which is why `path`
    # is never echoed from the raw parameter but restated as the server read it.
    it "treats a shape that is not a string as no ask" do
      window, block = blocks(query: { spec_directory: ["spec/models"] })

      expect(window["path"]).to be_nil
      expect(block).to be_nil
    end

    # An area NEITHER RUN RECORDED is an ordinary answer and not an error — a stale bookmark, a
    # directory deleted since, a typo. The comparison is comparable, the ask is restated, and the
    # rows are simply empty. Distinct from every refusal below, and distinct from no ask at all.
    it "answers an area neither run touched with an empty list, not a null and not an error" do
      window, block = blocks(query: { spec_directory: "spec/ghosts" })

      expect(response).to have_http_status(:ok)
      expect(window).to include("path" => "spec/ghosts", "state" => "comparable",
                                "comparable" => true)
      expect(block).to include("rows" => [], "file_count" => 0, "truncated" => false,
                               "baseline_recorded_count" => 0, "anchor_recorded_count" => 0)
    end

    # A NESTED area is its own area, because the narrow is an EQUALITY on the immediate parent
    # directory rather than a prefix `LIKE` — the same definition of "area" the sibling drill-in
    # and the parent panel use, so one ask cannot open two blocks that disagree about what an area
    # is.
    it "treats a subdirectory as its own area rather than part of its parent's" do
      ingest_files({ "spec/models/orders/refund_spec.rb" => 4 }, commit_sha: "nested000001",
                   at: 5.days.ago)

      _window, parent = blocks(query: { spec_directory: "spec/models" })
      _window, nested = blocks(query: { spec_directory: "spec/models/orders" })

      expect(parent["rows"].map { |row| row["path"] })
        .not_to include("spec/models/orders/refund_spec.rb")
      expect(nested["rows"].map { |row| row["path"] }).to eq(["spec/models/orders/refund_spec.rb"])
    end

    # ONE ASK, TWO BLOCKS — `?spec_directory=` is deliberately not split in two. The durations
    # drill-in inside `latest_run` and this growth drill-in answer the SAME ask in different grains,
    # and they name the same area.
    it "opens the durations drill-in and this one off the one parameter" do
      body = get_repository(query: { spec_directory: "spec/models" })

      expect(body["latest_run"]["spec_directory_files"]["path"]).to eq("spec/models")
      expect(body["directory_run_file_growth_window"]["path"]).to eq("spec/models")
      # The two answer in different grains off the same ask: one run's wall clock per file, and the
      # movement of each file since the previous run.
      expect(body["latest_run"]["spec_directory_files"]["rows"].first.keys)
        .to include("total_seconds", "timed_count")
      expect(body["directory_run_file_growth"]["rows"].first.keys)
        .to include("baseline_count", "anchor_count", "change")
      # And no THIRD parameter was introduced to open this one.
      expect(body["directory_run_file_growth_window"].keys).not_to include("spec_file_directory")
    end
  end

  # ⭐ CRITERION 3 AND CRITERION 5's FIRST MUTATION — THE VERDICT IS INHERITED, NOT RE-DERIVED.
  #
  # Swept across one table rather than as ten examples, because the defect this guards against is
  # two states COLLAPSING INTO ONE, which no single-state example can see. Every one of these is
  # asked WITH `?spec_directory=` set, which is what makes them this block's states rather than the
  # parent's.
  describe "the states the parent comparison can refuse in" do
    def state_of(repo)
      window, block = blocks(repo: repo)
      [window["state"], window["comparable"], window["path"], block]
    end

    def fresh_repository = create_repository(user: @user, github_full_name: "acme/r#{SecureRandom.hex(4)}")

    # ⭐ THE ⚠️ THE HTML CALL SITE IS STRUCTURALLY IMMUNE TO. `repositories#show` reaches
    # `SpecDirectoryFileGrowth.for` only inside `if @latest_test_run && @previous_test_run`; this
    # endpoint serves the key on every request, and `.for` dereferences its `growth:` argument on
    # its first line. The two SERIALIZER-LEVEL states are therefore the ones that raise if the
    # controller does not guard the nil itself, and they are asked here WITH the parameter set —
    # which is the only way to reach the call at all.
    it "names which state applies, serves no rows in any but the last, and raises in none" do
      no_latest = fresh_repository
      no_previous = fresh_repository.tap do |repo|
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "onlyrun00001",
                     at: 10.days.ago, repo: repo)
      end
      unbranched = fresh_repository.tap do |repo|
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "unbranched01",
                     at: 20.days.ago, repo: repo, branch: nil)
        ingest_files({ "spec/models/user_spec.rb" => 5 }, commit_sha: "unbranched02",
                     at: 10.days.ago, repo: repo, branch: nil)
      end
      # THE THREE PRE-QUERY STATES, decided from the two runs alone.
      latest_unmeasured = fresh_repository.tap do |repo|
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "measured0001",
                     at: 20.days.ago, repo: repo)
        ingest(repo, [], commit_sha: "nototals0001", at: 10.days.ago, total: 0)
      end
      previous_unmeasured = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "nototals0002", at: 20.days.ago, total: 0)
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "measured0002",
                     at: 10.days.ago, repo: repo)
      end
      assembled_differently = fresh_repository.tap do |repo|
        run = ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "sharded00001",
                           at: 20.days.ago, repo: repo)
        2.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 1) }
        ingest_files({ "spec/models/user_spec.rb" => 5 }, commit_sha: "unsharded001",
                     at: 10.days.ago, repo: repo)
      end
      # THE THREE ROW-DECIDED STATES: a run can report a suite size and write no per-example rows.
      neither_recorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 40)
        ingest(repo, [], commit_sha: "totalsonly02", at: 10.days.ago, total: 40)
      end
      previous_unrecorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly03", at: 20.days.ago, total: 40)
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "recorded0001",
                     at: 10.days.ago, repo: repo)
      end
      latest_unrecorded = fresh_repository.tap do |repo|
        ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "recorded0002",
                     at: 20.days.ago, repo: repo)
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
        # ⭐ THE TWO SERIALIZER-LEVEL STATES — the nil-growth path, which is the failure mode the
        # HTML call site cannot reach. A `NoMethodError` here would be a 500 rather than these rows.
        "no_latest_run" => ["no_latest_run", false, "spec/models", nil],
        "no_previous_run" => ["no_previous_run", false, "spec/models", nil],
        "unbranched" => ["no_previous_run", false, "spec/models", nil],
        "latest_unmeasured" => ["latest_unmeasured", false, "spec/models", nil],
        "previous_unmeasured" => ["previous_unmeasured", false, "spec/models", nil],
        "assembled_differently" => ["assembled_differently", false, "spec/models", nil],
        "neither_recorded" => ["neither_recorded", false, "spec/models", nil],
        "previous_unrecorded" => ["previous_unrecorded", false, "spec/models", nil],
        "latest_unrecorded" => ["latest_unrecorded", false, "spec/models", nil],
        "comparable" => ["comparable", true, "spec/models", states["comparable"].last]
      )
      # The comparable one really did compare, so "no rows in any but the last" refuses something
      # real rather than nine nulls and a tenth.
      expect(states["comparable"].last["rows"].length).to eq(5)
      # ⭐ CRITERION 5's FIRST MUTATION, stated where it can fail: the state is the PARENT'S,
      # verbatim, in every one of the ten. A drill-in that re-derived it from its own narrowed rows
      # would answer `previous_unrecorded` for an area only the latest run recorded — a true
      # statement about the area and a false one about the run.
      expect(states.transform_values(&:first))
        .to eq(states.keys.index_with do |name|
          get_repository(repo: { "no_latest_run" => no_latest, "no_previous_run" => no_previous,
                                 "unbranched" => unbranched,
                                 "latest_unmeasured" => latest_unmeasured,
                                 "previous_unmeasured" => previous_unmeasured,
                                 "assembled_differently" => assembled_differently,
                                 "neither_recorded" => neither_recorded,
                                 "previous_unrecorded" => previous_unrecorded,
                                 "latest_unrecorded" => latest_unrecorded,
                                 "comparable" => comparable }.fetch(name),
                         query: { spec_directory: "spec/models" })
            .dig("directory_run_growth_window", "state")
        end)
    end

    # ⭐ THE STATE THAT WOULD BE RE-DERIVED WRONG, isolated. `spec/new_area` exists ONLY in the
    # latest run, so its previous side has zero rows — which a drill-in deriving its own state from
    # its own read would spell `previous_unrecorded`, announcing that the earlier run recorded
    # nothing ANYWHERE. The previous run recorded plenty; it recorded none of it here.
    it "calls an area only the latest run recorded comparable, not previous_unrecorded" do
      ingest_files({ "spec/models/user_spec.rb" => 4 }, commit_sha: "previous0001", at: 20.days.ago)
      ingest_files({ "spec/models/user_spec.rb" => 4, "spec/new_area/thing_spec.rb" => 7 },
                   commit_sha: "latest000001", at: 10.days.ago)

      window, block = blocks(query: { spec_directory: "spec/new_area" })

      expect(window).to include("state" => "comparable", "comparable" => true)
      expect(block["rows"]).to eq([{ "path" => "spec/new_area/thing_spec.rb", "baseline_count" => 0,
                                     "anchor_count" => 7, "change" => 7, "moved" => true,
                                     "new_file" => true, "removed_file" => false }])
      # And the previous run did record rows — elsewhere. That is the fact a re-derived state would
      # have contradicted.
      expect(get_repository["directory_run_growth"]["baseline_recorded_count"]).to eq(4)
    end

    # THE KEY-ALWAYS-PRESENT RULE, asserted where nulling the rows block could quietly break it: the
    # contract block goes to the SAME KEY SET with no comparison as with one, and with no ask as
    # with one. A block that explains a `null` is worthless if it is itself absent whenever the
    # `null` happens — and here the commonest request of all is one that produces the `null`.
    it "serves the same contract keys with no comparison, no ask, and a full answer" do
      absent = fresh_repository
      compared = fresh_repository.tap { |repo| adjacent_runs(repo: repo) }

      absent_window, absent_block = blocks(repo: absent)
      unasked_window, unasked_block = blocks(repo: compared, query: {})
      compared_window, compared_block = blocks(repo: compared)

      expect(absent_window.keys).to match_array(compared_window.keys)
      expect(unasked_window.keys).to match_array(compared_window.keys)
      expect(absent_window).to eq(
        "path" => "spec/models", "order" => "abs_change_desc,path_asc", "tie_break_served" => true,
        "basis" => "previous_run_on_branch", "state" => "no_latest_run", "comparable" => false,
        "limit" => SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT
      )
      # `null` and never an empty block of zeroes, in both of the two ways to have no rows.
      expect(absent_block).to be_nil
      expect(unasked_block).to be_nil
      expect(compared_block).not_to be_nil
    end

    # ⭐ CRITERION 5's SECOND MUTATION — serving a row-decided state with its counts zeroed.
    # `SpecDirectoryFileGrowth.for` returns `new(path:, state:)` for a refusing parent, WITHOUT any
    # of the counts, so every aggregate falls back to its `0` default. Serving them raw would print
    # `anchor_recorded_count: 0` for a latest run that recorded four hundred rows in that very area.
    it "withholds the denominators in a state whose object dropped them, rather than serving zeroes" do
      ingest(repository, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 400)
      ingest_files({ "spec/models/user_spec.rb" => 400 }, commit_sha: "recorded0001",
                   at: 10.days.ago)

      window, block = blocks

      expect(window["state"]).to eq("previous_unrecorded")
      expect(block).to be_nil
      # The latest run really did record four hundred rows IN THIS AREA — the figure a zeroed block
      # would have contradicted. Served, correctly, by the single-run drill-in next door under the
      # same ask.
      expect(get_repository(query: { spec_directory: "spec/models" })
               .dig("latest_run", "spec_directory_files", "recorded_count")).to eq(400)
    end
  end

  # ⭐ CRITERION 6 — ADDED BESIDE, NEVER IN PLACE OF. Every neighbouring value stated in FULL rather
  # than by `include`, so a change to any of them is a red example here.
  describe "the blocks it was added beside" do
    before { adjacent_runs }

    it "leaves directory_run_growth and its window byte-identical, asked and unasked" do
      unasked = get_repository
      asked = get_repository(query: { spec_directory: "spec/models" })

      expect(asked["directory_run_growth_window"]).to eq(
        "order" => "abs_change_desc,path_asc", "tie_break_served" => true,
        "basis" => "previous_run_on_branch", "branch_scope" => "single_branch", "branch" => "main",
        "state" => "comparable", "comparable" => true, "anchor_commit_sha" => "latest000001",
        "baseline_commit_sha" => "previous0001"
      )
      expect(asked["directory_run_growth"]).to eq(
        "rows" => [
          { "path" => "spec/services", "baseline_count" => 5, "anchor_count" => 14, "change" => 9,
            "moved" => true, "new_area" => false, "removed_area" => false },
          { "path" => "spec/models", "baseline_count" => 17, "anchor_count" => 17, "change" => 0,
            "moved" => false, "new_area" => false, "removed_area" => false }
        ],
        "directory_count" => 2, "truncated" => false, "baseline_recorded_count" => 22,
        "anchor_recorded_count" => 31, "limit" => SpecObservation::MOVED_DIRECTORIES_LIMIT
      )
      # BYTE-IDENTICAL UNDER THE ASK — the drill-in did not re-anchor, re-narrow or re-order its
      # parent, which is the one way a drill-in most easily damages the block it drills out of.
      expect(asked["directory_run_growth"]).to eq(unasked["directory_run_growth"])
      expect(asked["directory_run_growth_window"]).to eq(unasked["directory_run_growth_window"])
      # And the window pair, whose gate is `?branch=`, still declines the same request.
      expect(asked["directory_growth"]).to be_nil
    end

    # The single-run drill-in answering the SAME parameter is untouched — the two share an ask and
    # nothing else, and this pins that sharing one parameter did not merge two answers.
    it "leaves latest_run.spec_directory_files byte-identical under the shared ask" do
      served = get_repository(query: { spec_directory: "spec/models" })
                 .dig("latest_run", "spec_directory_files")

      expect(served["path"]).to eq("spec/models")
      expect(served["rows"].map { |row| row["path"] })
        .to eq(%w[spec/models/order_spec.rb spec/models/user_spec.rb spec/models/refund_spec.rb
                  spec/models/billing_spec.rb])
      expect(served).to include("file_count" => 4, "recorded_count" => 17, "timed_count" => 17,
                                "limit" => SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
      # ⭐ AND IT IS THE LATEST RUN'S FILES, where the new block's are EITHER run's — four against
      # five. The removed file is on one list and not the other, which is the clearest statement
      # that these are two different questions under one ask.
      expect(blocks.last["rows"].map { |row| row["path"] })
        .to include("spec/models/legacy_user_spec.rb")
      expect(served["rows"].map { |row| row["path"] }).not_to include("spec/models/legacy_user_spec.rb")
    end
  end

  # ⭐ CRITERION 4 — THE API AND THE PANEL CANNOT NAME DIFFERENT NUMBERS FOR THE SAME AREA. Read off
  # the RENDERED PAGE rather than off a second call to `SpecDirectoryFileGrowth`, which would only
  # compare the endpoint against itself.
  describe "against what repositories#show prints" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-directory-file-growth")
      panel.all("tbody tr").map do |row|
        path, baseline, anchor, change = row.all("td").map { |cell| cell.text.strip }
        { "path" => path, "baseline" => baseline, "anchor" => anchor, "change" => change }
      end
    end

    it "names the same files, with the same operands and the same movements" do
      adjacent_runs

      _window, block = blocks
      get repository_path(repository, spec_directory: "spec/models")

      # The page prints the labels; the block serves the operands. Both readings are assembled here
      # so a drift in either surface is a red example rather than two numbers nobody compared.
      served = block["rows"].map do |row|
        { "path" => row["path"],
          "baseline" => row["baseline_count"].to_s,
          "anchor" => row["anchor_count"].to_s,
          "change" => if row["new_file"] then "New file"
                      elsif row["removed_file"] then "File removed"
                      elsif row["change"].zero? then "±0"
                      elsif row["change"].negative? then "−#{row["change"].abs}"
                      else "+#{row["change"]}"
                      end }
      end

      expect(panel_rows).to eq(served)
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(served.length).to eq(5)
      # And this fixture makes the panel print every reading the mapping above covers.
      expect(panel_rows.map { |row| row["change"] })
        .to include("New file", "File removed", "±0", "−3", "+3")
    end

    # The panel prints the area's two denominators and its file count in its caption; the block
    # serves them as keys. Same figures, so an agent reading the API and a human reading the page
    # are looking at one comparison of one area.
    it "names the same area, the same file count and the same denominators the caption states" do
      adjacent_runs

      _window, block = blocks
      get repository_path(repository, spec_directory: "spec/models")
      caption = Capybara.string(response.body).find("#spec-directory-file-growth-basis").text.squish

      expect(caption).to include("all #{block["file_count"]} spec files")
      expect(caption).to include("#{block["baseline_recorded_count"]} and " \
                                 "#{block["anchor_recorded_count"]} example rows")
      expect(caption).to include("spec/models")
    end
  end

  # CRITERION 7 — no `specguard-mcp` release is required, asserted as the property that makes it
  # true rather than as a claim about another repository. `src/tools/repository-overview.ts` already
  # forwards `spec_directory` and renders `JSON.stringify(overview, null, 2)`, returning the object
  # verbatim with no output schema — so a key reaches `get_repository_overview` if and only if it is
  # a TOP-LEVEL key of this body.
  describe "what a passthrough client sees" do
    it "adds the pair at the top level, and nowhere else" do
      adjacent_runs

      body = get_repository(query: { spec_directory: "spec/models" })

      expect(body.keys).to include("directory_run_file_growth_window", "directory_run_file_growth")
      # NEVER INSIDE `latest_run`, which is single-run facts by construction — even though the ask
      # that opens this block also opens a drill-in that DOES live in there.
      expect(body["latest_run"].keys)
        .not_to include("directory_run_file_growth", "directory_run_file_growth_window")
      expect(strings_in(body["latest_run"])).not_to include("previous_run_on_branch")
      # And the pair sits beside its parent rather than nested inside it — a passthrough client
      # reaches a nested key only by walking, which is the walk this endpoint's growth blocks avoid.
      expect(body["directory_run_growth"].keys)
        .not_to include("directory_run_file_growth", "file_growth", "rows_by_file")
    end
  end

  describe "what the per-file block costs the endpoint" do
    # ⭐ CRITERION 2's COST HALF: NO ASK, NO QUERY. The gate is decided from the params before any
    # read is issued, so a client that never sends the parameter pays nothing for the key's
    # existence — on a repository whose comparison is perfectly comparable, which is what makes the
    # zero the ASK's refusal rather than the comparison's.
    it "adds no query at all to a request that names no area" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      expect(directory_file_growth_grain_reads { get_repository(key: api_key) }).to be_empty
      expect(count_queries { get_repository(key: api_key) }).to eq(baseline)
      # The comparison really was available — the parent block answered in the same request.
      expect(get_repository(key: api_key)["directory_run_growth"]["rows"].length).to eq(2)
      expect(get_repository(key: api_key)["directory_run_file_growth"]).to be_nil
    end

    # ONE READ WHEN ASKED. Deliberately NOT a memoization guard: this accessor has a single call
    # site, because the contract block reads the PARENT rather than this object, so an unmemoized
    # build would read once too and this count would still be one. What it does pin is the cost of
    # the ask itself — naming an area buys exactly this grain's single query and nothing more.
    it "reads spec_observations exactly once for its own grain when an area is named" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      expect(directory_file_growth_grain_reads do
        get_repository(key: api_key, query: { spec_directory: "spec/models" })
      end.length).to eq(1)
      # One more query in total than the unasked request — and exactly one, so the ask did not also
      # re-issue something the endpoint had already paid for.
      expect(count_queries { get_repository(key: api_key, query: { spec_directory: "spec/models" }) })
        .to eq(baseline + 2)
    end

    # The same bound CLASSIFIED rather than counted, so "one more query" cannot be satisfied by a
    # different grain reading twice while this one reads none. The two `+1`s under one ask are this
    # block's and the durations drill-in's, which is why the total above is `+2`.
    it "reads once for its own grain and leaves every other grain alone" do
      adjacent_runs
      query = { spec_directory: "spec/models" }
      get_repository(key: api_key, query: query)

      area, file, example, description, flakiness, growth, directory_files, file_examples,
        repeated, directory_file_growth =
        observation_reads_by_grain { get_repository(key: api_key, query: query) }

      expect([area.length, file.length, example.length, description.length, flakiness.length,
              growth.length, directory_files.length, file_examples.length, repeated.length,
              directory_file_growth.length]).to eq([1, 1, 2, 2, 0, 1, 1, 0, 0, 1])
      # ⭐ THE PARTITION ITSELF, which is what a per-grain count cannot check: this read carries BOTH
      # the growth ordering and the area predicate, so it would land in two grains at once without
      # the exclusions `observation_reads_by_grain` carries. A double-classified read makes the
      # parts sum to MORE than the total; an unclassified one makes them sum to less.
      expect(observation_reads { get_repository(key: api_key, query: query) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key, query: query) })
      # And the two neighbouring growth grains are not this one: each is a different statement.
      expect(growth.first).not_to eq(directory_file_growth.first)
      expect(directory_files.first).not_to eq(directory_file_growth.first)
    end

    # ⭐ CRITERION 3's COST HALF, and the sharpest form of "the gate reads memory": a repository
    # whose parent comparison refuses asks `spec_observations` NOTHING for this grain EVEN WITH THE
    # PARAMETER SET. `SpecDirectoryFileGrowth.for` refuses on its first line, before any query.
    it "reads nothing for this grain where the parent comparison refuses, even under the ask" do
      solo = create_repository(user: @user, github_full_name: "acme/solo")
      solo_key = solo.api_keys.create!
      ingest_files({ "spec/models/user_spec.rb" => 2 }, commit_sha: "onlyrun00001",
                   at: 10.days.ago, repo: solo)
      query = { spec_directory: "spec/models" }
      get_repository(repo: solo, key: solo_key, query: query)

      expect(directory_file_growth_grain_reads do
        get_repository(repo: solo, key: solo_key, query: query)
      end).to be_empty
      # The zero is this grain declining rather than the table having gone quiet — the SAME ask's
      # durations drill-in read in the very same request.
      expect(directory_files_grain_reads do
        get_repository(repo: solo, key: solo_key, query: query)
      end.length).to eq(1)
      expect(get_repository(repo: solo, key: solo_key, query: query)["directory_run_file_growth"])
        .to be_nil
    end

    # A repository CI has never reported on does not raise under the ask, and asks nothing — the
    # nil-growth path again, measured rather than asserted.
    it "asks nothing at all of a repository with no runs" do
      empty = create_repository(user: @user, github_full_name: "acme/empty")
      empty_key = empty.api_keys.create!
      query = { spec_directory: "spec/models" }
      get_repository(repo: empty, key: empty_key, query: query)

      expect(response).to have_http_status(:ok)
      expect(directory_file_growth_grain_reads do
        get_repository(repo: empty, key: empty_key, query: query)
      end).to be_empty
      expect(get_repository(repo: empty, key: empty_key, query: query)["directory_run_file_growth"])
        .to be_nil
    end

    # The cost follows the size of the AREA rather than of the suite, and the cap bounds what comes
    # back — a relative pin rather than a number that would need rebaselining.
    it "costs the same one read as the suite and the area grow" do
      adjacent_runs
      query = { spec_directory: "spec/models" }
      get_repository(key: api_key, query: query)
      baseline = count_queries { get_repository(key: api_key, query: query) }

      ingest_files({ "spec/models/user_spec.rb" => 40, "spec/models/wide_spec.rb" => 30,
                     "spec/services/payment_spec.rb" => 30 },
                   commit_sha: "biggerrun001", at: 1.day.ago)
      get_repository(key: api_key, query: query)

      expect(directory_file_growth_grain_reads { get_repository(key: api_key, query: query) }.length)
        .to eq(1)
      expect(count_queries { get_repository(key: api_key, query: query) }).to eq(baseline)
      # And the area really did grow, so the equality above is not two identical small ones.
      expect(get_repository(key: api_key, query: query)
               .dig("directory_run_file_growth", "anchor_recorded_count")).to eq(70)
    end
  end
end
