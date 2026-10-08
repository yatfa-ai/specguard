# frozen_string_literal: true

# THE GROWTH FAMILY OF `RepositoryOverview`, MOVED OUT WHOLE — the sixteen `serialized_*growth*`
# methods that turn the run-over-run and window-over-window growth presenters into the JSON the
# overview's `body` serves, and the six memoized presenter accessors they read. It follows the
# `LatestRunSerializer` precedent: a collaborator the overview owns one memoized instance of
# (`RepositoryOverview#growth`), reaching back into it only for the runs and the asks.
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/repository_overview.rb`; nothing about the emitted JSON, its key order, its state
# tokens or its query count changed. The comments still say "above", "below" and "this file", and
# those coordinates are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position word
# as pointing into the overview, not into this class.
#
# ONE INSTANCE PER OVERVIEW IS LOAD-BEARING. The presenter accessors memoize in instance
# variables, so a second serializer would re-issue the previous-run `shard_totals` and layer reads
# and move the `observation_reads` pins. The overview memoizes it; do not build one per call.
#
# What it reads back from the overview is exactly five methods, delegated privately below:
# `latest_test_run`, `previous_test_run`, `history_runs`, `requested_branch` and
# `requested_spec_directory`. It holds no `repository` and no `params` of its own and issues no SQL.
class RepositoryGrowthSerializer
  def initialize(overview:)
    @overview = overview
  end

  # The contract the growth-by-area rows below are served under — and, when they are `null`, the
  # reason they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` and
  # `RepositoryWindowRankingSerializer#serialized_unstable_tests_window` both argue for: a client tests one thing rather than
  # distinguishing an absent key from a null one, and a block that explains a `null` is worthless if
  # it is itself absent whenever the `null` happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists for the branch reason its flakiness sibling
  # gives, which binds at least as hard here. `SpecDirectoryWindowGrowth` picks its baseline with
  # two in-memory predicates — `TestRun#suite_size_measured?` and `TestRun#assembled_like?`, which
  # is `shard_count` equality — and NEITHER looks at `branch`. Handed the INTERLEAVED all-branch
  # window `serialized_history_window` warns about, the walk would anchor on a `main` run and
  # baseline against a `feature/x` run that happened to be sharded the same way, and report "this
  # area grew by 300 examples" where the truth is two different pieces of code. So unfiltered, the
  # object IS NOT CONSTRUCTED — no rows, and no read to produce them — and this boolean says so.
  #
  # Read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ? true :
  # false`. A second copy of the gate is a second thing to keep true, and the one that decides what
  # was read is the one worth serving. So `grouped` is exactly `directory_growth != null`.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED", the same disclaimer the flakiness window
  # carries: the object is constructed for every branch-scoped ask, and what came of it is the
  # block's own business. Its `state` is what separates the eight answers.
  #
  # `order` names both keys and `tie_break_served` is TRUE, which is the honest reading here and
  # not the only block on this endpoint where it is. `SpecObservation.directory_growth_between`
  # orders by `ABS(anchor_count - baseline_count) DESC` then `path ASC`, and both operands and the
  # path go out on every row — so a client CAN reproduce this order from what it holds, unlike
  # `history` (whose tie-break is an ingest sequence no row carries) and `branches`.
  #
  # `basis` IS THE OBJECT'S OWN LOAD-BEARING LIMITATION, served as a token because a client cannot
  # act on the paragraph `spec_directory_window_growth.rb` spends on it. The figures compare TWO
  # ENDPOINTS of a thirty-run window; they are not a series over it. An area that added 300
  # examples in run 12 and deleted them again in run 25 reads `change: 0` here, indistinguishable
  # from an area nothing happened in — and a thirty-run heading over a two-run measurement is
  # exactly the claim a caption would otherwise imply and nothing looked at. `covered_run_count`
  # says how far apart the two endpoints are; this says that two is all there are.
  def serialized_directory_growth_window
    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "two_endpoints",
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !spec_directory_window_growth.nil?
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK ACROSS THE BRANCH WINDOW — the agent-readable half of
  # the panel `repositories#show` renders from the same object, and the "in which areas" half of the
  # roadmap's growth axis, which is the one this endpoint has never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`.
  # `latest_run.spec_directories` carries a per-directory `recorded_count` for exactly ONE run, and
  # `serialized_history_row` carries run TOTALS with no area grain on any row. Neither is the other's
  # missing half: an agent holding both, for every row of the window, knows how much the suite grew
  # and nothing about where. Two responses could not be subtracted into this either — that is the
  # polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryWindowGrowth` is view-free, so the API and the
  # panel name the same areas, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query — see
  # `spec_directory_window_growth` for the ORDER that window has to be handed over in, which is the
  # one thing about this block that is not shared with its flakiness sibling.
  #
  # `state` IS SERVED AS THE SYMBOL AND NEVER COLLAPSED TO A BOOLEAN OR TO `null`. The object
  # distinguishes eight states, seven of them absences, and its own comment is why they are not one:
  # "every earlier run on this branch reported no tests", "they were all assembled differently from
  # this one" and "the run at the far end recorded no per-example rows" are one blank panel and
  # three different things to go and fix. `comparable` rides beside it as the single boolean a
  # client that only wants the rows can branch on, read off the object's own predicate rather than
  # re-derived here from the symbol.
  #
  # THE HONESTY FIGURES ARE SERVED, NOT DROPPED, and they are the block's actual payload in seven of
  # the eight states. The baseline is WALKED from the far end of the window, so the comparison a
  # client is handed can be SHORTER than the window it asked over — `window_run_count` is what the
  # window holds and `covered_run_count`/`runs_back` are what the figures span, and a 26-run
  # comparison under a 30-run heading is a fact about the measurement rather than an implementation
  # detail. The two skip counts stay SPLIT rather than summed, on the object's own rule: a client
  # that stopped reporting totals and a branch whose sharding changed are two different repairs, and
  # a bare "4 runs were skipped" is a fact nobody can act on.
  #
  # BOTH COMMIT SHAS, so a client can say WHICH TWO RUNS the figure spans and go read them. They are
  # nullable for the reason the states are: the walk finds no baseline in four of them, and there is
  # no run to name. Anchor and baseline rather than "first" and "last" — the anchor is the newest
  # run of the window and the baseline is the OLDER end, which is the direction every `change` on
  # every row below is signed in.
  #
  # ⭐ THE SPAN IS NULL WHEREVER THE SHA IS — one predicate, `baseline_run`, read ONCE into a local
  # and used for all FOUR span keys, so the figures and the run they are counted to cannot come
  # apart. `#covered_run_count` is `runs_back + 1` and `runs_back` keeps its `0` default in exactly
  # the four states the walk landed on no baseline in, so serving it raw asserts a ONE-RUN
  # COMPARISON that was never taken: `anchor_unmeasured` would carry `covered_run_count: 1` beside
  # `window_run_count: 2` and `shortened: false` — the block's own claim that the span equals the
  # window, and its own figures denying it, two keys apart. The degenerate end is worse: an unknown
  # `?branch=` selects ZERO runs and would serve a comparison spanning one run over a window holding
  # none, next to an `anchor_commit_sha` of `null`.
  #
  # `shortened` IS THE FOURTH, and it fails in the opposite direction from the other three, which is
  # why enumerating from `anchor_unmeasured` alone once left it ungated. The four no-baseline states
  # split in half on this key. `anchor_unmeasured` and `no_earlier_run` never enter the walk, so the
  # skip counters keep their `0` default and `shortened?` is benignly `false`. `no_measured_baseline`
  # and `no_comparable_composition` are reached ONLY from inside the walk, and only by every earlier
  # run being skipped — `skipped_count.positive?` is the very mechanism that reaches them — so
  # `shortened?` is necessarily `true` in both, ALWAYS, not merely sometimes. Ungated it printed
  # `shortened: true` beside `covered_run_count: null` and `baseline_commit_sha: null`: a shortened
  # span asserted for a comparison that was never taken. `false` would be no better than `true`
  # here — it is equally a claim about a span, namely that it equals the window — so the answer is
  # `null`, the same answer the other three give, for the same reason.
  #
  # The two SKIP COUNTS are NOT gated and must not be: they are facts about the walk rather than
  # about the span, they are the actionable half of both those states ("two earlier runs reported no
  # tests"), and they are true whether or not the walk found somewhere to land.
  #
  # The panel never prints the span in these states — `spec_directory_window_growth_span_sentence`
  # is reached only under `comparable? && any_movement?` — so this endpoint is the FIRST surface that
  # can be wrong with it, and a fabricated span sitting among the honesty fields is the exact failure
  # they exist to prevent. `null` is the same answer `baseline_commit_sha` already gives, and it is a
  # PINNED CONTRACT rather than a default: the spec asserts the keys in every one of the four.
  # The four states that DID land on a baseline — `comparable` and the three recorded-rows absences
  # — carry a true span, and it is their actionable payload ("the run that recorded nothing is two
  # back"), so the gate is `baseline_run` and never `comparable?`.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it. `directory_count` is counted BEFORE
  # `SpecObservation::MOVED_DIRECTORIES_LIMIT` applies (a window function, so it runs before the
  # `LIMIT`), which is what makes the comparison answerable at all; `limit` is read off that
  # constant rather than restated — this call site passes no `limit:`, so the constant IS the bound
  # the query applied. It is the object's default that makes that true, not the serving of it: the
  # object does not expose the limit it was built with, so a caller that ever passed `limit: 5` here
  # would need this key taught to follow it rather than re-read the constant.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on — how many per-example rows each end wrote in total — and deliberately not
  # `TestRun#total_specs_count`, which is re-derived by SUM over shard reports and can legitimately
  # differ from the rows a run actually wrote. Every figure on this block is counted off those rows.
  #
  # ⭐ THOSE COUNTS ARE GATED ON `baseline_run` TOO, on the same rule as the span keys above them.
  # `SpecDirectoryWindowGrowth.from_tuples` is the ONLY path that reads the aggregate, and the only
  # one that passes `baseline_run:` — so the four states the walk short-circuits into before it
  # (`anchor_unmeasured`, `no_earlier_run`, `no_measured_baseline`, `no_comparable_composition`)
  # carry no totals at all and fall back to the object's `0` defaults. `baseline_run.nil?` is
  # therefore EXACTLY "the totals were never counted", with no third case. Served raw, those
  # defaults would print `anchor_recorded_count: 0` for an anchor that wrote four hundred rows, and
  # `directory_count: 0` for a comparison whose query was never issued — fabricated denominators
  # sitting among the fields that exist to be trustworthy. `truncated` rides along because it is
  # DERIVED from `directory_count` (`directory_count > rows.size`): once its operand is `null`, a
  # `false` beside it would be a completeness claim about a list this same body declares unknown.
  #
  # NOT `comparable?`, which is the weaker predicate and would null too much: `neither_recorded`,
  # `baseline_unrecorded` and `anchor_unrecorded` are non-comparable but DID read the aggregate, so
  # their totals are true — including their genuine `0`s — and are the actionable half of those
  # states. Four of the eight states carry these figures; the other four have none to carry.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all where there is nothing to compare. The
  # walk is pure in-memory predicates over rows already loaded, and the comparison itself is two run
  # ids in an `IN` list whatever the window's length — already plan-certified at the seeded table
  # size in `spec/models/spec_observation_spec.rb`, so that certification transfers rather than
  # needing to be repeated here. Same argument `serialized_unstable_tests` makes for itself.
  def serialized_directory_growth
    growth = spec_directory_window_growth

    return nil if growth.nil?

    baseline = growth.baseline_run

    {
      state: growth.state,
      comparable: growth.comparable?,
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      window_run_count: growth.window_run_count,
      covered_run_count: baseline && growth.covered_run_count,
      runs_back: baseline && growth.runs_back,
      shortened: baseline && growth.shortened?,
      skipped_unmeasured_count: growth.skipped_unmeasured_count,
      skipped_assembled_differently_count: growth.skipped_assembled_differently_count,
      anchor_commit_sha: growth.anchor_run&.commit_sha,
      baseline_commit_sha: baseline&.commit_sha,
      directory_count: baseline && growth.directory_count,
      truncated: baseline && growth.truncated?,
      baseline_recorded_count: baseline && growth.baseline_recorded_count,
      anchor_recorded_count: baseline && growth.anchor_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's movement across the window, and BOTH OPERANDS it was taken across — never one of the
  # labels the row builds for the panel. `SpecDirectoryWindowGrowth::Row` carries `change_label`,
  # `change_reading`, `baseline_count_label` and `anchor_count_label`, which are typographic and
  # screen-reader spellings of these same numbers: a U+2212 for a negative, `"±0"` for an area that
  # did not move, `"New area"` where a delta would be arithmetic on a side that was never measured,
  # and delimited numerals throughout. A client served those would be splitting strings and
  # stripping glyphs to compare two rows. `serialized_unstable_test_row` set this rule; this block
  # is where it costs the most, because the labels here are the panel's whole vocabulary.
  #
  # `previous_count`/`latest_count` are the aggregate's own two sides and are the parent Struct's
  # names; they go out as `baseline_count`/`anchor_count`, the names the window object itself uses
  # for the two ends of the comparison and the two shas above are served under. The translation
  # happens once, here, rather than in every client's head.
  #
  # `moved`, `new_area` and `removed_area` are the three states the label collapses, served as the
  # booleans they are. `new_area` and `removed_area` are NOT derivable from `change` alone — an area
  # at zero on one side is a real absence, and `+40` against an absent side reads identically to an
  # existing area that gained forty examples, which is the one distinction a client scanning this
  # list most needs. The block that holds this row has already established that BOTH runs recorded
  # rows, which is what makes a zero on one side that area's own absence rather than a run that
  # recorded nothing anywhere.
  def serialized_directory_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?
    }
  end

  # The contract the RUN-OVER-RUN growth rows below are served under — and, when they are `null`,
  # the reason they are. Served UNCONDITIONALLY, on the key-always-present rule
  # `serialized_directory_growth_window` and `latest_run.shards` both argue for: a block that
  # explains a `null` is worthless if it is itself absent whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK HERE, NOT A RUN WINDOW — the suffix this endpoint has used
  # three times for "the facts that decide how the array beside it may be read". This comparison
  # spans exactly TWO runs and `basis` says so in a token rather than leaving the suffix to be read
  # as a claim about depth. The pairing is kept because a client that learned the shape once
  # (`history_window`/`history`, `unstable_tests_window`/`unstable_tests`,
  # `directory_growth_window`/`directory_growth`) should not have to learn a fourth.
  #
  # ⭐ `state` LIVES HERE AND NOT ON THE ROWS BLOCK, WHICH IS WHERE THIS BLOCK DIVERGES FROM ITS
  # WINDOW SIBLING AND WHY. There, `state` rides on the rows block because that block is `null`
  # only when the object was never constructed, and `grouped` out here covers that one case. Here
  # there are TWO ways to have no rows — the object was not constructed (no runs to compare) and
  # the object was constructed and could not compare — and a `state` on the rows block would be
  # absent in exactly the first of them. So the nine-way answer is served on the block that is
  # always present, and the rows block carries figures only.
  #
  # THE STATE ENUMERATION, in full, because a client must be able to enumerate it:
  #
  # * `no_latest_run` — CI has never reported. Serializer-level; see `spec_directory_growth`.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch to compare it
  #   against. Serializer-level, and it covers TWO shapes that `branch` separates: a `branch` of
  #   `null` is a latest run whose client sent no branch (there is no branch to compare on, and
  #   `Repository#previous_test_run_on_branch` refuses to pool anonymous runs into a fictional
  #   history), and a named `branch` is a genuine first run on that branch.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — `SpecDirectoryGrowth`'s
  #   three pre-query states, decided from the two runs alone.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — its three row-decided states.
  # * `comparable` — the rows block below is non-null.
  #
  # The first two are ADDED AT THIS CALL SITE and are not model states, deliberately.
  # `SpecDirectoryGrowth.for` dereferences its second argument on its second line, so it must not be
  # handed a nil; widening it to accept one would change a contract the dashboard already guards for
  # itself (`repositories_controller.rb`, `if @latest_test_run && @previous_test_run`). The guard is
  # duplicated here rather than the model relaxed, and `no_previous_run` is a DISTINCT token from
  # `previous_unmeasured` because they are different repairs: "there is nothing to compare against"
  # against "the run we compared against reported no tests".
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it
  # is exactly `directory_run_growth != null`, so there is one boolean here and not two.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE. `branch_scope` is the constant `single_branch`
  # because this comparison is branch-correct BY CONSTRUCTION rather than by a parameter:
  # `Repository#previous_test_run_on_branch` scopes to the latest run's own branch and refuses a
  # blank one. So `branch` names the branch the comparison WAS MADE ON — read off the latest run,
  # never off `requested_branch`, which narrows `history` and must not be read as having narrowed
  # this. Like `latest_run`, this block is NOT re-anchored by `?branch=`: under `?branch=main` on a
  # repository whose newest run is on `feature/x`, this still compares the two newest `feature/x`
  # runs, and `branch` says `feature/x` so the two cannot be confused. And like `latest_run` again,
  # it IS re-anchored by `?commit_sha=` — the one parameter that moves the anchor. Under an explicit
  # ask `anchor_commit_sha` and `branch` are the NAMED run's, and the baseline is the run before THAT
  # one on ITS branch, because `previous_test_run_on_branch` is handed the very `latest_test_run`
  # memo `latest_run` was built from. Both halves are stated here deliberately: this block is one of
  # the few that enumerates what does and does not move it, and an enumeration that named only the
  # parameter with no effect would be the more misleading half to leave standing alone.
  #
  # `basis` IS WHAT SEPARATES THIS PAIR FROM THE ONE ABOVE IT, and it is the key a client reads to
  # know which of the two growth measurements it is holding. `two_endpoints` there says the figures
  # are the two ends of a thirty-run window and not a series over it; `previous_run_on_branch` here
  # says the baseline is one specific run, named by `baseline_commit_sha`, and that the comparison
  # therefore has NO such gap in it — an area that gained 300 examples and gave them back cannot
  # hide inside a two-run comparison. Spelled as the baseline's RULE rather than as "adjacent_runs",
  # which would be read as adjacent in the history `history` serves and is not what this is: the two
  # runs are consecutive ON THEIR BRANCH, and the all-branch history routinely has other branches'
  # runs between them.
  #
  # `order` and `tie_break_served` are the WINDOW SIBLING'S OWN VALUES because they are the same
  # query's: `SpecObservation.directory_growth_between` orders by `ABS(...) DESC` then `path ASC`,
  # and both operands and the path go out on every row, so a client can reproduce this order from
  # what it holds.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS, under the sibling's names rather
  # than "latest"/"previous", because the ROWS below are served as `anchor_count`/`baseline_count`
  # and a client must be able to tell which sha each operand was counted on. ANCHOR IS THE LATEST
  # RUN and BASELINE IS THE PREVIOUS ONE, which is the direction every `change` is signed in. Both
  # are nullable and independently so: `baseline_commit_sha` is `null` in both serializer states,
  # and `anchor_commit_sha` in `no_latest_run` alone.
  def serialized_directory_run_growth_window
    growth = spec_directory_growth

    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # The contract block for `layer_run_growth`, shaped like `directory_run_growth_window` and
  # carrying the same two runs (`anchor_commit_sha` = the latest/named run, `baseline_commit_sha` =
  # its predecessor ON ITS OWN BRANCH). `state` is `LayerRunGrowth#state`, plus the two
  # serializer-level states added at this call site exactly as the area sibling does —
  # `no_latest_run` (CI never reported) and `no_previous_run` (first run on the branch, or a latest
  # run that named no branch) — because the presenter is never handed a nil previous run.
  # `comparable` is exactly `layer_run_growth != null`.
  def serialized_layer_run_growth_window
    growth = layer_run_growth

    {
      basis: "previous_run_on_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # The declared-layer mix movement — `null` in EVERY non-comparable state, never a block of zeros
  # (a zero here would be a fabricated measurement for a run that recorded no mix). Per layer, in
  # `SpecObservation::DECLARED_LAYER_KEYS` order, `{baseline_count, anchor_count, change}`; a layer
  # that did not move serves `change: 0`. The per-layer changes sum to
  # `anchor_recorded_count - baseline_recorded_count`. Operands and difference only — no view
  # strings; the path is never consulted.
  def serialized_layer_run_growth
    growth = layer_run_growth

    return nil unless growth&.comparable?

    {
      layers: growth.rows.transform_values do |row|
        { baseline_count: row.baseline_count, anchor_count: row.anchor_count, change: row.change }
      end,
      baseline_recorded_count: growth.baseline_recorded_count,
      anchor_recorded_count: growth.anchor_recorded_count
    }
  end

  # The contract block for `layer_runtime_growth`, the exact shape of `layer_run_growth_window` so a
  # client reads both with one routine. `state` is `LayerRuntimeGrowth#state` (ten states) plus the
  # two serializer-level ones, `no_latest_run` and `no_previous_run`. `comparable` is exactly
  # `layer_runtime_growth != null`.
  def serialized_layer_runtime_growth_window
    growth = layer_runtime_growth

    {
      basis: "previous_run_on_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # The declared-layer TIME movement — `null` in EVERY non-comparable state, never zeros. Per layer,
  # in `SpecObservation::DECLARED_LAYER_KEYS` order: the summed seconds then and now, how many
  # examples each was summed over, the recorded example counts, and `change` (anchor − baseline,
  # `null` unless BOTH sides timed that layer). Operands and difference only — no view strings.
  def serialized_layer_runtime_growth
    growth = layer_runtime_growth

    return nil unless growth&.comparable?

    {
      layers: growth.rows.transform_values do |row|
        { baseline_seconds: row.baseline_seconds, anchor_seconds: row.anchor_seconds,
          baseline_timed_count: row.baseline_timed_count, anchor_timed_count: row.anchor_timed_count,
          baseline_count: row.baseline_count, anchor_count: row.anchor_count, change: row.change }
      end
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of the
  # "Areas that grew or shrank" panel `repositories#show` renders from the same object, off the same
  # two runs, in the same order. It is the question the dashboard answers with no parameter at all
  # and this endpoint could not be asked: `directory_growth` beside it needs a `?branch=` and then
  # answers about the two ends of a thirty-run window, which is a different measurement.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryGrowth` is view-free, so the API and the panel
  # cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS. The window sibling can gate
  # its honesty figures KEY BY KEY, on `baseline_run`, because its object keeps them in four of its
  # eight states — the four its aggregate read reaches — and drops them in the other four; this
  # object keeps them in ONE state only, so there is no per-key line to draw and the whole block
  # goes. (Seven-of-eight is the count of the window sibling's ABSENCE states, not of the states
  # that retain totals; it is a different figure and does not belong to this argument.)
  # `SpecDirectoryGrowth.from_tuples` returns `new(state: :previous_unrecorded)` and friends WITHOUT
  # the counts it just read, so every aggregate falls back to its `0` default. Serving them raw
  # would print `anchor_recorded_count: 0` for a latest run that recorded four hundred rows — a
  # fabricated denominator sitting among the fields that exist to be trustworthy, which is the
  # failure the sibling's ⭐ gates exist to prevent, refused here by a different route. The
  # actionable half of those states is the `state` token, and it is served unconditionally one key
  # up.
  #
  # So this block is non-null exactly when `directory_run_growth_window.comparable` is true, and
  # every figure in it was counted off the rows the `rows` array lists.
  #
  # ROWS THROUGH `serialized_directory_growth_row`, SHARED VERBATIM WITH THE WINDOW BLOCK and not a
  # second copy of it. That method is written entirely against `SpecDirectoryGrowth::Row` — `change`,
  # `moved?`, `new_area?` and `removed_area?` are all defined on the parent Struct, and
  # `SpecDirectoryWindowGrowth::Row` inherits them — so the two growth blocks read alike row for row,
  # including the `previous_count`/`latest_count` → `baseline_count`/`anchor_count` translation and
  # the rule against serving the panel's `*_label`/`change_reading` strings.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it, exactly as the sibling does:
  # `directory_count` is counted BEFORE the `LIMIT` applies (a window function, so it runs first),
  # and `limit` is read off `SpecObservation::MOVED_DIRECTORIES_LIMIT` rather than restated —
  # this call site passes no `limit:`, so the constant IS the bound the query applied.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on, and deliberately not `TestRun#total_specs_count`, which is re-derived by SUM over shard
  # reports and can legitimately differ from the rows a run actually wrote.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the nine states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. The comparison itself is two run ids in an `IN` list — the same aggregate already
  # plan-certified in `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_run_growth
    growth = spec_directory_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's RUNTIME movement between two runs, its two operands, and the three different absences
  # that all render as an empty Change cell.
  #
  # A NEW METHOD AND NOT `serialized_directory_growth_row`, WHICH CANNOT BE REUSED HERE. That method
  # is written entirely against `SpecDirectoryGrowth::Row` — `previous_count`/`latest_count`,
  # `moved?`, `new_area?`, `removed_area?` — and `SpecDirectoryWindowGrowth::Row` INHERITS that
  # Struct, which is the whole reason those two blocks share it. `SpecDirectoryRuntimeGrowth::Row` is
  # an INDEPENDENT Struct with seconds operands and a predicate the count Struct does not have, so a
  # shared serializer would be a method branching on which Struct it was handed.
  #
  # `previous_seconds`/`latest_seconds` are the aggregate's own two sides and are the model's names;
  # they go out as `baseline_seconds`/`anchor_seconds`, this endpoint's wire convention for the two
  # ends of a comparison and the names `anchor_commit_sha`/`baseline_commit_sha` one key up give
  # them. The same translation `serialized_directory_growth_row` makes for the counts, made once here
  # rather than in every client's head.
  #
  # ⭐ THREE PREDICATES, BECAUSE THERE ARE THREE DIFFERENT ABSENCES AND THE MODEL KEEPS THEM APART.
  # `change` is `null` when an area is NEW, when it was REMOVED, and when both runs ran it and one of
  # them reported no timing for it — and those are three different things to go and fix. `comparable`
  # says only that there is nothing to subtract; `new_area`/`removed_area` say the area is on one side
  # only; `timing_gap` says both runs HAVE this area and the telemetry, not the code, is what is
  # missing. Collapsing them re-creates exactly the confusion `SpecDirectoryRuntimeGrowth::Row` spends
  # paragraphs refusing.
  #
  # `change`, `baseline_seconds` and `anchor_seconds` ARE LEGITIMATELY `null` and are served as the
  # nils they are — never coerced to `0`. `SUM` skips NULLs silently and `duration_seconds` is
  # nullable by design, so a zero here would be "this side was never timed" made byte-identical to
  # "this area took no time", which is the one reading the whole panel exists to refuse.
  #
  # NO VIEW STRINGS. `previous_label`, `latest_label`, `coverage_label`, `change_label` and
  # `change_reading` are typographic and screen-reader spellings of these same numbers — a U+2212 for
  # a negative, `"±0"`, `"not reported"`, `"New area"` — and a client served those would be splitting
  # strings and stripping glyphs to compare two rows. The rule `serialized_directory_growth_row`
  # states, held at the grain where the labels are richest.
  def serialized_directory_runtime_growth_row(row)
    {
      path: row.path,
      baseline_seconds: row.previous_seconds,
      anchor_seconds: row.latest_seconds,
      change: row.change,
      comparable: row.comparable?,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?,
      timing_gap: row.timing_gap?
    }
  end

  # The contract the RUN-OVER-RUN RUNTIME growth rows below are served under — and, when they are
  # `null`, the reason they are. Served UNCONDITIONALLY, on the key-always-present rule every window
  # block on this endpoint holds: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK, NOT A RUN WINDOW — the suffix this endpoint has now used four
  # times for "the facts that decide how the array beside it may be read". This comparison spans
  # exactly TWO runs and `basis` says so in a token.
  #
  # ⭐ TWELVE STATES, AND THE ENUMERATION IS THE POINT. `SpecDirectoryRuntimeGrowth` has TEN of its
  # own — three MORE than its count sibling, because this grain has a second kind of absence:
  #
  # * `no_latest_run` — CI has never reported. ADDED AT THIS CALL SITE; see the accessor.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch. ADDED HERE too, and
  #   it covers the same two shapes `branch` separates for the count sibling: a `null` branch is a
  #   latest run whose client sent none, a named branch is a genuine first run on it.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — the three pre-query
  #   states, decided from the two runs alone and short-circuiting the read.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — a side wrote no per-example
  #   ROWS at all (a client that posts only totals).
  # * `neither_timed`, `previous_untimed`, `latest_untimed` — THE GRAIN THE COUNT SIBLING HAS NO
  #   EQUIVALENT OF. A side recorded rows and none of them carried a duration. "The previous run
  #   recorded no per-example detail" and "the previous run reported no timings" are the same blank
  #   panel and two entirely different things to go and fix, which is why the model asks the RECORDED
  #   questions first and the TIMED ones only of a side that has rows.
  # * `comparable` — the rows block below is non-null.
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it is
  # exactly `directory_runtime_growth != null`, so there is one boolean here and not two.
  #
  # ⭐ `order` IS THE COUNT SIBLING'S STRING PLUS `_nulls_last`, AND THE DIFFERENCE IS NOT COSMETIC.
  # `SpecObservation.directory_runtime_growth_between` orders by `ABS(...) DESC NULLS LAST`, and the
  # count read has no such clause because a `COUNT` is never NULL. Here the ordering key IS nil for
  # every area a side did not time, and those rows therefore sort LAST rather than first — which is
  # the whole reason a listed row can be untimed at all (the movement ran out before the cap did).
  # Copying `abs_change_desc,path_asc` across would be a token a client could not reproduce this
  # order from, so the token states what the query actually asked.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE — `branch_scope` is the constant `single_branch`
  # because `Repository#previous_test_run_on_branch` scopes to the latest run's OWN branch and
  # refuses a blank one, so this is branch-correct by construction rather than by a parameter. Like
  # `latest_run` and the count pair, this block is NOT re-anchored by `?branch=`: `branch` names the
  # branch the comparison WAS MADE ON, read off the latest run and never off `requested_branch`. And
  # like both of them it IS re-anchored by `?commit_sha=`, the one parameter that moves the anchor:
  # `anchor_commit_sha` and `branch` become the NAMED run's and the baseline the run before THAT one
  # on ITS branch, off the same `latest_test_run` memo. That is what keeps the two growth windows
  # under one request from sitting on two different runs — neither chooses, both follow.
  #
  # `basis` is `previous_run_on_branch`, the count pair's token and for its reason: the baseline is
  # one specific run, named by `baseline_commit_sha`, so the comparison has no gap in it — an area
  # that gained a minute and gave it back cannot hide inside a two-run comparison.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS under the sibling's names, because
  # the ROWS below are served as `anchor_seconds`/`baseline_seconds` and a client must be able to
  # tell which sha each operand was summed on. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS
  # ONE, which is the direction every `change` is signed in. Both are nullable and independently so.
  def serialized_directory_runtime_growth_window
    growth = spec_directory_runtime_growth

    {
      order: "abs_change_desc_nulls_last,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # WHICH AREAS OF THE SUITE GOT SLOWER OR FASTER IN THE LATEST PUSH — the agent-readable half of the
  # panel `repositories#show` renders from the same object, off the same two runs, in the same order.
  #
  # ⭐ NOT A RESTATEMENT OF `directory_run_growth`, AND NEITHER IS DERIVABLE FROM THE OTHER. That
  # block ranks areas by how their example COUNT moved; this one ranks them by how their summed
  # example TIME moved. `SpecDirectoryRuntimeGrowth`'s class comment carries the argument in full:
  # an area where somebody made an existing spec slow adds ZERO examples, so its
  # `ABS(latest_count - previous_count)` is `0`, it sorts last on that block and falls off the cap —
  # it is not a row there missing a column, it is not on that list at all. The independence runs both
  # ways: splitting one slow spec into four fast ones is `+3` examples and LESS time.
  #
  # It is also the grain `history` stops one short of. `test_runs.duration_seconds` is one figure per
  # run, so an agent holding every other key here can be told the run got ninety seconds slower and
  # can never ask WHERE. The per-area grain exists only in `spec_observations`.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryRuntimeGrowth` is view-free, so the API and the
  # panel cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND THE COUNT SIBLING'S ARGUMENT FOR THAT DOES NOT
  # TRANSFER VERBATIM — so here is the one that does. There, `SpecDirectoryGrowth.from_tuples`
  # returns its row-decided states WITHOUT the counts it just read, so serving them raw would print
  # `anchor_recorded_count: 0` for a run that recorded four hundred rows. `SpecDirectoryRuntimeGrowth`
  # does the opposite deliberately: `from_tuples` passes `**totals` into EVERY state it constructs,
  # so in its six row-derived absence states the four denominators are real. Only the three gate
  # states, which never ran a query, carry the `0` defaults.
  #
  # It goes `null` anyway, for three reasons in order. (1) A key whose presence rule is "populated in
  # six of nine model states and zeroed in three" is a contract a client cannot hold in its head;
  # "non-null exactly when `directory_runtime_growth_window.comparable` is true" is one sentence and
  # is the rule the two shipped growth blocks already teach. (2) A per-key gate would not actually
  # eliminate the fabricated-denominator failure — the three gate states would still carry zeros —
  # it would only narrow it, at the cost of that rule. (3) The actionable half of every
  # non-comparable state is the `state` token, served unconditionally one key up.
  #
  # Serving the honest totals in the six row-derived states is a well-formed enhancement to the
  # window block and deliberately NOT smuggled in here.
  #
  # ⭐ ALL FOUR DENOMINATORS, NOT THE TWO THE COUNT SIBLING SERVES. This block has two grains of
  # absence and therefore two grains of denominator: how many rows each run RECORDED, and how many of
  # those carried a TIMING. The model's own rule — "1,204 examples reported a timing" is 1,204 of
  # something unstated — and the whole reading this block turns on is whether an area got faster or
  # merely went quiet. The count sibling has only the recorded pair because it has no timing grain.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it: `directory_count` is counted BEFORE
  # the `LIMIT` applies (a window function, so it runs first), and `limit` is read off
  # `SpecObservation::RETIMED_DIRECTORIES_LIMIT` rather than restated — this call site passes no
  # `limit:`, so the constant IS the bound the query applied. A DIFFERENT constant from the count
  # sibling's `MOVED_DIRECTORIES_LIMIT`, which happens to hold the same number today and is not the
  # same bound.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the twelve states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. `SpecObservation.directory_runtime_growth_between` is already plan-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_runtime_growth
    growth = spec_directory_runtime_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_runtime_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      baseline_timed_count: growth.previous_timed_count,
      anchor_timed_count: growth.latest_timed_count,
      limit: SpecObservation::RETIMED_DIRECTORIES_LIMIT
    }
  end

  # The contract the PER-FILE growth rows below are served under — and, when they are `null`, which
  # of the two reasons applies. Served UNCONDITIONALLY, on the key-always-present rule the two
  # blocks above it argue for: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens, and here it is absent on the commonest request of all — the one
  # that named no area.
  #
  # ⭐ `path` IS THE ASK RESTATED, AND IT IS THE DISCRIMINATOR. The rows block is `null` in two
  # different situations and a client must be able to tell them apart:
  #
  # * `path` is `null` — YOU DID NOT ASK. No `?spec_directory=` reached the server, or the shape it
  #   carried was not a string (`RequestedSpecDirectoryParam` treats a malformed shape as no ask at
  #   all, which is why this is never echoed from the raw parameter).
  # * `path` is set and `comparable` is `false` — you asked, and the comparison this drills out of
  #   refuses. `state` says which of the eight refusals.
  # * `path` is set and `comparable` is `true` — the rows block is populated.
  #
  # So the rows block is non-null exactly when `path` is non-null AND `comparable` is true. This is
  # the same separation `serialized_spec_directory_files` keeps between *"you did not ask"* and
  # *"the area you asked about has no rows"*, reached the other way round: that key is `null`
  # wholesale when unasked, and this one cannot be, because its `null` has a second cause to
  # explain.
  #
  # ⭐ `state` AND `comparable` ARE THE PARENT'S VERDICT, READ OFF THE PARENT — never re-derived and
  # never read off this drill-in's own object, which is not even constructed when nobody asked.
  # `SpecDirectoryFileGrowth` carries the parent's state verbatim and refuses to build anything the
  # moment the parent is not comparable, and its class comment gives the load-bearing reason: two of
  # the six model states (`previous_unrecorded`/`latest_unrecorded`) are facts about a RUN, and
  # everything this object reads is narrowed to one area. An area only the latest run recorded has
  # zero previous-side rows — `previous_unrecorded` spelled identically and meaning something else
  # entirely. So this block's `state` is `directory_run_growth_window.state`, always, by
  # construction: the drill-in is ABSENT whenever the block it drills out of cannot compare, and it
  # never offers a second opinion about two runs.
  #
  # The safe navigation is LOAD BEARING and not stylistic — `spec_directory_growth` is `nil` in the
  # two serializer-level states, and the same `latest_test_run.nil?` fallback the sibling window
  # block uses tells those two apart off the one memoized accessor.
  #
  # NO SECOND SPELLING OF THE OPERANDS. `branch`, `anchor_commit_sha` and `baseline_commit_sha` are
  # served once, on `directory_run_growth_window`, and are identical here by construction — this is
  # the SAME comparison between the SAME two runs, narrowed to one area. Repeating them would be two
  # blocks under one request naming one run two ways, which is the hazard the shared
  # anchor/baseline vocabulary exists to prevent.
  #
  # `limit` LIVES HERE rather than on the rows block, unlike its sibling's: it is a fact about how
  # the array beside it may be read, and a client that asked for an area and got `null` should still
  # be able to learn what a populated answer would have been capped at. Read off
  # `SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT` rather than restated — it is its own
  # constant, neither the areas' ten nor the durations drill-down's.
  def serialized_directory_run_file_growth_window
    growth = spec_directory_growth

    {
      path: requested_spec_directory,
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      limit: SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT
    }
  end

  # WHICH FILES OF THE ASKED-FOR AREA GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of
  # the "Files that grew or shrank in this directory" panel `repositories#show` renders from the
  # same object, off the same two runs, in the same order.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryFileGrowth` is view-free, so the API and the
  # panel cannot name different files or different operands for the same area of the same
  # repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS — the rule its parent block
  # pins by its own example. `SpecDirectoryFileGrowth.for` returns `new(path:, state:)` for a parent
  # that cannot compare, WITHOUT any of the counts, so every aggregate falls back to its `0`
  # default: serving them raw would print `anchor_recorded_count: 0` for a latest run that recorded
  # four hundred rows in that very area — a fabricated denominator sitting among the fields that
  # exist to be trustworthy. The actionable half of those states is the `state` token, and it is
  # served unconditionally one key up.
  #
  # `file_count` is the AREA's — every file EITHER run recorded a row for, counted BEFORE the
  # `LIMIT` by a window function and therefore never `rows.size`, which is the truncated figure. So
  # `truncated` is disclosed against a population rather than against the list's own length, and the
  # caption a client builds from these figures cannot describe a different row set from the rows it
  # was handed.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are THIS AREA'S rows, deliberately not the
  # identically-named whole-run figures on the parent block: every figure here comes back from the
  # one grouped aggregate that returned the rows, narrowed by the same area predicate. A client
  # mixing the two would divide an area's population by the suite's.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all unless a caller asked for an area AND
  # the parent comparison is comparable — the gate is a read of an object already in memory, so it
  # short-circuits before any query in all eight refusing states even with `?spec_directory=` set.
  # The read is bounded by the size of the AREA rather than of the suite and needs no index of its
  # own: see `SpecObservation.file_growth_between`.
  def serialized_directory_run_file_growth
    growth = spec_directory_file_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_file_growth_row(row) },
      file_count: growth.file_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count
    }
  end

  # One spec file's movement between two runs, and BOTH OPERANDS it was taken across — never one of
  # the labels the row builds for the panel. `SpecDirectoryFileGrowth::Row` carries `change_label`,
  # `change_reading`, `previous_count_label` and `latest_count_label`, which are typographic and
  # screen-reader spellings of these same numbers; `serialized_directory_growth_row` states in full
  # why a client served those would be splitting strings and stripping glyphs.
  #
  # `previous_count`/`latest_count` go out as `baseline_count`/`anchor_count`, the vocabulary both
  # growth pairs on this endpoint already use, so the two blocks under one request cannot name the
  # same run two ways. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE, which is the
  # direction every `change` is signed in.
  #
  # NOT `serialized_directory_growth_row` REUSED, though the arithmetic and the two translated names
  # are identical. `new_file`/`removed_file` are not `new_area`/`removed_area` — they are claims
  # about a different grain, and a shared mapper would have to take its own nouns as arguments,
  # which is a parameterised key name standing where two plain ones were. That is the disposition
  # `SpecDirectoryFileGrowth::Row` itself takes on the same question one layer down.
  #
  # `new_file` and `removed_file` are NOT derivable from `change` alone: a file at zero on one side
  # is that file's real absence, and `+47` against an absent side reads identically to an existing
  # file that gained forty-seven examples. At THIS grain that distinction is the whole subject — a
  # file at "new" beside one at "removed" is the shape of a rename, and two files at `+47` and `−47`
  # is not. The block holding these rows has already established, through the parent's gate, that
  # BOTH runs recorded rows, which is what makes a zero on one side that file's own absence rather
  # than a run that recorded nothing anywhere.
  def serialized_directory_file_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_file: row.new_file?,
      removed_file: row.removed_file?
    }
  end

  # The contract the PER-FILE RUNTIME growth rows below are served under — and, when they are
  # `null`, which of the two reasons applies. Served UNCONDITIONALLY, on the key-always-present rule
  # every window block on this endpoint holds: a block that explains a `null` is worthless if it is
  # itself absent whenever the `null` happens, and here it is absent on the commonest request of all
  # — the one that named no area.
  #
  # ⭐ `path` IS THE ASK RESTATED, AND IT IS THE DISCRIMINATOR — the count drill-in's rule verbatim,
  # because the two blocks are `null` under exactly the same two situations and a client must be able
  # to tell them apart:
  #
  # * `path` is `null` — YOU DID NOT ASK. No `?spec_directory=` reached the server, or the shape it
  #   carried was not a string (`RequestedSpecDirectoryParam` treats a malformed shape as no ask at
  #   all, which is why this is never echoed from the raw parameter).
  # * `path` is set and `comparable` is `false` — you asked, and the comparison this drills out of
  #   refuses. `state` says which of the ELEVEN refusals.
  # * `path` is set and `comparable` is `true` — the rows block is populated.
  #
  # ⭐ `state` AND `comparable` ARE THE PARENT'S VERDICT, READ OFF `directory_runtime_growth` — never
  # re-derived, and never read off this drill-in's own object, which is not even constructed when
  # nobody asked. `SpecDirectoryFileRuntimeGrowth` carries the parent's state verbatim and refuses to
  # build anything the moment the parent is not comparable.
  #
  # The reason is the count drill-in's, WIDENED by this quantity and the class comment states it in
  # full: SIX of `SpecDirectoryRuntimeGrowth`'s nine refusals — the two RECORDED pairs and all three
  # TIMED ones — are computed from window totals across EVERY area, so they are facts about a RUN,
  # and everything this object reads is narrowed to one area. An area only the latest run timed has
  # zero previous-side timed rows: that is `previous_untimed` spelled identically and meaning
  # something else entirely — "the earlier run reported no timings ANYWHERE" against "this area was
  # not timed" — and a drill-in that re-derived it would print that sentence directly beneath
  # `directory_runtime_growth`, which is at that moment listing that same run's per-area seconds. The
  # count drill-in has TWO such states; this has SIX, so the inheritance is more load bearing here
  # and not less.
  #
  # ⭐ AND SPECIFICALLY NOT A `timed_shard_count` GATE. The Overview runtime delta takes one and this
  # is the finest runtime grain on the endpoint, so it is the block that looks likeliest to owe it.
  # `SpecDirectoryRuntimeGrowth` DECIDED that for this family and the reasoning is grain-independent:
  # that guard is the denominator of a MAX over the shards that reported, and these reads SUM
  # per-example rows — machine time, not wall clock — so there is no MAX to fold. Narrowing a sum to
  # one area's files does not turn it into a maximum. Where a shard genuinely went missing,
  # the parent's `assembled_like?` catches it, and the parent has already asked.
  #
  # The safe navigation is LOAD BEARING and not stylistic — `spec_directory_runtime_growth` is `nil`
  # in the two serializer-level states, and the same `latest_test_run.nil?` fallback every window
  # block here uses tells those two apart off the one memoized accessor.
  #
  # NO SECOND SPELLING OF THE OPERANDS. `branch`, `anchor_commit_sha` and `baseline_commit_sha` are
  # served once, on `directory_runtime_growth_window`, and are identical here by construction — this
  # is the SAME comparison between the SAME two runs, narrowed to one area. Repeating them would be
  # two blocks under one request naming one run two ways.
  #
  # `order` CARRIES `nulls_last` where the count drill-in's does not, and the difference is real
  # rather than cosmetic: `SUM(duration_seconds)` over a file no side timed is SQL NULL, so the
  # ordering key is NULL and those rows are pushed to the TAIL rather than to the head. A client
  # reproducing this ordering without that clause would sort the files nobody measured to the top of
  # a list about slowdowns. The same token `directory_runtime_growth_window` serves, for the same
  # reason one grain up.
  #
  # `limit` LIVES HERE rather than on the rows block, following the count drill-in at this GRAIN
  # rather than the runtime block at this QUANTITY — and the grain is the one that decides it. A
  # client that asked for an area and got `null` should still be able to learn what a populated
  # answer would have been capped at, which is a question only the drill-ins can be asked. Read off
  # `SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT` rather than restated — it is its own
  # constant, and it happens to hold the same number as the count drill-in's for an unrelated reason:
  # the two rank the SAME files by INDEPENDENT quantities, which is precisely why they are two
  # constants.
  def serialized_directory_runtime_file_growth_window
    growth = spec_directory_runtime_growth

    {
      path: requested_spec_directory,
      order: "abs_change_desc_nulls_last,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      limit: SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT
    }
  end

  # WHICH FILES OF THE ASKED-FOR AREA GOT SLOWER OR FASTER IN THE LATEST PUSH — the cell that
  # completes the {area, file} × {count, runtime} square, and the one an agent holding the other
  # three could not compute.
  #
  # ⭐ NOT A RESTATEMENT OF `directory_run_file_growth`, AND NEITHER IS DERIVABLE FROM THE OTHER.
  # That block ranks this area's files by how their example COUNT moved; this one ranks them by how
  # their summed example TIME moved. A file where somebody made an existing example slow adds ZERO
  # examples, so its `ABS(latest_count - previous_count)` is `0`, it sorts last there and falls off
  # the cap — it is not a row on that block missing a column, it is not on that list at all. The
  # independence runs both ways: splitting one slow spec into four fast ones is `+3` examples and
  # LESS time.
  #
  # THE SAME OBJECT ANY PANEL WOULD READ, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files`. `SpecDirectoryFileRuntimeGrowth` is view-free, so a
  # later `repositories#show` panel over the same cell cannot name different files or different
  # operands for the same area of the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS — the rule its two neighbours
  # pin by their own examples. `SpecDirectoryFileRuntimeGrowth.for` returns `new(path:, state:)` for
  # a parent that cannot compare, WITHOUT any of the counts, so every aggregate would fall back to
  # its `0` default: serving them raw would print `anchor_timed_count: 0` for a latest run that timed
  # four hundred rows in that very area — a fabricated denominator sitting among the fields that
  # exist to be trustworthy. The actionable half of those states is the `state` token, served
  # unconditionally one key up.
  #
  # ⭐ ALL FOUR DENOMINATORS, NOT THE TWO THE COUNT DRILL-IN SERVES, and here they are not optional
  # decoration — they are what keeps the block honest. This grain has TWO absences: how many rows
  # each run RECORDED in this area, and how many of those carried a TIMING. `SUM` skips NULLs
  # silently, so a file half of whose examples were untimed reports a total covering half of it, and
  # the whole reading this block turns on is whether a file got faster or merely went quiet. Without
  # the timed pair a client cannot tell those apart, and `baseline_seconds` would be a number over an
  # unstated population. The count drill-in has only the recorded pair because it has no timing grain
  # to state anything against.
  #
  # `file_count` is the AREA's — every file EITHER run recorded a row for, counted BEFORE the `LIMIT`
  # by a window function and therefore never `rows.size`, which is the truncated figure. So
  # `truncated` is disclosed against a population rather than against the list's own length.
  #
  # All four denominators are THIS AREA'S, deliberately not the identically-named whole-run figures
  # on `directory_runtime_growth`: every figure here comes back from the one grouped aggregate that
  # returned the rows, narrowed by the same area predicate. A client mixing the two would divide an
  # area's population by the suite's.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all unless a caller asked for an area AND
  # the parent comparison is comparable — the gate is a read of an object already in memory, so it
  # short-circuits before any query in all eleven refusing states even with `?spec_directory=` set.
  # The read is bounded by the size of the AREA rather than of the suite and needs no index of its
  # own: see `SpecObservation.file_runtime_growth_between`.
  def serialized_directory_runtime_file_growth
    growth = spec_directory_file_runtime_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_file_runtime_growth_row(row) },
      file_count: growth.file_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      baseline_timed_count: growth.previous_timed_count,
      anchor_timed_count: growth.latest_timed_count
    }
  end

  # One spec file's RUNTIME movement between two runs, its two operands, and the three different
  # absences that all render as an empty Change cell.
  #
  # A NEW METHOD AND NEITHER NEIGHBOUR REUSED, for the reason `serialized_directory_runtime_growth_row`
  # gives against ITS count sibling and which holds twice here. `serialized_directory_file_growth_row`
  # is written entirely against `SpecDirectoryFileGrowth::Row` — `previous_count`/`latest_count`,
  # and no `comparable?` or `timing_gap?` at all — and
  # `serialized_directory_runtime_growth_row` is written against an independent Struct whose nouns
  # are AREAS. `SpecDirectoryFileRuntimeGrowth::Row` is a third independent Struct: seconds operands
  # like the second, file nouns like the first. Sharing either serializer would be a method branching
  # on which Struct it was handed, or a parameterised key name standing where two plain ones were.
  #
  # `previous_seconds`/`latest_seconds` are the aggregate's own two sides and are the model's names;
  # they go out as `baseline_seconds`/`anchor_seconds`, this endpoint's wire convention for the two
  # ends of a comparison and the names `anchor_commit_sha`/`baseline_commit_sha` give them on
  # `directory_runtime_growth_window`. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE,
  # which is the direction every `change` is signed in.
  #
  # ⭐ THREE PREDICATES, BECAUSE THERE ARE THREE DIFFERENT ABSENCES AND THE MODEL KEEPS THEM APART.
  # `change` is `null` when a file is NEW, when it was REMOVED, and when both runs ran it and one of
  # them reported no timing for it — three different things to go and fix. `comparable` says only
  # that there is nothing to subtract; `new_file`/`removed_file` say the file is on one side only;
  # `timing_gap` says both runs HAVE this file and the telemetry, not the code, is what is missing.
  #
  # `new_file` and `removed_file` are NOT derivable from `change` alone — the count drill-in's rule,
  # and NULL-valued seconds make it sharper rather than softer: at this grain a file at "new" beside
  # one at "removed" is the shape of a rename, and two files at `+47s` and `−47s` is not. The block
  # holding these rows has already established, through the parent's gate, that BOTH runs recorded
  # rows, which is what makes a zero on one side that file's own absence rather than a run that
  # recorded nothing anywhere.
  #
  # `change`, `baseline_seconds` and `anchor_seconds` ARE LEGITIMATELY `null` and are served as the
  # nils they are — never coerced to `0`. `SUM` skips NULLs silently and `duration_seconds` is
  # nullable by design, so a zero here would be "this side was never timed" made byte-identical to
  # "this file took no time", which is the one reading the whole block exists to refuse.
  #
  # NO VIEW STRINGS, and at this cell there are none to omit — `SpecDirectoryFileRuntimeGrowth`
  # carries no labels at all, unlike the three siblings above whose `previous_label`, `latest_label`,
  # `coverage_label`, `change_label` and `change_reading` this method would have had to step around.
  # Those are typographic and screen-reader spellings of these same numbers — a U+2212 for a
  # negative, `"±0"`, `"not reported"`, `"New file"` — and a client served those would be splitting
  # strings and stripping glyphs to compare two rows. They land on that model WITH the
  # `repositories#show` panel that renders them, so the rule this comment states stays true by
  # construction here rather than by restraint: there is nothing on the object this method could
  # wrongly serve.
  def serialized_directory_file_runtime_growth_row(row)
    {
      path: row.path,
      baseline_seconds: row.previous_seconds,
      anchor_seconds: row.latest_seconds,
      change: row.change,
      comparable: row.comparable?,
      moved: row.moved?,
      new_file: row.new_file?,
      removed_file: row.removed_file?,
      timing_gap: row.timing_gap?
    }
  end

  private

  attr_reader :overview

  delegate :latest_test_run, :previous_test_run, :requested_spec_directory, :requested_branch,
           :history_runs, to: :overview, private: true

  # The run-over-run presenter, or `nil` when there are not two runs to hand it — memoized across
  # the nil with `defined?` for the reason `unstable_tests` states, and under the same double read
  # (`show` asks the window block for `state` and then this block for the rows).
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL. `SpecDirectoryGrowth.for`
  # dereferences `previous_test_run` on its SECOND LINE (`unless previous_test_run.suite_size_measured?`)
  # and has no nil state of its own — there are six non-comparable states and "there is no previous
  # run" is none of them. `previous_test_run` above is nil for three ordinary live shapes: a
  # repository CI has never reported on, a latest run whose client sent no branch, and the first run
  # on a branch. Handed straight in, every one of those is a `NoMethodError` on a plain
  # `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, which is the same shape `RepositoriesController#show`
  # already uses (`if @latest_test_run && @previous_test_run`). Teaching `SpecDirectoryGrowth.for` to
  # accept a nil would give the object a seventh absence state that the dashboard — its other caller,
  # which guards for itself — can never reach, and would move a decision the two call sites make
  # identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  def spec_directory_growth
    return @spec_directory_growth if defined?(@spec_directory_growth)

    @spec_directory_growth =
      latest_test_run && previous_test_run && SpecDirectoryGrowth.for(latest_test_run, previous_test_run)
  end

  # The run-over-run declared-layer-mix presenter, or `nil` when there are not two runs to hand it.
  # Guarded here, not by widening the model, on `spec_directory_growth`'s argument (see above): the
  # presenter dereferences its second argument immediately and has no "no previous run" state.
  # Rides the memoized `previous_test_run` — no second previous-run lookup.
  def layer_run_growth
    return @layer_run_growth if defined?(@layer_run_growth)

    @layer_run_growth =
      latest_test_run && previous_test_run && LayerRunGrowth.for(latest_test_run, previous_test_run)
  end

  # The run-over-run declared-layer TIME presenter, guarded and memoized exactly as
  # {#layer_run_growth} is (`defined?` across the nil). Shared with the dashboard through
  # {#layer_runtime_growth} so there is one object and no second previous-run lookup.
  def layer_runtime_growth
    return @layer_runtime_growth if defined?(@layer_runtime_growth)

    @layer_runtime_growth =
      latest_test_run && previous_test_run && LayerRuntimeGrowth.for(latest_test_run, previous_test_run)
  end

  # The run-over-run RUNTIME presenter, or `nil` when there are not two runs to hand it — memoized
  # across the nil with `defined?` rather than `||=`, on this file's idiom for every nullable
  # accessor and under the same double read its count sibling has: `show` asks the window block for
  # `state` and then this block for the rows, so a `||=` would re-issue the previous-run lookup on
  # every repository that has none, which is the case this most needs to be cheap in.
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL, exactly as one method up.
  # `SpecDirectoryRuntimeGrowth.for` dereferences `previous_test_run` on its SECOND LINE
  # (`unless previous_test_run.suite_size_measured?`) and has no nil state of its own — there are
  # nine non-comparable states and "there is no previous run" is none of them. `previous_test_run` is
  # nil for three ordinary live shapes: a repository CI has never reported on, a latest run whose
  # client sent no branch, and the first run on a branch. Handed straight in, every one of those is a
  # `NoMethodError` on a plain unparameterised `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL — the same shape `RepositoriesController#show` already
  # uses (`if @latest_test_run && @previous_test_run`), and the reason `spec_directory_growth` states
  # for its own guard: teaching `.for` to accept a nil would give the object a further absence
  # state that the dashboard — its other caller, which guards for itself — can never reach, and would
  # move a decision the two call sites make identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  #
  # A SECOND OBJECT OVER THE SAME TWO RUNS, and that is one more read rather than a doubling: this
  # asks a question `SpecDirectoryGrowth` structurally cannot answer (see
  # `serialized_directory_runtime_growth`), and its own gate short-circuits before any query in the
  # three states decidable from the two runs alone.
  def spec_directory_runtime_growth
    return @spec_directory_runtime_growth if defined?(@spec_directory_runtime_growth)

    @spec_directory_runtime_growth =
      latest_test_run && previous_test_run &&
      SpecDirectoryRuntimeGrowth.for(latest_test_run, previous_test_run)
  end

  # The per-file drill-in for the ONE area a caller asked about, or `nil` when nobody asked or there
  # was no comparison to narrow — memoized across the nil with `defined?` rather than `||=`, on the
  # idiom every nullable accessor in this file uses. Unlike `spec_directory_growth` above,
  # `spec_directory_window_growth` below, and `unstable_tests` further up, this accessor is read
  # ONCE: the contract block reads the PARENT, deliberately, so the verdict is never taken off this
  # object — which is not even constructed when nobody asked. The memoization is this file's idiom
  # held, not a second read paid for; the two guards below are what actually keep the key cheap.
  #
  # ⭐ TWO GUARDS, AND THEY REFUSE DIFFERENT THINGS. `requested_spec_directory` is the ASK — decided
  # from the params before any query, so a client that never sends the parameter pays nothing at all
  # for this key's existence. `spec_directory_growth` is the parent COMPARISON, and it is guarded
  # here for a reason the HTML call site is structurally immune to: `repositories_controller#show`
  # only ever reaches `SpecDirectoryFileGrowth.for` inside `if @latest_test_run && @previous_test_run`,
  # where the growth object has already been built. This endpoint serves the key on every request,
  # and `spec_directory_growth` is `nil` in both serializer-level states — a repository CI has never
  # reported on, and a latest run with no earlier run on its branch. `.for` dereferences its
  # `growth:` argument on its first line (`unless growth.comparable?`), so handing it that `nil` is
  # a `NoMethodError` on a plain `GET /api/v1/repository?spec_directory=spec/models`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, for the reason `spec_directory_growth` states about
  # its own guard one method up: teaching `.for` to accept a nil growth would give it an absence
  # state the dashboard — its other caller, which guards for itself — can never reach.
  #
  # ⭐ AND ONLY THOSE TWO. Comparability is NOT re-asked here: `.for` takes the parent object and
  # refuses on its own first line, reading memory rather than the database, so the six model-level
  # refusals cost this endpoint nothing while still producing an object that carries the parent's
  # state verbatim. Adding a `&.comparable?` to the condition above would be a fourth spelling of
  # predicates the parent has already asked on these same two runs — see `SpecDirectoryFileGrowth`,
  # which prices exactly that and explains why two of the six states are not re-derivable at this
  # grain in any case.
  def spec_directory_file_growth
    return @spec_directory_file_growth if defined?(@spec_directory_file_growth)

    @spec_directory_file_growth =
      if requested_spec_directory && spec_directory_growth
        SpecDirectoryFileGrowth.for(latest_test_run, previous_test_run, requested_spec_directory,
                                    growth: spec_directory_growth)
      end
  end

  # The per-file RUNTIME drill-in for the ONE area a caller asked about, or `nil` when nobody asked
  # or there was no comparison to narrow — memoized across the nil with `defined?` rather than `||=`,
  # on the idiom every nullable accessor in this file uses. Like its count sibling one method up this
  # accessor is read ONCE, because the contract block reads the PARENT deliberately: the memoization
  # is this file's idiom held, not a second read paid for, and the two guards below are what actually
  # keep the key cheap.
  #
  # ⭐ TWO GUARDS, AND THEY REFUSE DIFFERENT THINGS — the count drill-in's pair, against the RUNTIME
  # parent. `requested_spec_directory` is the ASK, decided from the params before any query, so a
  # client that never sends the parameter pays nothing at all for this key's existence.
  # `spec_directory_runtime_growth` is the parent COMPARISON, and it is `nil` in both
  # serializer-level states — a repository CI has never reported on, and a latest run with no earlier
  # run on its branch. `.for` dereferences its `growth:` argument on its first line
  # (`unless growth.comparable?`), so handing it that `nil` is a `NoMethodError` on a plain
  # `GET /api/v1/repository?spec_directory=spec/models`.
  #
  # ⭐ THE PARENT IS `spec_directory_runtime_growth` AND NEVER `spec_directory_growth`, which is the
  # one substitution that would compile, pass a careless reading, and be wrong in a way no type
  # catches. The two objects answer about the same two runs and both expose `state`/`comparable?`, so
  # the count parent would satisfy every call this method makes — and it would gate a RUNTIME
  # comparison on whether the two runs' example COUNTS were comparable. Those verdicts genuinely
  # differ: `neither_timed`, `previous_untimed` and `latest_untimed` exist only on the runtime object,
  # so a run that recorded four hundred rows and timed none of them is comparable to the count parent
  # and refused by this one. Gated on the wrong parent, this block would serve a table of nulls under
  # `comparable: true`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, for the reason `spec_directory_growth` states about
  # its own guard: teaching `.for` to accept a nil growth would give it an absence state a
  # self-guarding caller can never reach.
  #
  # ⭐ AND ONLY THOSE TWO. Comparability is NOT re-asked here: `.for` takes the parent object and
  # refuses on its own first line, reading memory rather than the database, so the NINE model-level
  # refusals cost this endpoint nothing while still producing an object that carries the parent's
  # state verbatim. Adding a `&.comparable?` to the condition above would be a further spelling of
  # predicates the parent has already asked on these same two runs — see
  # `SpecDirectoryFileRuntimeGrowth`, which prices exactly that and explains why SIX of the nine
  # states are not re-derivable at this grain in any case.
  def spec_directory_file_runtime_growth
    return @spec_directory_file_runtime_growth if defined?(@spec_directory_file_runtime_growth)

    @spec_directory_file_runtime_growth =
      if requested_spec_directory && spec_directory_runtime_growth
        SpecDirectoryFileRuntimeGrowth.for(latest_test_run, previous_test_run, requested_spec_directory,
                                           growth: spec_directory_runtime_growth)
      end
  end

  # The presenter, or `nil` when no comparison was allowed — memoized across the nil with `defined?`
  # rather than `||=`, for the reason `unstable_tests` states above and under the same double read
  # (`show` asks for the window block's `grouped` and then for the rows).
  #
  # ⭐ THIS SITE ASKS FOR THE WINDOW OLDEST FIRST, AND THAT IS ITS WHOLE SUBTLETY.
  # `SpecDirectoryWindowGrowth.for` takes `runs.last` as its ANCHOR and walks from index 0 for the
  # BASELINE — both ends load-bearing — so it asks `history_runs.oldest_first` by name. The
  # orientation was decided once, at the load (`recent_test_runs` orders `(created_at, id) DESC` —
  # NEWEST first — and the window carries that fact), so there is no `.reverse` here to drop; what
  # this site can still get wrong is ask for the WRONG END, and the failure that buys is worth
  # pricing: handed the other way the presenter does not raise — it anchors on the OLDEST run,
  # baselines against a NEWER one, and every `change` comes back SIGN-FLIPPED — a suite that grew
  # reports its areas shrinking, under a block that looks perfectly well-formed. The human panel
  # avoids this by construction because `Repository#suite_size_trajectory` ends `.to_a.reverse`;
  # this site says which end it wants out loud instead.
  #
  # The adjacent precedent is what made it easy to walk into and is NOT a licence: `UnstableTests.for`
  # is order-indifferent — it reads `runs.map(&:id)` and groups — so `unstable_tests` above hands
  # the window straight in and is right to. This one is not order-indifferent, and the two lines
  # are otherwise identical.
  #
  # The no-mutation rule is `RunWindow`'s to enforce, guaranteed by the object rather than
  # restated by its readers — the reasoning lives in the `== Non-mutating, by construction`
  # header of `app/models/run_window.rb`.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart — see `serialized_directory_growth_window` for why an unfiltered
  # window is refused rather than answered.
  def spec_directory_window_growth
    return @spec_directory_window_growth if defined?(@spec_directory_window_growth)

    @spec_directory_window_growth =
      requested_branch && SpecDirectoryWindowGrowth.for(history_runs.oldest_first, branch: requested_branch)
  end
end
