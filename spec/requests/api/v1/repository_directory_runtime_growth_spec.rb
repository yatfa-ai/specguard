# frozen_string_literal: true

require "rails_helper"

# The `directory_runtime_growth` pair on `GET /api/v1/repository` — the agent-readable half of the
# "Areas that got slower or faster" panel `repositories#show` renders with NO PARAMETER AT ALL, and
# the one question about the suite's TIME this endpoint could not be asked at any grain finer than
# the whole run: *which areas got slower in the push I just made*.
#
# ITS OWN FILE, BESIDE `repository_directory_run_growth_spec.rb` RATHER THAN INSIDE IT, and the two
# are not near-copies. That file covers the COUNT grain — `SpecDirectoryGrowth`, which areas changed
# SIZE. This one covers the RUNTIME grain — `SpecDirectoryRuntimeGrowth`, which areas changed TIME.
# They share two runs, a gate and a SQL shape and nothing else: the states differ (ten against
# seven, because this grain has a second kind of absence), the row Struct differs, the row serializer
# is a different method, and the fixture that makes one falsifiable says nothing about the other.
# ⭐ THAT LAST CLAIM IS ITSELF AN EXAMPLE HERE — see "the falsifying case" below, which is the whole
# reason this pair exists rather than a column on that one.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never inserted
# by hand — the rule the sibling files state, and for the same reason: every state this pair turns on
# is a state the recorder produces from what a real client sends. A run whose examples carry no
# `duration` is a client reporting outcomes and no timings, which is the state this grain has and the
# count grain cannot see.
RSpec.describe "GET /api/v1/repository — directory_runtime_growth", type: :request do
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
    [body["directory_runtime_growth_window"], body["directory_runtime_growth"]]
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

  # `{"spec/models" => [1.0, 1.0]}` — one run's payload holding two examples in `spec/models`, taking
  # a second each, EACH IN ITS OWN FILE so no two rows collide on the recorder's key.
  #
  # ⭐ THE VALUES ARE DURATIONS AND NOT A COUNT, which is the whole difference from the count file's
  # `examples_in`. An area's figure here is `SUM(duration_seconds)` over its rows, so the fixture has
  # to control the seconds and not merely how many rows there are — and a `nil` in the list is an
  # example the client reported WITHOUT a timing, the state that produces this grain's three extra
  # absences and that no count fixture can express.
  #
  # Every duration used in this file is exactly representable in binary (halves and quarters), so the
  # sums and differences asserted below are exact and no example rests on float tolerance.
  def examples_in(areas)
    areas.flat_map do |directory, durations|
      durations.each_with_index.map do |duration, index|
        unannotated_spec(file_path: "#{directory}/thing_#{index}_spec.rb", line_number: index + 1,
                         name: "#{directory} example #{index}", duration: duration)
      end
    end
  end

  def ingest_areas(areas, commit_sha:, at:, repo: repository, branch: "main", **)
    ingest(repo, examples_in(areas), commit_sha: commit_sha, branch: branch, at: at, **)
  end

  # THE TWO-RUN FIXTURE THIS FILE TURNS ON, oldest first, and every property of it is load bearing:
  #
  # * `spec/models` got SLOWER by 5s and `spec/services` got FASTER by 5s, so the SIGN of every
  #   `change` is a fact the fixture can be wrong about — a symmetric pair would serialize identically
  #   under a comparison taken backwards and would pin nothing at all.
  # * The two movements are EQUAL IN MAGNITUDE, so the `ABS(...) DESC` ranking is decided by the
  #   `path ASC` tie-break, which is the half of the order a client is told it can reproduce.
  # * `spec/jobs` takes the same time in both runs, so the list carries an area that did not move —
  #   `change: 0`, where the panel prints `±0`.
  # * ⭐ EVERY AREA HOLDS TWO EXAMPLES IN BOTH RUNS. So the COUNT grain's `change` is `0` on all three
  #   rows and the count pair beside this one reports that nothing moved anywhere, while two areas
  #   moved five seconds each. That is this pair's whole reason to exist, stated as a fixture rather
  #   than as a claim in a comment.
  def adjacent_runs(repo: repository, branch: "main")
    ingest_areas({ "spec/models" => [1.0, 1.0], "spec/services" => [3.0, 3.0],
                   "spec/jobs" => [0.5, 0.5] },
                 commit_sha: "previous0001", branch: branch, at: 20.days.ago, repo: repo)
    ingest_areas({ "spec/models" => [3.5, 3.5], "spec/services" => [0.5, 0.5],
                   "spec/jobs" => [0.5, 0.5] },
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

  # ⭐ CRITERION 1 — A PLAIN `GET` WITH NO PARAMETERS CARRIES THE BLOCK.
  describe "a plain unparameterised request" do
    before { adjacent_runs }

    # No `?branch=`, no `?spec_directory=`, nothing. The dashboard answers this question with no
    # parameter and this endpoint had no key for it at all.
    it "carries runtime growth on a request that names no branch at all" do
      window, block = blocks

      expect(window).to include("state" => "comparable", "comparable" => true)
      # Largest absolute movement first; the two 5s movements tie and are broken by `path ASC`.
      expect(block["rows"].map { |row| row["path"] })
        .to eq(%w[spec/models spec/services spec/jobs])
    end

    # The operands the panel's labels are built from, and nothing that has been worded. BOTH
    # operands and not only the change: a signed duration alone cannot say whether an area of four
    # seconds gained twelve or an area of four hundred did.
    it "serves each area's two summed operands, their difference and the four states of it" do
      _window, block = blocks

      expect(row_at(block, "spec/models")).to eq(
        "path" => "spec/models", "baseline_seconds" => 2.0, "anchor_seconds" => 7.0,
        "change" => 5.0, "comparable" => true, "moved" => true,
        "new_area" => false, "removed_area" => false, "timing_gap" => false
      )
      expect(row_at(block, "spec/services")).to eq(
        "path" => "spec/services", "baseline_seconds" => 6.0, "anchor_seconds" => 1.0,
        "change" => -5.0, "comparable" => true, "moved" => true,
        "new_area" => false, "removed_area" => false, "timing_gap" => false
      )
      expect(row_at(block, "spec/jobs")).to eq(
        "path" => "spec/jobs", "baseline_seconds" => 1.0, "anchor_seconds" => 1.0,
        "change" => 0.0, "comparable" => true, "moved" => false,
        "new_area" => false, "removed_area" => false, "timing_gap" => false
      )
    end

    # ANCHOR IS THE LATEST RUN AND BASELINE IS THE PREVIOUS ONE, which is the direction every
    # `change` above is signed in. Both halves flip together if the two runs are handed to
    # `SpecDirectoryRuntimeGrowth.for` in the wrong order, so both are stated: swapping the arguments
    # turns `spec/models` from `+5` into `-5` AND swaps these two shas.
    it "anchors on the latest run and baselines on the previous one, so every change carries its true sign" do
      window, block = blocks

      expect(row_at(block, "spec/models")["change"]).to eq(5.0)
      expect(row_at(block, "spec/services")["change"]).to eq(-5.0)
      expect(window).to include("anchor_commit_sha" => "latest000001",
                                "baseline_commit_sha" => "previous0001")
      # And the anchor is the run `latest_run` names, in the same body — the two blocks cannot be
      # describing two different runs of the same repository.
      expect(get_repository["latest_run"]["commit_sha"]).to eq(window["anchor_commit_sha"])
    end

    # ⭐ THE FIGURES ARE NOT DERIVABLE FROM WHAT THE ENDPOINT ALREADY SERVED, stated as assertions
    # rather than as a claim in a comment. The subtraction needs the PREVIOUS run's per-area seconds,
    # and this body has no such figure anywhere: `latest_run.spec_directories` is the LATEST run
    # only, and the only cross-run duration served is one number for the whole run.
    it "reaches figures no arrangement of the keys beside it can produce" do
      body = get_repository

      # The single-run area grain answers for the anchor and says nothing about the baseline.
      anchor_areas = body["latest_run"]["spec_directories"]["rows"]
                     .to_h { |area| [area["path"], area["total_seconds"]] }
      expect(anchor_areas).to eq("spec/models" => 7.0, "spec/services" => 1.0, "spec/jobs" => 1.0)
      # And the whole-run delta the history serves has no area grain in it at all: both runs report
      # the same wall clock, while two areas moved five seconds each.
      expect(body["history"].map { |row| row["duration_seconds"] }.uniq).to eq([60.0])
      expect(body["directory_runtime_growth"]["rows"].map { |row| row["change"] })
        .to eq([5.0, -5.0, 0.0])
    end

    # OPERANDS, NEVER THE PANEL'S SPELLINGS. `SpecDirectoryRuntimeGrowth::Row` carries
    # `previous_label`, `latest_label`, `coverage_label`, `change_label` and `change_reading` —
    # typographic and screen-reader spellings of these same numbers. A client served those would be
    # splitting strings and stripping glyphs to compare two rows.
    it "serves no value the panel has worded, and no glyph it has typeset" do
      window, block = blocks

      # The only strings in the rows block are area paths; the contract block's are its own tokens.
      expect(strings_in(block)).to all(start_with("spec/"))
      expect(strings_in(window))
        .to contain_exactly("abs_change_desc_nulls_last,path_asc", "previous_run_on_branch",
                            "single_branch", "main", "comparable", "latest000001", "previous0001")
      # And the vocabulary being refused is real — this data makes the panel print all of it.
      expect(strings_in(block) + strings_in(window))
        .not_to include("±0", "−5.00s", "+5.00s", "New area", "not reported", "2 of 2 → 2 of 2")
    end

    # ⭐ CRITERION 6 — the cap's operands, so "am I seeing all of them" is answerable.
    # `directory_count` is counted BEFORE the `LIMIT` applies (a window function runs first), and
    # `limit` is read off the constant rather than restated.
    it "discloses the areas it covered, whether the list was cut, and the bound that cut it" do
      _window, block = blocks

      expect(block).to include("directory_count" => 3, "truncated" => false,
                               "limit" => SpecObservation::RETIMED_DIRECTORIES_LIMIT)
    end

    # ⭐ ALL FOUR DENOMINATORS, WHICH IS TWO MORE THAN THE COUNT SIBLING SERVES. This grain has two
    # kinds of absence and therefore two kinds of denominator: how many rows each run RECORDED, and
    # how many of those carried a TIMING. "1,204 examples reported a timing" is 1,204 of something
    # unstated, and the whole reading this block turns on is whether an area got faster or merely
    # went quiet.
    it "serves both count grains on both sides, and not only the recorded pair" do
      _window, block = blocks

      expect(block).to include("baseline_recorded_count" => 6, "anchor_recorded_count" => 6,
                               "baseline_timed_count" => 6, "anchor_timed_count" => 6)
      # The count sibling, over the same two runs, has only the recorded pair — it has no timing
      # grain to report. So this is a difference in the CONTRACT and not a difference in the data.
      expect(get_repository["directory_run_growth"].keys)
        .not_to include("baseline_timed_count", "anchor_timed_count")
    end

    # `RETIMED_DIRECTORIES_LIMIT` is a DIFFERENT constant from the count sibling's
    # `MOVED_DIRECTORIES_LIMIT`, and they hold the same number today. Asserted by NAME on both sides
    # so a later change to one does not silently rebaseline the other's block through this file.
    it "reads its bound off its own constant and not off the count block's" do
      _window, block = blocks

      expect(block["limit"]).to eq(SpecObservation::RETIMED_DIRECTORIES_LIMIT)
      expect(get_repository["directory_run_growth"]["limit"])
        .to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
    end
  end

  # ⭐⭐ CRITERION 2 — THE FALSIFYING CASE, AND THE REASON THIS PAIR IS NOT A COLUMN ON THE ONE BESIDE
  # IT.
  #
  # `SpecDirectoryRuntimeGrowth`'s class comment states the defect directly: an area where somebody
  # made an EXISTING spec slow adds ZERO examples, so its `ABS(latest_count - previous_count)` is
  # `0`, it sorts LAST on the count block and falls off the cap. It is not a row there missing a
  # column — it is not on that list at all.
  #
  # The fixture makes that literal. Ten decoy areas each gain one example (so each has a count
  # movement and outranks the target on the count block, filling its cap exactly), and `spec/slow`
  # holds ONE example in both runs whose duration goes 0.25s → 8.25s. Nothing was added anywhere in
  # it; something in it got eight seconds slower.
  describe "an area where an existing spec got slower and nothing was added" do
    before do
      decoys = (0...SpecObservation::MOVED_DIRECTORIES_LIMIT)
               .to_h { |index| ["spec/decoy#{format("%02d", index)}", [0.25]] }

      ingest_areas(decoys.merge("spec/slow" => [0.25]),
                   commit_sha: "previous0001", at: 20.days.ago)
      ingest_areas(decoys.transform_values { [0.25, 0.25] }.merge("spec/slow" => [8.25]),
                   commit_sha: "latest000001", at: 10.days.ago)
    end

    it "appears in directory_runtime_growth and is absent from directory_run_growth" do
      body = get_repository

      runtime_paths = body["directory_runtime_growth"]["rows"].map { |row| row["path"] }
      count_paths = body["directory_run_growth"]["rows"].map { |row| row["path"] }

      # THE WHOLE TICKET, IN TWO LINES. It is on the runtime list, at the top of it.
      expect(runtime_paths.first).to eq("spec/slow")
      # And it is on the count list NOWHERE — the regression is invisible to that block entirely.
      expect(count_paths).not_to include("spec/slow")
    end

    # The absence above is a REAL absence and not an empty sibling: the count block did answer, over
    # the same two runs, and filled its cap with areas that moved by one example each while the area
    # that lost eight seconds fell off it.
    it "is absent because the count grain ranks it last, not because the count block is empty" do
      body = get_repository
      count_block = body["directory_run_growth"]

      expect(count_block["rows"].length).to eq(SpecObservation::MOVED_DIRECTORIES_LIMIT)
      expect(count_block["rows"].map { |row| row["change"] }.uniq).to eq([1])
      # The count block SAW the area — it is inside the total it covered — and had no room to
      # list it, which is exactly the disclosure that cannot be acted on without this pair.
      expect(count_block).to include("truncated" => true,
                                     "directory_count" => SpecObservation::MOVED_DIRECTORIES_LIMIT + 1)
    end

    # And the row the runtime block serves for it says the movement was TIME and not SIZE: the two
    # operands are one example's duration on each side, and the area is neither new nor removed.
    it "serves the movement with both operands, and no example was added on either side" do
      _window, block = blocks

      expect(row_at(block, "spec/slow")).to eq(
        "path" => "spec/slow", "baseline_seconds" => 0.25, "anchor_seconds" => 8.25,
        "change" => 8.0, "comparable" => true, "moved" => true,
        "new_area" => false, "removed_area" => false, "timing_gap" => false
      )
    end
  end

  describe "a comparison covering more areas than the block lists" do
    it "discloses the cap, the total it was applied to, and the bound that produced it" do
      areas = Array.new(SpecObservation::RETIMED_DIRECTORIES_LIMIT + 2) { |index| "spec/area#{index}" }
      ingest_areas(areas.index_with { [0.25] }, commit_sha: "previous0001", at: 20.days.ago)
      ingest_areas(areas.each_with_index.to_h { |area, index| [area, [0.25 + index]] },
                   commit_sha: "latest000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["rows"].length).to eq(SpecObservation::RETIMED_DIRECTORIES_LIMIT)
      expect(block).to include("truncated" => true,
                               "directory_count" => SpecObservation::RETIMED_DIRECTORIES_LIMIT + 2,
                               "limit" => SpecObservation::RETIMED_DIRECTORIES_LIMIT)
    end
  end

  # ⭐ CRITERION 5 — THE THREE ABSENCES THE MODEL KEEPS APART, AND THE `0` THAT MUST NEVER APPEAR.
  #
  # `SUM` skips NULLs silently and `duration_seconds` is nullable by design, so an area can have a
  # nil `change` for three completely different reasons. Collapsing them re-creates exactly the
  # confusion `SpecDirectoryRuntimeGrowth::Row` spends paragraphs refusing — and coercing any of them
  # to `0` would make "this side was never timed" byte-identical to "this area took no time".
  describe "the three different reasons a change can be null" do
    before do
      ingest_areas({ "spec/models" => [1.0], "spec/gap" => [nil], "spec/gone" => [2.0] },
                   commit_sha: "previous0001", at: 20.days.ago)
      ingest_areas({ "spec/models" => [4.0], "spec/gap" => [3.0], "spec/fresh" => [1.0] },
                   commit_sha: "latest000001", at: 10.days.ago)
    end

    # BOTH RUNS RAN IT AND ONE DID NOT TIME IT — the absence about the REPORTING rather than about
    # the area existing. This is the row the panel prints as "Not timed".
    it "serves a timing gap as change: null, comparable: false, timing_gap: true — never change: 0" do
      _window, block = blocks

      expect(row_at(block, "spec/gap")).to eq(
        "path" => "spec/gap", "baseline_seconds" => nil, "anchor_seconds" => 3.0,
        "change" => nil, "comparable" => false, "moved" => false,
        "new_area" => false, "removed_area" => false, "timing_gap" => true
      )
      # ⭐ The nil is SERVED and not fabricated into a zero, which is the one reading this refuses.
      expect(row_at(block, "spec/gap")["change"]).not_to eq(0)
      expect(row_at(block, "spec/gap")["baseline_seconds"]).not_to eq(0)
    end

    # AN AREA ONLY ONE RUN HAS is a different fact from a timing gap, and it is `timing_gap: false` —
    # its cell already says "New area" / "Area removed", and a sentence about a run that "reported no
    # timing" would be describing a different row from the one the reader is looking at.
    it "tells an area that is new or removed apart from one that went untimed" do
      _window, block = blocks

      expect(row_at(block, "spec/fresh")).to include(
        "baseline_seconds" => nil, "anchor_seconds" => 1.0, "change" => nil,
        "comparable" => false, "new_area" => true, "removed_area" => false, "timing_gap" => false
      )
      expect(row_at(block, "spec/gone")).to include(
        "baseline_seconds" => 2.0, "anchor_seconds" => nil, "change" => nil,
        "comparable" => false, "new_area" => false, "removed_area" => true, "timing_gap" => false
      )
      # THREE ROWS, THREE DIFFERENT ABSENCES, and the three predicates separate them — which is the
      # assertion that would fail if any two were collapsed into one flag.
      expect(%w[spec/gap spec/fresh spec/gone].map { |path| row_at(block, path)["timing_gap"] })
        .to eq([true, false, false])
      expect(%w[spec/gap spec/fresh spec/gone].map { |path| row_at(block, path)["new_area"] })
        .to eq([false, true, false])
    end

    # The untimed rows sort LAST — the read asks `NULLS LAST` — which is what `order` says and what
    # lets an untimed row appear on a capped list at all: the movement ran out before the cap did.
    it "sorts the rows with nothing to subtract last, as its order token says" do
      window, block = blocks

      expect(window["order"]).to eq("abs_change_desc_nulls_last,path_asc")
      expect(block["rows"].map { |row| row["path"] }.first).to eq("spec/models")
      expect(block["rows"].last(3).map { |row| row["comparable"] }).to eq([false, false, false])
    end

    # The TIMED denominators are what make that row readable, and they differ from the RECORDED ones
    # here — which is the whole reason this block serves four counts and the count sibling serves two.
    it "serves timed denominators that differ from the recorded ones" do
      _window, block = blocks

      expect(block).to include("baseline_recorded_count" => 3, "baseline_timed_count" => 2,
                               "anchor_recorded_count" => 3, "anchor_timed_count" => 3)
    end
  end

  # ⭐ CRITERION 3 AND CRITERION 4 — THE TWELVE STATES, SWEPT AT ONCE.
  #
  # Swept across one table rather than as twelve examples, because the defect this guards against is
  # two states COLLAPSING INTO ONE — which no single-state example can see. `state` is the block's
  # whole answer in eleven of the twelve, and the sweep is what pins that the eleven are eleven.
  describe "the states a comparison can fail in" do
    # Each shape on its own repository, so the "latest" run of one cannot become the "previous" run
    # of another.
    def state_of(repo)
      window, block = blocks(repo: repo)
      [window["state"], window["comparable"], block]
    end

    def fresh_repository = create_repository(user: @user, github_full_name: "acme/r#{SecureRandom.hex(4)}")

    it "names which of the twelve applies, and serves no rows in any but the last" do
      # SERIALIZER-LEVEL, and NOT model states: `SpecDirectoryRuntimeGrowth.for` dereferences its
      # second argument on its second line and has no nil state of its own.
      no_latest = fresh_repository
      no_previous = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "onlyrun00001", at: 10.days.ago, repo: repo)
      end
      unbranched = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "unbranched01", at: 20.days.ago,
                     repo: repo, branch: nil)
        ingest_areas({ "spec/models" => [2.0] }, commit_sha: "unbranched02", at: 10.days.ago,
                     repo: repo, branch: nil)
      end
      # THE THREE PRE-QUERY STATES, decided from the two runs alone.
      latest_unmeasured = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "measured0001", at: 20.days.ago, repo: repo)
        ingest(repo, [], commit_sha: "nototals0001", at: 10.days.ago, total: 0)
      end
      previous_unmeasured = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "nototals0002", at: 20.days.ago, total: 0)
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "measured0002", at: 10.days.ago, repo: repo)
      end
      assembled_differently = fresh_repository.tap do |repo|
        run = ingest_areas({ "spec/models" => [1.0] }, commit_sha: "sharded00001", at: 20.days.ago,
                           repo: repo)
        2.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 1) }
        ingest_areas({ "spec/models" => [2.0] }, commit_sha: "unsharded001", at: 10.days.ago, repo: repo)
      end
      # THE THREE RECORDED STATES: a run can report a suite size and write no per-example rows,
      # which is a client that posts only totals.
      neither_recorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly01", at: 20.days.ago, total: 40)
        ingest(repo, [], commit_sha: "totalsonly02", at: 10.days.ago, total: 40)
      end
      previous_unrecorded = fresh_repository.tap do |repo|
        ingest(repo, [], commit_sha: "totalsonly03", at: 20.days.ago, total: 40)
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "recorded0001", at: 10.days.ago, repo: repo)
      end
      latest_unrecorded = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [1.0] }, commit_sha: "recorded0002", at: 20.days.ago, repo: repo)
        ingest(repo, [], commit_sha: "totalsonly04", at: 10.days.ago, total: 40)
      end
      # ⭐ THE THREE TIMED STATES — THE GRAIN THE COUNT SIBLING HAS NO EQUIVALENT OF. A run whose
      # client posts rows WITHOUT durations is fully recorded and has nothing to sum, which is a
      # different thing to go and fix from a run that recorded nothing.
      neither_timed = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [nil, nil] }, commit_sha: "untimed00001", at: 20.days.ago,
                     repo: repo)
        ingest_areas({ "spec/models" => [nil, nil] }, commit_sha: "untimed00002", at: 10.days.ago,
                     repo: repo)
      end
      previous_untimed = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [nil, nil] }, commit_sha: "untimed00003", at: 20.days.ago,
                     repo: repo)
        ingest_areas({ "spec/models" => [1.0, 1.0] }, commit_sha: "timed0000001", at: 10.days.ago,
                     repo: repo)
      end
      latest_untimed = fresh_repository.tap do |repo|
        ingest_areas({ "spec/models" => [1.0, 1.0] }, commit_sha: "timed0000002", at: 20.days.ago,
                     repo: repo)
        ingest_areas({ "spec/models" => [nil, nil] }, commit_sha: "untimed00004", at: 10.days.ago,
                     repo: repo)
      end
      comparable = fresh_repository.tap { |repo| adjacent_runs(repo: repo) }

      states = {
        "no_latest_run" => no_latest, "no_previous_run" => no_previous,
        "unbranched" => unbranched, "latest_unmeasured" => latest_unmeasured,
        "previous_unmeasured" => previous_unmeasured,
        "assembled_differently" => assembled_differently, "neither_recorded" => neither_recorded,
        "previous_unrecorded" => previous_unrecorded, "latest_unrecorded" => latest_unrecorded,
        "neither_timed" => neither_timed, "previous_untimed" => previous_untimed,
        "latest_untimed" => latest_untimed, "comparable" => comparable
      }.transform_values { |repo| state_of(repo) }

      expect(states).to eq(
        "no_latest_run" => ["no_latest_run", false, nil],
        # ⭐ CRITERION 4 — a repository whose latest run has no earlier run on its branch returns 200
        # with this token and does NOT raise. `SpecDirectoryRuntimeGrowth.for` dereferences
        # `previous_test_run.suite_size_measured?` on its second line, so an unguarded call site is a
        # `NoMethodError` on a plain unparameterised `GET` for exactly this shape.
        "no_previous_run" => ["no_previous_run", false, nil],
        # A latest run whose client sent no branch is `no_previous_run` too — there is no branch to
        # compare on, and `Repository#previous_test_run_on_branch` refuses to pool anonymous runs
        # into a fictional history. The two shapes are told apart by `branch`, asserted below.
        "unbranched" => ["no_previous_run", false, nil],
        "latest_unmeasured" => ["latest_unmeasured", false, nil],
        "previous_unmeasured" => ["previous_unmeasured", false, nil],
        "assembled_differently" => ["assembled_differently", false, nil],
        "neither_recorded" => ["neither_recorded", false, nil],
        "previous_unrecorded" => ["previous_unrecorded", false, nil],
        "latest_unrecorded" => ["latest_unrecorded", false, nil],
        "neither_timed" => ["neither_timed", false, nil],
        "previous_untimed" => ["previous_untimed", false, nil],
        "latest_untimed" => ["latest_untimed", false, nil],
        "comparable" => ["comparable", true, states["comparable"].last]
      )
      # ⭐ CRITERION 3, THE HALF THE TABLE ABOVE CANNOT STATE — the RECORDED and TIMED grains are
      # distinct tokens on each side, and they are different repairs: "the earlier run recorded no
      # per-example rows" against "the earlier run recorded rows and reported no timings". This pair
      # is the reason this block has ten model states where the count sibling has seven.
      expect(states["previous_unrecorded"].first).not_to eq(states["previous_untimed"].first)
      expect(states["latest_unrecorded"].first).not_to eq(states["latest_untimed"].first)
      expect(states["neither_recorded"].first).not_to eq(states["neither_timed"].first)
      # And `no_previous_run` is distinct from `previous_unmeasured` — "there is nothing to compare
      # against" against "the run we compared against reported no tests".
      expect(states["no_previous_run"].first).not_to eq(states["previous_unmeasured"].first)
      # The two shapes of `no_previous_run` are separable by the block itself.
      expect(blocks(repo: no_previous).first["branch"]).to eq("main")
      expect(blocks(repo: unbranched).first["branch"]).to be_nil
      expect(blocks(repo: no_latest).first["branch"]).to be_nil
      # The comparable one really did compare, so "no rows in any but the last" is a refusal of
      # something real rather than twelve nulls and a thirteenth.
      expect(states["comparable"].last["rows"].length).to eq(3)
    end

    # ⭐ CRITERION 4, ON ITS OWN, BECAUSE IT IS THE ONE THAT RAISES. Stated as a status assertion
    # rather than only as a token in the table above: an unguarded accessor makes this a 500.
    it "returns 200 on a repository whose latest run has no previous run on its branch" do
      solo = fresh_repository
      ingest_areas({ "spec/models" => [1.0] }, commit_sha: "onlyrun00001", at: 10.days.ago, repo: solo)

      window, block = blocks(repo: solo)

      expect(response).to have_http_status(:ok)
      expect(window).to include("state" => "no_previous_run", "comparable" => false,
                                "baseline_commit_sha" => nil,
                                "anchor_commit_sha" => "onlyrun00001")
      expect(block).to be_nil
    end

    # THE KEY-ALWAYS-PRESENT RULE, asserted where nulling the rows block could quietly break it: the
    # contract block goes to the SAME KEY SET in an absence state as in a comparison, rather than
    # going absent or going short. A block that explains a `null` is worthless if it is itself
    # absent whenever the `null` happens.
    it "serves the same contract keys with no comparison as with one" do
      absent = fresh_repository
      compared = fresh_repository.tap { |repo| adjacent_runs(repo: repo) }

      absent_window, absent_block = blocks(repo: absent)
      compared_window, compared_block = blocks(repo: compared)

      expect(absent_window.keys).to match_array(compared_window.keys)
      expect(absent_window).to include("state" => "no_latest_run", "comparable" => false,
                                       "branch" => nil, "anchor_commit_sha" => nil,
                                       "baseline_commit_sha" => nil,
                                       "order" => "abs_change_desc_nulls_last,path_asc",
                                       "tie_break_served" => true,
                                       "basis" => "previous_run_on_branch",
                                       "branch_scope" => "single_branch")
      # `null` and never an empty block of zeroes: "we could not compare" must not serialize as "we
      # compared and nothing moved" — and it must not invent the denominators either.
      expect(absent_block).to be_nil
      expect(compared_block).not_to be_nil
    end

    # ⭐ THE ONE GENUINE DESIGN DECISION, ASSERTED AS THE BEHAVIOUR IT PRODUCES.
    #
    # `SpecDirectoryRuntimeGrowth.from_tuples` passes `**totals` into EVERY state it constructs, so
    # unlike its count sibling the denominators in a row-derived absence state are REAL rather than
    # dropped. The block is `null` there anyway, so that "non-null exactly when `comparable`" is one
    # sentence a client can hold rather than a six-of-nine rule — and the actionable half, the state
    # token, is served unconditionally one key up.
    it "withholds the whole block in an absence state whose object DID keep its totals" do
      ingest_areas({ "spec/models" => [nil, nil] }, commit_sha: "untimed00001", at: 20.days.ago)
      ingest_areas({ "spec/models" => [1.0, 1.0] }, commit_sha: "timed0000001", at: 10.days.ago)

      window, block = blocks

      expect(window["state"]).to eq("previous_untimed")
      expect(block).to be_nil
      # The object really did hold honest totals in that state — the figures exist and are simply not
      # served here, which is what makes this a decision rather than an absence of data.
      growth = SpecDirectoryRuntimeGrowth.for(repository.test_runs.order(created_at: :desc).first,
                                              repository.test_runs.order(created_at: :desc).second)
      expect(growth.state).to eq(:previous_untimed)
      expect([growth.previous_recorded_count, growth.previous_timed_count]).to eq([2, 0])
    end
  end

  # ⭐ CRITERION 6 (BRANCH CORRECTNESS) — no `?branch=` gate, because the comparison is branch-correct
  # BY CONSTRUCTION. `Repository#previous_test_run_on_branch` scopes to the LATEST RUN'S OWN branch,
  # so the row immediately before the newest one in the interleaved all-branch history can be a
  # different branch and comparing against it would report a movement no commit made.
  describe "a newest run whose immediate predecessor is on another branch" do
    before do
      ingest_areas({ "spec/models" => [1.0] }, commit_sha: "feature00001", branch: "feature/x",
                   at: 30.days.ago)
      ingest_areas({ "spec/models" => [99.0] }, commit_sha: "maininterlv1", branch: "main",
                   at: 20.days.ago)
      ingest_areas({ "spec/models" => [4.0] }, commit_sha: "feature00002", branch: "feature/x",
                   at: 10.days.ago)
    end

    it "compares the two newest runs on the latest run's own branch, not the interleaved row" do
      window, block = blocks

      expect(window).to include("branch" => "feature/x", "branch_scope" => "single_branch",
                                "anchor_commit_sha" => "feature00002",
                                "baseline_commit_sha" => "feature00001")
      # +3s across the branch, and NOT the −95s the interleaved `main` row would have produced.
      expect(row_at(block, "spec/models")).to include("baseline_seconds" => 1.0,
                                                      "anchor_seconds" => 4.0, "change" => 3.0)
    end

    # NOT RE-ANCHORED BY `?branch=`, exactly like `latest_run` and unlike `history`. A client
    # narrowing the history has asked a question about a series, not for a different comparison —
    # and `branch` says which branch this one was actually taken on.
    it "keeps naming the latest run's branch under a ?branch= that names another" do
      window, block = blocks(query: { branch: "main" })

      expect(window).to include("branch" => "feature/x", "anchor_commit_sha" => "feature00002",
                                "baseline_commit_sha" => "feature00001")
      expect(row_at(block, "spec/models")["change"]).to eq(3.0)
      # While `history` DID narrow in the same body, so the request really did carry the parameter.
      expect(get_repository(query: { branch: "main" })["history"].map { |row| row["commit_sha"] })
        .to eq(%w[maininterlv1])
    end
  end

  # ADDED BESIDE, NEVER IN PLACE OF — the two growth pairs already on the wire are untouched.
  describe "against the blocks it sits beside" do
    before { adjacent_runs }

    it "leaves the count pair's answer exactly as it was" do
      body = get_repository

      # Every area holds two examples in both runs, so the count pair correctly reports that nothing
      # moved — while this pair reports two areas moving five seconds each. Stated in full rather
      # than by `include`, so a change to either count key is a red example here.
      expect(body["directory_run_growth"]["rows"]).to eq(
        [{ "path" => "spec/jobs", "baseline_count" => 2, "anchor_count" => 2, "change" => 0,
           "moved" => false, "new_area" => false, "removed_area" => false },
         { "path" => "spec/models", "baseline_count" => 2, "anchor_count" => 2, "change" => 0,
           "moved" => false, "new_area" => false, "removed_area" => false },
         { "path" => "spec/services", "baseline_count" => 2, "anchor_count" => 2, "change" => 0,
           "moved" => false, "new_area" => false, "removed_area" => false }]
      )
      expect(body["directory_run_growth_window"]).to include("order" => "abs_change_desc,path_asc",
                                                             "state" => "comparable")
      # And the window pair, which is gated on `?branch=`, still declines an unfiltered request.
      expect(body["directory_growth"]).to be_nil
    end

    # THE TWO PAIRS ANSWER DIFFERENT QUESTIONS OVER THE SAME TWO RUNS, and their contract blocks say
    # so: same basis, same branch, same two shas — different ORDER, because they rank by different
    # quantities and one of them can rank on a NULL.
    it "shares the two runs with the count pair and states a different ordering" do
      body = get_repository
      runtime = body["directory_runtime_growth_window"]
      counts = body["directory_run_growth_window"]

      expect(runtime.slice("basis", "branch", "branch_scope", "anchor_commit_sha",
                           "baseline_commit_sha", "state"))
        .to eq(counts.slice("basis", "branch", "branch_scope", "anchor_commit_sha",
                            "baseline_commit_sha", "state"))
      expect(runtime["order"]).not_to eq(counts["order"])
      expect(runtime["order"]).to eq("abs_change_desc_nulls_last,path_asc")
    end
  end

  # ⭐ CRITERION 8 — THE API'S FIGURES EQUAL THE PANEL'S FOR THE SAME REPOSITORY. Read off the
  # RENDERED PAGE rather than off a second call to `SpecDirectoryRuntimeGrowth`, which would only
  # compare the endpoint against itself.
  describe "against what repositories#show prints" do
    def panel_rows
      panel = Capybara.string(response.body).find("#spec-directory-runtime-growth")
      panel.all("tbody tr").map do |row|
        path, baseline, anchor, change, = row.all("td").map { |cell| cell.text.strip }
        { "path" => path, "baseline" => baseline, "anchor" => anchor, "change" => change }
      end
    end

    # The page prints the labels; the block serves the operands. The spelling is restated HERE, by
    # hand, rather than taken from `SpecObservation.humanized_duration` — an expectation built from
    # the same method the view calls would agree with the page no matter what either did.
    def seconds_label(seconds) = seconds.nil? ? "not reported" : format("%.2fs", seconds)

    it "names the same areas, with the same operands and the same movements" do
      adjacent_runs

      _window, block = blocks
      get repository_path(repository)

      served = block["rows"].map do |row|
        { "path" => row["path"],
          "baseline" => seconds_label(row["baseline_seconds"]),
          "anchor" => seconds_label(row["anchor_seconds"]),
          "change" => case row["change"]
                      when nil then "Not timed"
                      when 0 then "±0"
                      when ..-1 then "−#{seconds_label(row["change"].abs)}"
                      else "+#{seconds_label(row["change"])}"
                      end }
      end

      expect(panel_rows).to eq(served)
      # The comparison is over a NON-EMPTY list rendered by both surfaces — two empty arrays are
      # equal, and an endpoint that served nothing at all would satisfy the line above.
      expect(served.length).to eq(3)
      # The panel is the one the dashboard renders with NO PARAMETER, which is the request the API
      # block was just read off too.
      expect(panel_rows.map { |row| row["change"] }).to eq(["+5.00s", "−5.00s", "±0"])
    end

    # The panel prints the previous run's sha in its caption; the block serves it as a key. Same
    # run, so an agent reading the API and a human reading the page are looking at one comparison.
    it "names the same previous run the panel's caption does" do
      adjacent_runs

      window, = blocks
      get repository_path(repository)
      caption = Capybara.string(response.body).find("#spec-directory-runtime-growth-basis").text.squish

      expect(window["baseline_commit_sha"]).to eq("previous0001")
      expect(caption).to include(window["baseline_commit_sha"].first(7))
    end

    # And the four denominators the block serves are the four the caption states, so an agent sizing
    # "recorded six, timed five" and a human reading the page cannot be given different figures.
    it "states the same four denominators the panel's caption does" do
      ingest_areas({ "spec/models" => [1.0], "spec/gap" => [nil] },
                   commit_sha: "previous0001", at: 20.days.ago)
      ingest_areas({ "spec/models" => [4.0], "spec/gap" => [3.0] },
                   commit_sha: "latest000001", at: 10.days.ago)

      _window, block = blocks
      get repository_path(repository)
      caption = Capybara.string(response.body).find("#spec-directory-runtime-growth-basis").text.squish

      expect(block).to include("baseline_recorded_count" => 2, "baseline_timed_count" => 1,
                               "anchor_recorded_count" => 2, "anchor_timed_count" => 2)
      expect(caption).to include("1 of 2 and 2 of 2")
    end
  end

  # CRITERION: no `specguard-mcp` release is required, asserted as the property that makes it true
  # rather than as a claim about another repository. `src/tools/repository-overview.ts` renders
  # `JSON.stringify(overview, null, 2)` and returns the object verbatim, so a key reaches
  # `get_repository_overview` if and only if it is a TOP-LEVEL key of this body.
  describe "what a passthrough client sees" do
    it "adds the pair at the top level, and nowhere else" do
      adjacent_runs

      body = get_repository

      expect(body.keys).to include("directory_runtime_growth_window", "directory_runtime_growth")
      # NEVER INSIDE `latest_run`, which is single-run facts by construction — the rule that block
      # states for itself, and the reason every growth pair sits out here beside `history`.
      expect(body["latest_run"].keys)
        .not_to include("directory_runtime_growth", "directory_runtime_growth_window")
    end
  end

  describe "what the runtime block costs the endpoint" do
    # ONE READ, and it is also the MEMOIZATION GUARD — the only form of one this endpoint can have.
    # `show` reads the presenter twice, once for the contract block's `state` and once for the rows,
    # so an unmemoized accessor builds it twice and this count is two.
    #
    # ⭐ THIS GRAIN IS THIS BLOCK'S ALONE, unlike `growth_grain_reads`, which has two readers that no
    # pattern can separate. `SpecObservation.directory_runtime_growth_between` is issued by this
    # block and by nothing else on this endpoint, so the count attributes directly.
    it "reads spec_observations exactly once on an unparameterised request" do
      adjacent_runs
      get_repository(key: api_key)

      expect(runtime_growth_grain_reads { get_repository(key: api_key) }.length).to eq(1)
    end

    # And that one read is ALL it adds — the assertion a per-grain count cannot make, because a read
    # matching no grain's pattern is invisible to every one of them. The total is asserted as the SUM
    # OF THE PARTS, so a read that stopped being issued and a different one that started cannot
    # cancel out into a passing number, and a read double-classified into two grains shows up as
    # parts summing to more than the total.
    it "adds exactly that one to the table's total, and is classified into no other grain" do
      adjacent_runs
      get_repository(key: api_key)

      grains = observation_reads_by_grain { get_repository(key: api_key) }

      # `growth` (5) is UNCHANGED at one — the count block's read — so the runtime read was not
      # adopted into it, which is the misclassification the two share a grouping expression for.
      expect(grains[5].length).to eq(1)
      expect(grains[10].length).to eq(1)
      expect(observation_reads { get_repository(key: api_key) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key) })
    end

    # ⭐ THE COST HALF OF THE STATE TABLE: a repository with nothing to compare asks
    # `spec_observations` NOTHING for this grain. The gate short-circuits before any read in five of
    # the twelve states — the two serializer states never construct the object, and three of the
    # model's own are decided from the two runs alone.
    it "reads nothing for this grain where there is nothing to compare" do
      solo = create_repository(user: @user, github_full_name: "acme/solo")
      solo_key = solo.api_keys.create!
      ingest_areas({ "spec/models" => [1.0] }, commit_sha: "onlyrun00001", at: 10.days.ago, repo: solo)
      get_repository(repo: solo, key: solo_key)

      expect(runtime_growth_grain_reads { get_repository(repo: solo, key: solo_key) }).to be_empty
      # The zero above is this grain declining to read rather than the table having gone quiet — the
      # endpoint's single-run grains are untouched in the same request.
      expect(observation_reads { get_repository(repo: solo, key: solo_key) }).not_to be_empty
      expect(get_repository(repo: solo, key: solo_key)["directory_runtime_growth"]).to be_nil
    end

    # A gate state costs nothing either, which is the half the example above cannot show: there ARE
    # two runs here, and the read is still never issued.
    it "reads nothing for this grain when the two runs are assembled differently" do
      run = ingest_areas({ "spec/models" => [1.0] }, commit_sha: "sharded00001", at: 20.days.ago)
      2.times { |shard| run.test_run_shards.create!(shard_id: (shard + 1).to_s, total_specs_count: 1) }
      ingest_areas({ "spec/models" => [2.0] }, commit_sha: "unsharded001", at: 10.days.ago)
      get_repository(key: api_key)

      expect(runtime_growth_grain_reads { get_repository(key: api_key) }).to be_empty
      expect(get_repository(key: api_key)["directory_runtime_growth_window"])
        .to include("state" => "assembled_differently")
    end

    # A repository CI has never reported on does not raise, and asks nothing.
    it "asks nothing at all of a repository with no runs" do
      empty = create_repository(user: @user, github_full_name: "acme/empty")
      empty_key = empty.api_keys.create!
      get_repository(repo: empty, key: empty_key)

      expect(response).to have_http_status(:ok)
      expect(runtime_growth_grain_reads { get_repository(repo: empty, key: empty_key) }).to be_empty
      expect(get_repository(repo: empty, key: empty_key)["directory_runtime_growth_window"])
        .to include("state" => "no_latest_run")
    end

    # The previous-run lookup is still ONE indexed row however many blocks read it — this pair is the
    # THIRD reader of that row, and an unmemoized accessor would make it two lookups. Matched on the
    # ROW-VALUE PREDICATE, which `Repository#previous_test_run_on_branch` issues and nothing else
    # this endpoint calls does.
    it "looks the previous run up exactly once, with a third reader of it now on the page" do
      adjacent_runs
      get_repository(key: api_key)

      statements = executed_sql { get_repository(key: api_key) }
      lookups = statements.grep(/\(test_runs\.created_at, test_runs\.id\) < /)

      expect(lookups.length).to eq(1)
      expect(get_repository(key: api_key)["directory_runtime_growth_window"]["baseline_commit_sha"])
        .to eq("previous0001")
    end

    # The cost does not follow the size of the suite: the aggregate is `GROUP BY` area over two run
    # ids in an `IN` list, and the row cap bounds what comes back. A relative pin rather than a
    # number that would need rebaselining.
    it "costs the same one read as the suite grows" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      ingest_areas({ "spec/models" => Array.new(40) { 0.25 },
                     "spec/services" => Array.new(30) { 0.25 },
                     "spec/jobs" => Array.new(30) { 0.25 } },
                   commit_sha: "biggerrun001", at: 1.day.ago)
      get_repository(key: api_key)

      expect(runtime_growth_grain_reads { get_repository(key: api_key) }.length).to eq(1)
      expect(count_queries { get_repository(key: api_key) }).to eq(baseline)
      expect(get_repository(key: api_key).dig("directory_runtime_growth", "anchor_timed_count"))
        .to eq(100)
    end
  end
end
