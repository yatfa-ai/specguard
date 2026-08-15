# frozen_string_literal: true

require "rails_helper"

# The `directory_runtime_file_growth` pair on `GET /api/v1/repository` — the FOURTH AND LAST cell of
# the {area, file} × {count, runtime} square this endpoint serves growth over, and the one that was
# empty. `directory_run_growth` is area×count, `directory_runtime_growth` is area×runtime,
# `directory_run_file_growth` is file×count, and an agent told `spec/models` got ninety seconds
# slower could not ask WHICH FILE DID IT.
#
# ITS OWN FILE, on the disposition its three siblings already take. This pair is a DRILL-IN gated on
# an ask the runtime pair takes none of, capped by its own constant, and its whole subject — a file
# that stopped reporting timings beside one that genuinely got slower — is a distinction neither
# neighbour can express: the area grain has no files, and the count grain has no durations.
#
# THE ROWS ARE WRITTEN BY `Ingest::ObservationRecorder` THROUGH `Ingest::RunRecorder`, never inserted
# by hand — the rule every sibling file states, and for the same reason: every state this pair turns
# on is a state the recorder produces from what a real client sends, including the untimed row, which
# is what a reporter that omits `run_time` writes.
RSpec.describe "GET /api/v1/repository — directory_runtime_file_growth", type: :request do
  let(:repository) { create_repository }
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
    [body["directory_runtime_file_growth_window"], body["directory_runtime_file_growth"]]
  end

  def ingest(repo, specs, commit_sha:, branch: "main", at: nil, total: nil, **attrs)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    run
  end

  # `{"spec/models/user_spec.rb" => [4, 0.5]}` — one run's payload holding four examples in that
  # FILE at half a second each. A nil second element is the UNTIMED row a reporter that sends no
  # `run_time` writes, which is the state half this pair's absences turn on.
  def examples_in(counts)
    counts.flat_map do |file_path, (count, each)|
      Array.new(count) do |index|
        unannotated_spec(file_path: file_path, line_number: index + 1,
                         name: "#{file_path} example #{index}", duration: each)
      end
    end
  end

  # ⭐ THE TWO-RUN FIXTURE THIS FILE TURNS ON, oldest first, and every property of it is load
  # bearing:
  #
  # * `user_spec.rb` is NEW (absent then, 12s now) and `legacy_user_spec.rb` is REMOVED (12s then,
  #   none now) — THE RENAME SHAPE, and the area grain cannot produce it: both files are in
  #   `spec/models`, so one rung up this pair of movements is a single area at `±0`.
  # * `order_spec.rb` got 6s SLOWER and `refund_spec.rb` got 6s FASTER, so the SIGN of every `change`
  #   is a fact the fixture can be wrong about — a symmetric pair would serialize identically under a
  #   comparison taken backwards and would pin nothing.
  # * Those two movements are EQUAL IN MAGNITUDE, so the `ABS(...) DESC` ranking between them is
  #   decided by the `path ASC` tie-break, which is the half of the order a client is told it can
  #   reproduce.
  # * `quiet_spec.rb` is RUN BY BOTH and TIMED BY ONLY THE PREVIOUS ONE — the TIMING GAP, the absence
  #   that exists at this quantity and nowhere else on the file grain. Its ordering key is NULL, so
  #   it also pins `NULLS LAST`.
  # * `billing_spec.rb` takes 2s in both runs, so the list carries a file that did not move.
  # * ⭐ NOT ONE FILE'S EXAMPLE COUNT MOVES. Every movement here is a re-timing of the same number of
  #   examples, so the COUNT drill-in over these very rows reports `±0` for everything it can see —
  #   which is what makes this pair's rows unobtainable from the block beside it rather than merely
  #   inconvenient to derive.
  # * `spec/services/payment_spec.rb` sits OUTSIDE the asked-for area in both runs and moves by 50s —
  #   the largest movement in the repository. It must never appear in these rows, and it is what
  #   makes "narrowed to one area" falsifiable rather than a claim about an untested predicate. It is
  #   also TIMED ON BOTH SIDES, which keeps every run-level timing state away from the parent.
  def adjacent_runs(repo: repository, branch: "main")
    ingest(repo, examples_in({ "spec/models/legacy_user_spec.rb" => [2, 6.0],
                               "spec/models/order_spec.rb" => [2, 1.0],
                               "spec/models/refund_spec.rb" => [2, 4.0],
                               "spec/models/billing_spec.rb" => [2, 1.0],
                               "spec/models/quiet_spec.rb" => [2, 3.0],
                               "spec/services/payment_spec.rb" => [2, 1.0] }),
           commit_sha: "previous0001", branch: branch, at: 20.days.ago)
    ingest(repo, examples_in({ "spec/models/user_spec.rb" => [2, 6.0],
                               "spec/models/order_spec.rb" => [2, 4.0],
                               "spec/models/refund_spec.rb" => [2, 1.0],
                               "spec/models/billing_spec.rb" => [2, 1.0],
                               "spec/models/quiet_spec.rb" => [2, nil],
                               "spec/services/payment_spec.rb" => [2, 26.0] }),
           commit_sha: "latest000001", branch: branch, at: 10.days.ago)
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

  describe "an area named under ?spec_directory=" do
    before { adjacent_runs }

    # ⭐ THE DEAD END THIS CELL REMOVES: both operands per file, so an agent can say WHICH FILE took
    # the area's ninety seconds. Ranked by absolute movement with the untimed row last.
    it "serves each file's seconds then, its seconds now, and the movement between them" do
      _window, rows = blocks

      expect(rows["rows"].map { |row| row.values_at("path", "baseline_seconds", "anchor_seconds", "change") })
        .to eq([["spec/models/order_spec.rb", 2.0, 8.0, 6.0],
                ["spec/models/refund_spec.rb", 8.0, 2.0, -6.0],
                ["spec/models/billing_spec.rb", 2.0, 2.0, 0.0],
                ["spec/models/legacy_user_spec.rb", 12.0, nil, nil],
                ["spec/models/quiet_spec.rb", 6.0, nil, nil],
                ["spec/models/user_spec.rb", nil, 12.0, nil]])
    end

    # ⭐ THE CLAIM THAT MAKES THIS A CAPABILITY GAP RATHER THAN A CONVENIENCE KEY, asserted against
    # the response body itself. `order_spec.rb` and `refund_spec.rb` hold the SAME NUMBER OF EXAMPLES
    # in both runs and moved 6 seconds in opposite directions: the count drill-in beside them reports
    # `±0` for both and cannot rank them at all, while this block ranks them at the head of the list.
    # An agent holding the whole response and the three shipped cells cannot compute either row.
    #
    # Narrowed to those two files deliberately: the RENAME pair moves counts as well as seconds — a
    # file that vanished lost its examples too — so a claim over every row would be false and would
    # be pinning the fixture rather than the independence.
    it "ranks files the count drill-in in the same response reports as unmoved" do
      body = get_repository(key: api_key, query: { spec_directory: "spec/models" })
      counts = body["directory_run_file_growth"]["rows"].to_h { |row| [row["path"], row["change"]] }
      seconds = body["directory_runtime_file_growth"]["rows"].to_h { |row| [row["path"], row["change"]] }

      expect(counts.values_at("spec/models/order_spec.rb", "spec/models/refund_spec.rb")).to eq([0, 0])
      expect(seconds.values_at("spec/models/order_spec.rb", "spec/models/refund_spec.rb"))
        .to eq([6.0, -6.0])
      # And they are the two files this block ranks FIRST — so they are not merely present, they are
      # the answer, on a list the block beside it orders by nothing.
      expect(body["directory_runtime_file_growth"]["rows"].first(2).map { |row| row["path"] })
        .to eq(["spec/models/order_spec.rb", "spec/models/refund_spec.rb"])
    end

    # ⭐ THE THREE ABSENCES ARE THREE PREDICATES, because they are three different things to fix. A
    # file on one side only, a file both runs ran and one did not time, and a file that moved.
    it "tells a new file, a removed file and a timing gap apart" do
      _window, rows = blocks

      expect(row_at(rows, "spec/models/user_spec.rb").values_at("new_file", "removed_file", "timing_gap"))
        .to eq([true, false, false])
      expect(row_at(rows, "spec/models/legacy_user_spec.rb")
               .values_at("new_file", "removed_file", "timing_gap"))
        .to eq([false, true, false])
      expect(row_at(rows, "spec/models/quiet_spec.rb").values_at("new_file", "removed_file", "timing_gap"))
        .to eq([false, false, true])
      expect(row_at(rows, "spec/models/order_spec.rb").values_at("new_file", "removed_file", "timing_gap"))
        .to eq([false, false, false])
    end

    # `comparable` says only that there is nothing to subtract, so it is true of the mover and false
    # of all three absences — which is why it cannot stand in for any of them.
    it "marks every row it could not subtract as uncomparable" do
      _window, rows = blocks
      by_path = rows["rows"].to_h { |row| [row["path"], row["comparable"]] }

      expect(by_path).to eq("spec/models/legacy_user_spec.rb" => false, "spec/models/user_spec.rb" => false,
                            "spec/models/order_spec.rb" => true, "spec/models/refund_spec.rb" => true,
                            "spec/models/billing_spec.rb" => true, "spec/models/quiet_spec.rb" => false)
      expect(row_at(rows, "spec/models/billing_spec.rb")["moved"]).to be(false)
      expect(row_at(rows, "spec/models/order_spec.rb")["moved"]).to be(true)
    end

    # ⭐ A NIL SECONDS IS SERVED AS `null` AND NEVER COERCED TO `0`. `SUM` skips NULLs and
    # `duration_seconds` is nullable by design, so a zero here would be "this side was never timed"
    # made byte-identical to "this file took no time" — the one reading the whole block refuses. The
    # file that DID take a real zero movement is served as `0.0`, so the two are distinguishable.
    it "serves an untimed side as null while a genuine zero movement stays zero" do
      _window, rows = blocks

      expect(row_at(rows, "spec/models/quiet_spec.rb")["anchor_seconds"]).to be_nil
      expect(row_at(rows, "spec/models/quiet_spec.rb")["change"]).to be_nil
      expect(row_at(rows, "spec/models/billing_spec.rb")["change"]).to eq(0.0)
    end

    # ⭐ NULLS LAST, which the `order` token declares and this pins: an uncomparable row's ordering
    # key is NULL, and `DESC` alone is NULLS FIRST — which would name the files NOBODY MEASURED the
    # biggest movers in the area and put them at the head of a list about slowdowns. Asserted as a
    # PARTITION rather than on the last row alone, so it cannot be satisfied by one row landing right.
    it "sorts every row it cannot compare below every row it can" do
      window, rows = blocks
      comparable_at = rows["rows"].each_index.select { |i| rows["rows"][i]["comparable"] }
      null_at = rows["rows"].each_index.reject { |i| rows["rows"][i]["comparable"] }

      expect(window["order"]).to eq("abs_change_desc_nulls_last,path_asc")
      expect(comparable_at).to eq([0, 1, 2])
      expect(null_at).to eq([3, 4, 5])
      expect(comparable_at.max).to be < null_at.min
      # And the three that sorted last are ordered among themselves by the path tie-break.
      expect(null_at.map { |i| rows["rows"][i]["path"] })
        .to eq(["spec/models/legacy_user_spec.rb", "spec/models/quiet_spec.rb",
                "spec/models/user_spec.rb"])
    end

    # The tie-break the `order` token promises, over two movements equal in magnitude and opposite in
    # sign — so the ordering is not satisfiable by luck.
    it "breaks a tie on equal movement by path, as its order token says" do
      window, rows = blocks
      tied = rows["rows"].select { |row| row["change"]&.abs == 6.0 }.map { |row| row["path"] }

      expect(window["tie_break_served"]).to be(true)
      expect(tied).to eq(["spec/models/order_spec.rb", "spec/models/refund_spec.rb"])
    end

    # ⭐ ALL FOUR DENOMINATORS, AND THEY ARE THIS AREA'S. The suite's totals move entirely outside the
    # asked-for area (payment_spec), so a block reading the parent's identically-named whole-run
    # figures produces visibly wrong numbers. The timed pair differs from the recorded pair on the
    # anchor side (10 rows, 8 timed — `quiet_spec.rb` went silent), which is what makes the two
    # unreadable off each other.
    it "states all four denominators over the asked-for area and not over the run" do
      _window, rows = blocks

      expect(rows.values_at("baseline_recorded_count", "anchor_recorded_count",
                            "baseline_timed_count", "anchor_timed_count"))
        .to eq([10, 10, 10, 8])
      expect(rows["file_count"]).to eq(6)
      expect(rows["truncated"]).to be(false)
      # The parent block over the same request counts the whole SUITE, which is a different figure.
      body = get_repository(key: api_key, query: { spec_directory: "spec/models" })
      expect(body["directory_runtime_growth"]["anchor_recorded_count"]).to eq(12)
    end

    # `file_count` is counted BEFORE the `LIMIT` by a window function, so `truncated` is disclosed
    # against a population rather than against the list's own length. Asserted under a stubbed cap so
    # the two figures genuinely differ.
    it "discloses the cap against the area's file count and not against the rows it returned" do
      stub_const("SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT", 2)
      window, rows = blocks

      expect(rows["rows"].length).to eq(2)
      expect(rows["file_count"]).to eq(6)
      expect(rows["truncated"]).to be(true)
      # And the cap a client is told about is the one the query actually applied.
      expect(window["limit"]).to eq(2)
    end

    # ⭐ NARROWED TO ONE AREA, AND THE EQUALITY IS AT ONE DEPTH. The largest movement in the whole
    # repository sits outside the asked-for area and must not appear — which is what makes the
    # predicate falsifiable rather than an untested claim.
    it "never serves a file outside the area that was asked for" do
      _window, rows = blocks

      expect(rows["rows"].map { |row| row["path"] }).to all(start_with("spec/models/"))
      expect(rows["rows"].map { |row| row["path"] }).not_to include("spec/services/payment_spec.rb")
      # And the area outside it really did move more than anything inside it.
      body = get_repository(key: api_key)
      expect(body["directory_runtime_growth"]["rows"].first["path"]).to eq("spec/services")
    end

    # ⭐ OPERANDS, NEVER THE PRESENTER'S LABELS — and this example's job is mostly in the FUTURE.
    # `SpecDirectoryFileRuntimeGrowth` carries no labels today: the typographic and screen-reader
    # spellings its three siblings have — a U+2212, an `"±0"`, a `"not reported"`, a `"New file"` —
    # land on it with the `repositories#show` panel that renders them, deliberately not before, so
    # they can be judged against a render rather than frozen by a green spec. That is exactly when
    # this endpoint is at risk of quietly acquiring them, and a client served a label would be
    # splitting strings and stripping glyphs to compare two rows. Walked over every string at any
    # depth rather than over today's key list, so a label added later is caught HERE rather than by
    # nobody.
    it "serves no view string anywhere in either block" do
      window, rows = blocks

      expect(strings_in(rows)).to all(start_with("spec/models/"))
      expect(strings_in(rows)).not_to include("New file", "File removed", "Not timed", "±0",
                                              "not reported")
      expect(strings_in(rows).join).not_to include("−", "0.00s")
      # The window block's own strings are TOKENS, and the path is the ask restated.
      expect(strings_in(window))
        .to contain_exactly("spec/models", "abs_change_desc_nulls_last,path_asc",
                            "previous_run_on_branch", "comparable")
    end

    # The vocabulary the whole square shares, so two blocks under one request cannot name one run two
    # ways. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE, and every `change` is signed in
    # that direction — asserted through a file that got SLOWER, where a comparison taken backwards
    # would report the same magnitude with the wrong sign.
    it "names the two runs as anchor and baseline, and signs every change in that direction" do
      body = get_repository(key: api_key, query: { spec_directory: "spec/models" })
      rows = body["directory_runtime_file_growth"]
      parent = body["directory_runtime_growth_window"]

      expect(parent["anchor_commit_sha"]).to eq("latest000001")
      expect(parent["baseline_commit_sha"]).to eq("previous0001")
      expect(row_at(rows, "spec/models/order_spec.rb").values_at("baseline_seconds", "anchor_seconds"))
        .to eq([2.0, 8.0])
      expect(row_at(rows, "spec/models/order_spec.rb")["change"]).to eq(6.0)
    end

    # NO SECOND SPELLING OF THE OPERANDS — `branch` and the two shas are served once, on the parent
    # window block, and repeating them here would be two blocks under one request naming one run two
    # ways.
    it "does not restate the branch or either commit sha" do
      window, = blocks

      expect(window.keys).to contain_exactly("path", "order", "tie_break_served", "basis", "state",
                                             "comparable", "limit")
    end
  end

  describe "the contract block when nobody asked" do
    before { adjacent_runs }

    # ⭐ `path` IS THE DISCRIMINATOR between "you did not ask" and "you asked and it refused". The
    # window block is served UNCONDITIONALLY — a block that explains a `null` is worthless if it is
    # itself absent whenever the `null` happens, and it is absent on the commonest request of all.
    it "serves the contract with a null path, and null rows, on a request that names no area" do
      window, rows = blocks(query: {})

      expect(window["path"]).to be_nil
      expect(window["comparable"]).to be(true)
      expect(window["state"]).to eq("comparable")
      expect(rows).to be_nil
    end

    # A malformed shape is treated as NO ASK at all rather than echoed, which is why `path` is never
    # read off the raw parameter.
    it "treats a malformed spec_directory as no ask rather than echoing it" do
      window, rows = blocks(query: { spec_directory: { "evil" => "hash" } })

      expect(window["path"]).to be_nil
      expect(rows).to be_nil
    end

    # An area neither run recorded is an ordinary answer — a stale bookmark, a typo, a directory
    # deleted since — and it is an EMPTY row list rather than a `null` or a refusal, because the runs
    # are perfectly comparable. The `path` is echoed, so a client can tell this from "you did not
    # ask".
    it "serves an empty row list for an area neither run recorded" do
      window, rows = blocks(query: { spec_directory: "spec/ghosts" })

      expect(window["path"]).to eq("spec/ghosts")
      expect(window["comparable"]).to be(true)
      expect(rows["rows"]).to eq([])
      expect(rows["file_count"]).to be_zero
    end
  end

  # ⭐ THE PROPERTY THIS PAIR IS DEFINED BY: the drill-in is ABSENT whenever the block it drills out
  # of cannot compare, and its `state` is that block's verdict verbatim. Never a second opinion about
  # two runs, and — for six of the nine — never derivable from one area's rows at all.
  describe "when the parent runtime comparison cannot compare" do
    def two_runs(previous:, latest:, previous_total: nil, latest_total: nil, **latest_attrs)
      ingest(repository, examples_in(previous), commit_sha: "previous0001", at: 20.days.ago,
                                                total: previous_total)
      ingest(repository, examples_in(latest), commit_sha: "latest000001", at: 10.days.ago,
                                              total: latest_total, **latest_attrs)
    end

    # The three states the parent decides from the two runs ALONE, before any query.
    it "carries 'previous_unmeasured' and serves null rows" do
      two_runs(previous: {}, latest: { "spec/models/a_spec.rb" => [3, 1.0] }, previous_total: 0)
      window, rows = blocks

      expect(window["state"]).to eq("previous_unmeasured")
      expect(window["comparable"]).to be(false)
      expect(window["path"]).to eq("spec/models")
      expect(rows).to be_nil
    end

    it "carries 'assembled_differently' and serves null rows" do
      ingest(repository, examples_in({ "spec/models/a_spec.rb" => [3, 1.0] }),
             commit_sha: "previous0001", at: 20.days.ago)
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "latest000001", branch: "main", total_specs_count: 3, annotated_specs_count: 0,
          duration_seconds: 60.0, ci_run_id: "gha-1" },
        specs: examples_in({ "spec/models/a_spec.rb" => [3, 1.0] }).map(&:deep_stringify_keys),
        shard_id: "0"
      )
      TestRun.where(commit_sha: "latest000001").update_all(created_at: 10.days.ago)
      window, rows = blocks

      expect(window["state"]).to eq("assembled_differently")
      expect(rows).to be_nil
    end

    # ⭐ THE THREE TIMED STATES, which exist at this quantity and nowhere on the count pair — the
    # reason this block's state enumeration is nine and its sibling's is six. A run that recorded
    # every row and timed none of them must read as "this run reported no timings" and never as
    # "every file lost all its time".
    {
      "neither_timed" => [{ "spec/models/a_spec.rb" => [3, nil] }, { "spec/models/a_spec.rb" => [3, nil] }],
      "previous_untimed" => [{ "spec/models/a_spec.rb" => [3, nil] }, { "spec/models/a_spec.rb" => [3, 1.0] }],
      "latest_untimed" => [{ "spec/models/a_spec.rb" => [3, 1.0] }, { "spec/models/a_spec.rb" => [3, nil] }]
    }.each do |state, (previous, latest)|
      it "carries '#{state}' and serves null rows" do
        two_runs(previous: previous, latest: latest)
        window, rows = blocks

        expect(window["state"]).to eq(state)
        expect(window["comparable"]).to be(false)
        expect(rows).to be_nil
      end
    end

    # ⭐ THE GATE IS THE RUNTIME PARENT'S AND NOT THE COUNT PARENT'S — the substitution that would
    # compile, satisfy every call the controller makes, and be wrong. These two runs recorded every
    # row and timed none: the COUNT pair in the same response is comparable and serves rows, and this
    # one refuses. Gated on the wrong parent, this block would serve a table of nulls under
    # `comparable: true`.
    it "refuses where the count pair in the same response compares happily" do
      two_runs(previous: { "spec/models/a_spec.rb" => [3, nil] },
               latest: { "spec/models/a_spec.rb" => [5, nil] })
      body = get_repository(key: api_key, query: { spec_directory: "spec/models" })

      expect(body["directory_run_file_growth_window"]["comparable"]).to be(true)
      expect(body["directory_run_file_growth"]["rows"].length).to eq(1)
      expect(body["directory_runtime_file_growth_window"]["comparable"]).to be(false)
      expect(body["directory_runtime_file_growth"]).to be_nil
    end

    # ⭐ IT DOES NOT RE-DERIVE A RUN-LEVEL ABSENCE FROM ONE AREA'S MISSING TIMINGS, which is the
    # mistake the inheritance exists to forbid. `spec/models` is timed by NEITHER run, inside two runs
    # that time plenty elsewhere: an object re-deriving from this area's rows would spell it
    # `neither_timed` — "neither run reported a timing anywhere" — directly beneath a parent block
    # listing both runs' per-area seconds. The inherited verdict is `comparable`, and the area's own
    # silence is a row-level `timing_gap`.
    it "does not spell one area's missing timings as a fact about the runs" do
      two_runs(previous: { "spec/models/a_spec.rb" => [2, nil], "spec/requests/b_spec.rb" => [2, 1.0] },
               latest: { "spec/models/a_spec.rb" => [2, nil], "spec/requests/b_spec.rb" => [2, 5.0] })
      body = get_repository(key: api_key, query: { spec_directory: "spec/models" })
      window = body["directory_runtime_file_growth_window"]

      expect(window["state"]).to eq("comparable")
      expect(window["comparable"]).to be(true)
      expect(body["directory_runtime_file_growth"]["rows"].sole["timing_gap"]).to be(true)
      # The parent, which CAN speak about the runs, says the runs did report timings.
      expect(body["directory_runtime_growth_window"]["state"]).to eq("comparable")
    end

    # The two SERIALIZER-level states, where the parent object is never constructed at all. Told
    # apart by `latest_test_run.nil?` off the one memoized accessor, so the token and the object it
    # stands in for cannot come apart.
    it "carries 'no_latest_run' for a repository CI has never reported on" do
      window, rows = blocks

      expect(window["state"]).to eq("no_latest_run")
      expect(window["comparable"]).to be(false)
      expect(window["path"]).to eq("spec/models")
      expect(rows).to be_nil
    end

    it "carries 'no_previous_run' for the first run on a branch" do
      ingest(repository, examples_in({ "spec/models/a_spec.rb" => [3, 1.0] }),
             commit_sha: "onlyrun00001", at: 10.days.ago)
      window, rows = blocks

      expect(window["state"]).to eq("no_previous_run")
      expect(window["comparable"]).to be(false)
      expect(rows).to be_nil
    end

    # ⭐ NEVER A BLOCK OF ZEROS. `.for` returns an object without any of the counts for a parent that
    # cannot compare, so serving them raw would print `anchor_timed_count: 0` for a latest run that
    # timed four hundred rows in that very area — a fabricated denominator among the fields that exist
    # to be trustworthy. The actionable half is the `state` token, served unconditionally one key up.
    it "serves null rather than a zeroed block in every refusing state" do
      two_runs(previous: { "spec/models/a_spec.rb" => [3, 1.0] },
               latest: { "spec/models/a_spec.rb" => [3, nil] })
      _window, rows = blocks

      expect(rows).to be_nil
    end
  end

  describe "what the per-file runtime block costs the endpoint" do
    # ⭐ NO ASK, NO QUERY. The gate is decided from the params before any read is issued, so a client
    # that never sends the parameter pays nothing for the key's existence — on a repository whose
    # comparison is perfectly comparable, which is what makes the zero the ASK's refusal rather than
    # the comparison's.
    it "adds no query at all to a request that names no area" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      expect(directory_file_runtime_growth_grain_reads { get_repository(key: api_key) }).to be_empty
      expect(count_queries { get_repository(key: api_key) }).to eq(baseline)
      # The comparison really was available — the parent block answered in the same request.
      expect(get_repository(key: api_key)["directory_runtime_growth"]["rows"]).to be_present
      expect(get_repository(key: api_key)["directory_runtime_file_growth"]).to be_nil
    end

    # ⭐ ZERO QUERIES EVEN WITH `?spec_directory=` SET, whenever the parent refuses — the bound the
    # ticket states and the one an implementation that queried first and gated afterwards would miss
    # on every example above. Asserted in a TIMED state specifically: those are the refusals the
    # parent reached BY RUNNING a query, so an object that mistook "the parent already read the
    # table" for "so may I" pays for a second read precisely there.
    it "asks nothing for a named area when the parent cannot compare" do
      ingest(repository, examples_in({ "spec/models/a_spec.rb" => [3, nil] }),
             commit_sha: "previous0001", at: 20.days.ago)
      ingest(repository, examples_in({ "spec/models/a_spec.rb" => [4, nil] }),
             commit_sha: "latest000001", at: 10.days.ago)
      query = { spec_directory: "spec/models" }
      get_repository(key: api_key, query: query)

      expect(blocks(query: query).first["state"]).to eq("neither_timed")
      expect(directory_file_runtime_growth_grain_reads { get_repository(key: api_key, query: query) })
        .to be_empty
    end

    # ONE READ WHEN ASKED, and the ask's whole cost is the grains it opens. `?spec_directory=` now
    # opens THREE reads of `spec_observations` — the durations drill-in, the count drill-in, and this
    # one — so the total is `+3` and this grain's own contribution is exactly one.
    it "reads spec_observations exactly once for its own grain when an area is named" do
      adjacent_runs
      get_repository(key: api_key)
      baseline = count_queries { get_repository(key: api_key) }

      expect(directory_file_runtime_growth_grain_reads do
        get_repository(key: api_key, query: { spec_directory: "spec/models" })
      end.length).to eq(1)
      expect(count_queries { get_repository(key: api_key, query: { spec_directory: "spec/models" }) })
        .to eq(baseline + 3)
    end

    # ⭐ THE PARTITION ITSELF, which is what a per-grain count cannot check. This read carries BOTH
    # the runtime growth ordering AND the area predicate AND the by-file grouping, so without the
    # exclusions `observation_reads_by_grain` carries it would land in THREE grains at once. A
    # double-classified read makes the parts sum to MORE than the total; an unclassified one makes
    # them sum to less.
    it "reads once for its own grain and leaves every other grain alone" do
      adjacent_runs
      query = { spec_directory: "spec/models" }
      get_repository(key: api_key, query: query)

      grains = observation_reads_by_grain { get_repository(key: api_key, query: query) }

      expect(grains.map(&:length)).to eq([1, 1, 2, 2, 0, 1, 1, 0, 0, 1, 1, 1])
      expect(observation_reads { get_repository(key: api_key, query: query) }.length)
        .to eq(classified_observation_reads { get_repository(key: api_key, query: query) })
      # And the three neighbouring growth grains are each a different statement from this one.
      expect([grains[5].first, grains[9].first, grains[10].first]).not_to include(grains[11].first)
    end
  end
end
