# frozen_string_literal: true

# THE BRANCH-WINDOW RANKING FAMILY OF `RepositoryOverview`, MOVED OUT WHOLE — the eight
# `serialized_*` methods that turn the flakiness presenters (`UnstableTests`, `UnstableTestRuns`)
# and the duration presenter (`SlowestTests`) into the JSON the overview's `body` serves, and the
# two memoized branch gates (`unstable_tests`, `slowest_tests`) they read. It follows the
# `RepositoryGrowthSerializer` precedent: a collaborator the overview owns one memoized instance of
# (`RepositoryOverview#window_rankings`), reaching back into it only for the repository, the window
# and the asks.
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/repository_overview.rb`; nothing about the emitted JSON, its key order, its state
# tokens or its query count changed. The comments still say "above", "below" and "this file", and
# those coordinates are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position word
# as pointing into the overview, not into this class.
#
# ONE INSTANCE PER OVERVIEW IS LOAD-BEARING. The two gates memoize in instance variables and `show`
# reads each of them twice (the window block's `grouped`, then the rows), so a second serializer
# would build the presenter again and double the reads the query-cost examples count. The overview
# memoizes it; do not build one per call.
#
# What it reads back from the overview is exactly four methods, delegated privately below:
# `repository`, `history_runs`, `requested_branch` and `requested_unstable_test`. It holds no
# `params` of its own and issues no SQL outside the presenters.
class RepositoryWindowRankingSerializer
  def initialize(overview:)
    @overview = overview
  end

  # The contract the flakiness rows below are served under — and, when they are `null`, the reason
  # they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` argues for
  # itself above: a client tests one thing rather than distinguishing an absent key from a null one,
  # and the block that explains a `null` is worthless if it is itself absent whenever the `null`
  # happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists because of the branch decision below. Outcomes
  # compared across branches are outcomes of different code — `UnstableTests` states that rule for
  # itself — and unfiltered, `history_runs` is the INTERLEAVED all-branch window
  # `serialized_history_window` spends a paragraph warning about, on which consecutive rows are
  # routinely two different branches. Grouping outcomes over it would manufacture a flip out of two
  # branches: the same description failing on `feature/x` and passing on `main` is two pieces of
  # code, and calling it flaky is a false positive the object exists to avoid. So unfiltered,
  # `UnstableTests.for` IS NOT CALLED AT ALL — no rows, and no reads to produce them — and this
  # boolean is what says so.
  #
  # It is read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ?
  # true : false`. A second copy of the gate is a second thing to keep true, and the one that
  # decides what was read is the one worth serving. So `grouped` is exactly `unstable_tests !=
  # null`, in every response, and a client can test either.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED". It says the window was eligible to be grouped
  # and was handed to the presenter — which is the branch decision and nothing more. What came of
  # it is the block's own business and is stated there: an unknown `?branch=` selects zero runs and
  # groups over an empty set, and a branch whose client never reported outcomes groups over a
  # populated one and still cannot compare. `run_count`, `recorded` and `comparable` are what
  # separate those, and they are in the block precisely because they are answers rather than
  # eligibility.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token, and `branch` is
  # always served (`null` when the window was not narrowed) — `serialized_history_window` makes
  # both arguments in full and they are not repeated here. They carry the same values that block
  # carries in the same response, because both describe the SAME window: the rows below are grouped
  # over `history_runs`, which is what `history` is serialized from.
  #
  # `null` ROWS AND NEVER AN EMPTY LIST. `unstable_tests: []` would read as "nothing is flaky" when
  # it means "we refused to compare" — Vacuous Green exactly, in the shape this project keeps
  # finding it: a surface reporting a clean result for work it did not do. The `null` cannot be
  # misread, and this block says which of the two states produced it.
  #
  # `order` NAMES ALL THREE KEYS, and `tie_break_served` is `true` here — one of the blocks on
  # this endpoint where it is, as is `RepositoryGrowthSerializer#serialized_directory_growth_window`.
  # `UnstableTests#initialize` sorts by `(-failed_run_count, -run_count,
  # spec_identity_id)` and every one of those three is served on the row below, so unlike `history` and
  # `branches` — whose tie-breaks are an ingest sequence and a last-run timestamp that no row
  # carries — a client CAN reproduce this order from what it holds. Stated rather than assumed,
  # because the honest answer differs per block and a client that had to guess would re-sort one of
  # the two lists that must not be re-sorted.
  def serialized_unstable_tests_window
    {
      order: "failed_run_count_desc,run_count_desc,spec_identity_id_asc",
      tie_break_served: true,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !unstable_tests.nil?
    }
  end

  # WHICH TESTS ARE UNSTABLE ACROSS RUNS — the agent-readable half of the "Tests whose outcome
  # changed" panel `repositories#show` has rendered since SPGD-282, and the roadmap's fourth axis
  # ("where it is flaky"), which was the last of the four this endpoint had never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`
  # rather than inside that block. `slowest_examples` reaches the per-example grain of ONE run;
  # this is the first key on this endpoint that matches a test to ITSELF across runs, and no
  # arrangement of single-run facts answers it. An agent holding thirty responses could subtract
  # them — which is the polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files`. `UnstableTests` is view-free, so the API and the
  # panel name the same tests, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query. `history_runs` is
  # materialized once and `show` already reads it twice, and `UnstableTests.for`'s own signature
  # documents the window as *"ALREADY LOADED … handed in rather than re-queried"*, precisely so two
  # surfaces cannot come to be drawn on two windows that agree today. The object is order- and
  # anchor-indifferent: it reads `runs.map(&:id)` and `runs.size` and nothing else.
  #
  # `null` — THE KEY STILL PRESENT — under an unfiltered window, and the argument for that is on
  # `serialized_unstable_tests_window` above where the boolean that explains it lives.
  #
  # AN EMPTY `rows` IS A REAL ANSWER HERE and is not the same state. Under a branch-scoped window
  # the object IS constructed, and `rows: []` beside `comparable: true` means "we compared and
  # nothing flipped". Beside `comparable: false` it means "nobody told us how anything ended". The
  # two must never serialize identically, which is what the coverage keys below are for.
  #
  # STRUCTURED COUNTS AND BOOLEANS, NOT PROSE — this endpoint's standing rule, and this is the
  # block where it costs the most. `RepositoriesHelper` words this same coverage in TWELVE
  # `unstable_tests_*` helpers ("3 of the last 30 runs on main reported outcomes", "2 of 5"), and a
  # machine-readable client cannot act on a sentence without parsing it. So every figure those
  # sentences are built from goes out as an integer or a boolean and the client words it — or does
  # not word it at all and just divides.
  #
  # `comparable` IS THE VACUOUS GREEN GATE AND IS SERVED AS A FLAG, never as an empty list.
  # `UnstableTests#comparable?` is explicit about why: `outcome` is nullable and nothing validates
  # it, so a window whose client sends no outcomes stores a nil on every row of every run, which
  # yields no failures, therefore no candidates, therefore an empty list — *"the zero is real; what
  # it counts is silence"*. An empty list without this flag is "nobody told us" wearing the
  # spelling of "everything is stable".
  #
  # `recorded` is the coarser question one rung under it — whether the window has ANY per-example
  # grain at all — and separates a repository whose CI has never sent per-example detail from one
  # that sends it without outcomes. Both are read off the object's OWN predicates, called rather
  # than re-spelled here, on the rule `serialized_spec_files`' `#recorded?` gate states: a
  # controller-side copy of a predicate is free to drift the day the presenter's changes.
  #
  # `truncated` / `unexamined_count` DISCLOSE THE CANDIDATE CAP. The candidate step stops at
  # `SpecObservation::UNSTABLE_CANDIDATE_LIMIT` — a catastrophe valve for a window in which the
  # whole suite went red — and a capped list that does not say it stopped is read as the whole
  # story. The two OPERANDS (`candidate_count`, `examined_count`) go out beside the boolean, so a
  # client can check the comparison rather than take it; `limit` is read off `SpecObservation`'s own
  # constant rather than restated here, on the precedent `serialized_spec_files` sets, so the
  # response cannot claim a bound the query did not apply.
  #
  # `unnamed_count` IS AN EXCLUSION, not a population. A null `name` cannot be matched to itself
  # across runs — two nulls are not known to be one test — so those rows are dropped from the
  # matching before anything is grouped. Counted in ROWS and never in tests, because an unnamed row
  # is precisely a row this block cannot say is a test. `unresolved_count` is its sibling exclusion,
  # for the rows that reached no durable identity — the column the identity-grained matching
  # (SPGD-758) is denied by instead, served here beside the first with the same grain and the same
  # semantics.
  #
  # BOTH are `null` wherever the outcome gate below short-circuited — the two keys on that line
  # that go null while `candidate_count`, `examined_count`, `truncated` and `unexamined_count` stay
  # at their zeros. The split is not a stylistic one. Those four are OUTCOME facts, and in a window
  # nothing was examined in their zeros are true: no candidate was found because none was sought.
  # These two are ROW facts — their queries carry no outcome predicate — so the number of excluded
  # rows is fully determined in that window and merely never asked. A `0` would be a fabricated
  # exclusion, wire-identical to a window measured to hold none, and a client reading these keys to
  # learn how much of the window the matching dropped could not tell "not counted" from "counted
  # zero". Null rather than the true count because asking costs the second read the ONE-read
  # property below rules out; the HTML panel refuses to print any count over this same state.
  #
  # `shared_description_rows` IS ITS OWN LIST and never folded into `rows` — exactly as the panel
  # lists them separately. These are descriptions that varied across the window AND were carried by
  # more than one example in at least one run of it, so the description is not a key for that run:
  # its `failed` and its `passed` are two tests rather than one test that flipped. Reported rather
  # than dropped, because a dropped group is a silence a reader has no way to notice, and named as
  # what they are rather than as flakiness, because nothing here establishes which of it.
  #
  # AT MOST FOUR READS OF `spec_observations`, and CONSTANT in the length of the window and the size
  # of the suite — none of them new. They are the panel's own reads, already EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers rather than needing to
  # be repeated in a request spec. The count is not constant in STATE, deliberately:
  # `UnstableTests.for` asks the gating question FIRST and on its own, so an incomparable window
  # costs ONE read and stops, and an unfiltered request costs NONE because the object is never
  # constructed.
  #
  # A FIFTH READ EXISTS AND IS THE CLIENT'S TO ASK FOR: `unstable_test_runs` below issues one more,
  # and only when `?unstable_test=` was sent. It is counted here rather than left for a reader to
  # discover, and it does not disturb the property above — it is bounded by ONE DESCRIPTION'S rows
  # over the same window, so it is constant in the size of the suite exactly as the four are.
  #
  # It does put ONE exception on the "incomparable window costs ONE read and stops" clause above:
  # the drill-in fires on the parameter alone, not on `comparable?`, so an incomparable window that
  # was ASKED a description costs that read too. That is deliberate rather than an oversight. A
  # window the ranking has nothing to say about is precisely the one where the raw per-run grain is
  # worth having — "no candidates" and "here is what this test actually did" are answers to
  # different questions, and gating the second on the first would withhold the grain exactly when
  # the aggregate above it went silent.
  def serialized_unstable_tests
    unstable = unstable_tests

    return nil if unstable.nil?

    {
      rows: unstable.rows.map { |row| serialized_unstable_test_row(row) },
      shared_description_rows: unstable.shared_description_rows.map { |row| serialized_unstable_test_row(row) },
      run_count: unstable.run_count,
      runs_with_rows: unstable.runs_with_rows,
      runs_reporting_outcomes: unstable.runs_reporting_outcomes,
      recorded: unstable.recorded?,
      comparable: unstable.comparable?,
      candidate_count: unstable.candidate_count,
      examined_count: unstable.examined_count,
      truncated: unstable.truncated?,
      unexamined_count: unstable.unexamined_count,
      unnamed_count: unstable.unnamed_count,
      unresolved_count: unstable.unresolved_count,
      limit: SpecObservation::UNSTABLE_CANDIDATE_LIMIT,
      unstable_test_runs: serialized_unstable_test_runs
    }
  end

  # ONE of the rows above, opened: that description's rows across the SAME window, run by run and in
  # window order — the fourth drill-in on this endpoint, on the ladder the three before it set
  # (`?spec_directory=` → `spec_directory_files`, `?spec_file=` → `spec_file_examples`,
  # `?repeated_description=` → `repeated_description_examples`).
  #
  # WHAT THE RANKING ABOVE CANNOT SAY, and the whole reason this exists. A row up there says
  # `run_count: 30`, `failed_run_count: 4`, `outcome_words: ["failed", "passed"]`. Those three
  # figures are IDENTICAL for two windows that call for opposite work: four failures in runs 27–30 is
  # a REGRESSION — find the commit between run 26 and run 27 — and four failures in runs 3, 11, 19
  # and 26 is FLAKINESS, where there is no culprit commit to find and the work is quarantine or
  # shared state. An agent told to "fix the flaky tests" treats every row as the second, and on the
  # first it hunts nondeterminism in a test that fails deterministically. `UNSTABLE_COMPOSITION` is
  # `COUNT`s and `ARRAY_AGG(DISTINCT …)` under `GROUP BY spec_identity_id` and is RIGHT to be — that is what
  # keeps the ranking constant in the size of the suite — so the axis is not recovered by changing
  # it. It is recovered by a rung below it.
  #
  # NOT DERIVABLE FROM ANY OTHER KEY HERE, which is what makes it a key rather than a convenience.
  # `history` rows carry `commit_sha`, `branch` and `ingested_at` and have no per-test grain;
  # `latest_run.spec_file_examples` and `latest_run.repeated_description_examples` carry an `outcome`
  # for the LATEST RUN only. A client holds at most one run's outcome per test beside thirty-run
  # aggregates, and no arithmetic over those produces a sequence.
  #
  # WHAT IT MAKES POSSIBLE, in one join the client already holds both sides of: `history` rows carry
  # `commit_sha` and these rows carry `commit_sha`, so the run this test started failing at is the
  # commit on the earliest row of the failing tail. That is the answer this endpoint could not give.
  #
  # `test_run_id` is served BESIDE `commit_sha` because a commit is not a key: the same commit is
  # legitimately ingested more than once — a re-run, a retry, a second workflow — and a reader
  # following a sequence has to be able to tell two runs of one commit apart before deciding a
  # failure moved.
  #
  # `outcome` GOES OUT VERBATIM and `null` STAYS `null`. Nothing platform-side validates that string
  # (`SpecObservation#outcome_label`), so quoting what arrived is the only reading that cannot be
  # wrong, and a run that recorded the test while reporting no outcome serializes as `null` rather
  # than as a pass — the separation `UnstableTests::Row#changed?` maintains one rung up by comparing
  # against `reported_outcome_count` rather than `recorded_count`, kept here so a client that stopped
  # sending outcomes cannot manufacture a flip that looks like a DATE.
  #
  # NESTED INSIDE `unstable_tests` rather than served beside it, on the shape the three sibling
  # drill-ins already set: each sits inside the block whose row it opens. It is gated by the ASK and
  # by the same `?branch=` the block itself is gated behind — an unfiltered window is interleaved
  # across branches (`serialized_history_window` warns about this at length), and an outcome sequence
  # read down an interleaved window is the outcomes of different code in run order, which is the one
  # reading of these rows that would be worse than not serving them.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the three drill-ins
  # fixed. An ask that matched nothing gets the block with `rows: []` and its `name` restated, HTTP
  # 200 and never a 404: the project's identity rule is semantic, so a RENAMED test starts a new
  # history and every bookmark to the old name goes stale by design.
  #
  # `run_count` and `limit` are the WINDOW and the CAP, disclosed on this block rather than left to
  # be read off the parent: this is a list, and a list that does not say how deep it was allowed to
  # go is read as the whole story. `recorded_count` beside them is the operand a client compares
  # against `rows.length` to see the cap bite — the operands, never the predicate, on
  # `serialized_repeated_description_examples`' standing rule for this endpoint.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on every drill-in's rule: the gate is
  # the ask and it is decided before any read is issued. The read is bounded by ONE DESCRIPTION'S
  # rows over at most thirty runs — constant in the size of the suite, not merely sublinear in it —
  # and rides `index_spec_observations_on_repository_id_and_name`, EXPLAIN-certified for exactly this
  # narrow in `spec/models/spec_observation_spec.rb`.
  def serialized_unstable_test_runs
    return nil if requested_unstable_test.nil?

    # Handed the window AS-IS, deliberately: `UnstableTestRuns` is order-PROPAGATING — the sequence
    # follows the handed orientation, so these rows read newest run first, the same direction as
    # the `history` rows they sit beside. The two anchor sites ask `oldest_first`; this one must
    # not. See `RunWindow`.
    sequence = UnstableTestRuns.for(repository, history_runs, requested_unstable_test)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on the rule
      # every sibling drill-in follows: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the description the rows were actually gathered under.
      name: sequence.name,
      rows: sequence.rows.map do |row|
        {
          test_run_id: row.test_run_id,
          commit_sha: row.commit_sha,
          branch: row.branch,
          ingested_at: row.ingested_at.iso8601,
          outcome: row.outcome,
          duration_seconds: row.duration_seconds,
          spec_file_path: row.spec_file_path,
          line_number: row.line_number
        }
      end,
      recorded_count: sequence.recorded_count,
      reported_outcome_count: sequence.reported_outcome_count,
      unreported_outcome_count: sequence.unreported_outcome_count,
      run_count: sequence.run_count,
      limit: SpecObservation::UNSTABLE_TEST_RUNS_LIMIT
    }
  end

  # One description across the window. Every counter the presenter carries, flat, on
  # `serialized_slowest_examples`' shape — and every one of them an OPERAND rather than one of the
  # labels `UnstableTests::Row` builds for the panel. `#appearance_label` and `#failure_label` word
  # these same figures as `"2 of 5"`, which a client would have to split on a space before it could
  # compare two rows.
  #
  # BOTH DENOMINATORS ARE SERVED, and they are different denominators. `run_count` is the runs this
  # description APPEARED in — not the window's length, which is on the block above — because a test
  # added halfway through the window failed in two of the fifteen runs that ran it, and dividing by
  # thirty would report a stability it was never measured for. `recorded_count` is its ROWS, which
  # exceeds `run_count` exactly when the description was carried by more than one example in a run.
  #
  # `outcome_words` IS ECHOED VERBATIM and never reworded into a verdict — the model's own
  # echo-don't-judge rule, which `SpecObservation#outcome_label` carries the reason for: nothing
  # platform-side validates that string, so quoting what arrived is the only reading that cannot be
  # wrong. An unrecognised word goes out unrecognised.
  #
  # `outcome_words` and `files_seen` are read through the ROW'S ACCESSORS, never off the struct
  # members: both aggregates are `ARRAY_AGG(…) FILTER (…)`, which is SQL NULL rather than an empty
  # array for a group with nothing to collect, and both accessors `Array()`-normalise that and sort
  # — so two rows carrying the same set serialize the same way instead of in whatever order the
  # planner returned.
  #
  # `unreported_outcome_count` is runs that recorded this description and said NOTHING about how it
  # ended. Not a pass, and counted as one nowhere: `#changed?` compares against
  # `reported_outcome_count` and not against `recorded_count`, precisely so a client that stopped
  # sending outcomes cannot manufacture a flip. Served so a client can see the same separation
  # rather than infer it.
  #
  # `shared_description` rides on EVERY row, in both lists, on the rule `serialized_history_row`'s
  # per-row `branch` follows: a client should be able to read a row's classification off the row
  # rather than off the list it arrived in. `multi_file` is beside it and is a DISCLOSURE rather
  # than a defect — the project's identity rule is semantic, so a test that moved is the same test
  # and keeps its history, but a reader looking for a flaky test in one file needs to know the
  # history spans two.
  # `declared_layers`: the DISTINCT layers the test's examples declared anywhere in the window (a
  # set — an identity can change layer mid-window), sorted. `[]` = no run in the window declared
  # one: NOT unreadable, NOT a measured `unit`. A partially annotated identity lists only what was
  # declared. The stored `intent_layer`, never inferred from the path.
  def serialized_unstable_test_row(row)
    {
      name: row.name,
      recorded_count: row.recorded_count,
      run_count: row.run_count,
      reported_outcome_count: row.reported_outcome_count,
      unreported_outcome_count: row.unreported_outcome_count,
      failed_count: row.failed_count,
      failed_run_count: row.failed_run_count,
      outcome_words: row.outcome_words,
      files_seen: row.files_seen,
      multi_file: row.multi_file?,
      shared_description: row.shared_description?,
      spec_identity_id: row.spec_identity_id,
      renamed: row.renamed?,
      descriptions: row.descriptions,
      declared_layers: row.declared_layers
    }
  end

  # The contract the runtime rows below are served under — and, when they are `null`, the reason
  # they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` and
  # `serialized_unstable_tests_window` both argue for in full and which is not repeated here: a
  # client tests one thing rather than distinguishing an absent key from a null one, and a block
  # that explains a `null` is worthless if it is itself absent whenever the `null` happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists for the branch reason its flakiness sibling
  # gives, which binds at least as hard here. `SlowestTests#branch` states the rule for itself:
  # *"Runtimes compared across branches are runtimes of different code, so the window is
  # branch-anchored exactly as those are."* Unfiltered, `history_runs` is the INTERLEAVED
  # all-branch window `serialized_history_window` spends a paragraph warning about — and this
  # object is ANCHORED, so the damage is worse than a mixed total. The anchor would be whichever
  # branch happened to run last, and the ⭐ partition it decides would rank THAT branch's tests
  # against the window's other branch's history. So unfiltered, `SlowestTests.for` IS NOT CALLED AT
  # ALL — no anchor, no reads — and this boolean is what says so.
  #
  # It is read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ?
  # true : false`, on the rule the sibling states: a second copy of the gate is a second thing to
  # keep true. So `grouped` is exactly `slowest_tests != null`, in every response.
  #
  # `order` DESCRIBES `SlowestTests::Row#sort_key` TRUTHFULLY, all three keys and the nil rule:
  # `[total_seconds.nil? ? 1 : 0, -(total_seconds || 0.0), -recorded_count, spec_identity_id]`. The
  # NULLS LAST clause is named rather than left implicit because it is the one part a client would
  # get backwards by defaulting — a test nobody timed is not a test that cost nothing, and sorting
  # its nil as a zero would put it at whichever end the client's language happens to put nils.
  #
  # `tie_break_served: true`, and it is true because `spec_identity_id` GOES OUT ON THE ROW. All
  # four operands of the sort — the nil flag, the total, the appearance count and the identity —
  # are served, so a client CAN reproduce this exact order from what it holds. Had the identity
  # been withheld this would have had to say `false`: the final tie-break would not be
  # reproducible, and two tests totalling identically over the same number of runs would be a pair
  # a client could not order. That is the same honesty `serialized_history_window` shows in the
  # other direction, where the tie-break is an ingest sequence no row carries.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token, and `branch` is
  # always served (`null` when the window was not narrowed) — `serialized_history_window` makes
  # both arguments in full. They carry the same values `history_window` and `unstable_tests_window`
  # carry in the same response, because all three describe the SAME window.
  def serialized_slowest_tests_window
    {
      order: "total_seconds_desc_nulls_last,recorded_count_desc,spec_identity_id_asc",
      tie_break_served: true,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !slowest_tests.nil?
    }
  end

  # WHICH TESTS COST THE MOST WALL CLOCK ACROSS RUNS — the agent-readable half of the "Slowest tests
  # over the window" panel `repositories#show` renders, and the roadmap's first axis of suite
  # intelligence ("per-test duration") at the grain the Project Goals pin as semantic.
  #
  # A DIFFERENT GRAIN FROM `latest_run.slowest_examples`, which is why it is served beside
  # `unstable_tests` rather than inside that block. `slowest_examples` reaches the per-example grain
  # of ONE run — `SlowestExamples.for(test_run)` is bounded to one run by construction — and this is
  # the same question over a window, matched to a DURABLE TEST rather than to a coordinate. An agent
  # holding thirty responses could not assemble it: no identity crosses the wire on that block, so
  # grouping client-side means grouping on `(file_path, line_number)`, which splits a moved test's
  # history in two, or on `name`, which survives a move but not a rename. `SlowestTests`' class
  # comment states both failure modes and what the identity grain buys instead: *"a test that moved
  # keeps its runtime history."*
  #
  # AND A DIFFERENT GRAIN FROM `unstable_tests`, which is the neighbour it most resembles. That
  # block groups on `spec_identity_id` too — the question is about outcomes on a DURABLE TEST — so
  # an annotated test that was REWORDED keeps one outcome history there, disclosed by the `renamed`
  # key on its own row. An unannotated renamed test is still two tests there, on the owner-settled
  # rule that an unannotated rename loses its history.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SlowestTests` is view-free, so the API and the panel name
  # the same tests in the same order off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query — see `slowest_tests` below,
  # where the ⭐ ORDERING HAZARD that distinguishes this call site from the flakiness one is stated
  # in full. It is not a copy of that gate and must not be read as one.
  #
  # `null` — THE KEY STILL PRESENT — under an unfiltered window, and the argument for that is on
  # `serialized_slowest_tests_window` above where the boolean that explains it lives.
  #
  # AN EMPTY `rows` IS A REAL ANSWER HERE and is not the same state. Under a branch-scoped window
  # the object IS constructed, and `rows: []` beside `state: "ranked"` means "we ranked and this
  # suite holds nothing slow". The two must never serialize identically, which is what `state` is
  # for.
  #
  # ⭐ `state` IS LOAD-BEARING, not a convenience. An empty list has FOUR meanings here and
  # `SlowestTests`' class comment separates them: `no_runs` (the window is empty), `unrecorded` (the
  # anchor wrote no per-example rows), `unresolved` (it wrote rows and none of them has been matched
  # to a durable test yet) and `ranked`. Only the last may be read as "nothing in this suite is
  # slow". `Ingest::IdentityResolutionJob` is asynchronous, so `unresolved` is the ORDINARY state
  # for the seconds after an ingest — Vacuous Green exactly, in the shape this project keeps finding
  # it, and a block that served those four as one empty array would report a clean result for work
  # it did not do.
  #
  # `anchor_run` NAMES THE RUN THAT DECIDED MEMBERSHIP. The candidates are the newest run's slowest
  # tests and the window merely supplies their history, so a test that ran in the first twenty runs
  # of the window and not in the newest is NOT HERE — a partition the rows cannot be read to
  # discover. `test_run_id` goes out BESIDE `commit_sha` for the reason `unstable_test_runs` states:
  # a commit is not a key, since the same commit is legitimately ingested more than once.
  #
  # `recorded` / `resolved` / `excluded_unresolved_rows` are read off the object's OWN predicates,
  # CALLED rather than re-spelled here, on the rule `serialized_spec_files`' `#recorded?` gate
  # states: a controller-side copy of a predicate is free to drift the day the presenter's changes.
  # The same goes for `truncated`, `complete` and `untimed_count`.
  #
  # `truncated` / `unexamined_count` DISCLOSE THE CANDIDATE CAP, with both OPERANDS
  # (`candidate_count`, and `rows.length` the client already holds) beside the boolean so a client
  # can check the comparison rather than take it. `limit` is read off `SpecObservation::SLOWEST_LIMIT`
  # rather than restated here, on the precedent `serialized_slowest_examples` sets, so the response
  # cannot claim a bound the query did not apply.
  #
  # ⚠️ `null` VERSUS `0` IS CONTRACTUAL ON FIVE KEYS, and it is `SlowestTests::UNREAD` serialized
  # through rather than a shape to be tidied. `recorded_count`, `unresolved_count`,
  # `candidate_count`, `resolved_count` and `timed_count` are `nil` in every state that returned
  # before the read that would have produced them, and a `0` there would be wire-indistinguishable
  # from a window MEASURED to have excluded nothing — which is exactly the distinction these keys
  # exist to let a client draw. `serialized_unstable_tests` makes the identical split for its
  # `unnamed_count`.
  #
  # STRUCTURED COUNTS AND BOOLEANS, NOT PROSE — this endpoint's standing rule. `RepositoriesHelper`
  # words this same coverage for the panel and `SlowestTests` exposes four label readers
  # (`duration_label`, `slowest_label`, `coverage_label`, `appearance_label`); not one of them is
  # served. A machine client cannot act on "9 of 12" without parsing it, so the OPERANDS go out and
  # the client divides.
  #
  # AT MOST THREE READS of `spec_observations`, and ONE in the gating states — none of them new, and
  # none growing with the size of the suite or the length of the window. They are the panel's own
  # reads, `EXPLAIN`-certified in `spec/models/spec_observation_spec.rb`, so that certification
  # transfers rather than needing to be repeated in a request spec (the precedent
  # `serialized_slowest_examples` and `serialized_unstable_tests` both rely on). An unfiltered
  # request costs NONE, because the object is never constructed.
  def serialized_slowest_tests
    slowest = slowest_tests

    return nil if slowest.nil?

    {
      rows: slowest.rows.map { |row| serialized_slowest_test_row(row) },
      state: slowest.state.to_s,
      anchor_run: serialized_slowest_tests_anchor_run(slowest.anchor_run),
      run_count: slowest.run_count,
      recorded: slowest.recorded?,
      resolved: slowest.resolved?,
      excluded_unresolved_rows: slowest.excluded_unresolved_rows?,
      recorded_count: slowest.recorded_count,
      unresolved_count: slowest.unresolved_count,
      resolved_count: slowest.resolved_count,
      candidate_count: slowest.candidate_count,
      timed_count: slowest.timed_count,
      untimed_count: slowest.untimed_count,
      complete: slowest.complete?,
      truncated: slowest.truncated?,
      unexamined_count: slowest.unexamined_count,
      limit: SpecObservation::SLOWEST_LIMIT
    }
  end

  # The run the ⭐ partition was taken from, named as a REFERENCE rather than restated as a run
  # block. `test_run_id` leads and `commit_sha` rides beside it on `unstable_test_runs`' rule — a
  # commit is not a key, because a re-run, a retry or a second workflow ingests the same commit
  # again — and `branch` is served because the anchor is the one run whose branch decided which
  # tests are on the list at all.
  #
  # `null` — the key still present — in `:no_runs`, where the window held no run to anchor on. That
  # is the one state where there is no run to name, and it is exactly the state `state` reports.
  def serialized_slowest_tests_anchor_run(run)
    return nil if run.nil?

    {
      test_run_id: run.id,
      commit_sha: run.commit_sha,
      branch: run.branch,
      ingested_at: run.created_at.iso8601
    }
  end

  # ONE durable test's runtime across the window.
  #
  # `spec_identity_id` IS THE FIELD THIS WHOLE BLOCK EXISTS FOR, and it is the only stable join key
  # a client can carry between two responses. Neither `slowest_examples` nor `unstable_tests` serves
  # an identity, which is precisely why a client holding them cannot rebuild this ranking. It is
  # also what makes `tie_break_served: true` on the window block honest.
  #
  # `total_seconds` BESIDE `slowest_seconds`, never one without the other: sixty seconds is one
  # minute-long test or sixty runs of a one-second one, and a ranking ordered on the sum alone
  # cannot tell a reader which they are looking at. Neither is coalesced to `0.0` — a group nothing
  # timed serves `null`, on the rule `serialized_spec_files` states, because a zero there is an
  # invented measurement.
  #
  # ⭐ `moved` AND `renamed` ARE THE POINT OF THE IDENTITY GRAIN and no other key on this endpoint
  # can express either. `moved` is this test recorded under more than one spec file across the
  # window — the guarantee being KEPT rather than an anomaly, and a fact about where to go looking.
  # `renamed` is its description changing while its identity did not — the same disclosure
  # `unstable_tests` makes on its own rows, since both reads group on `spec_identity_id`.
  #
  # `descriptions` and `files_seen` are the OPERANDS behind those two booleans, so a client can see
  # what the flag is claiming rather than take it. Both are read through the Struct's own readers
  # and never off the raw attributes: the aggregates are `ARRAY_AGG(…) FILTER (…)`, i.e. SQL NULL
  # for a group with nothing to collect, and the readers are where the `Array()` wrap and the sort
  # live — so two rows carrying the same set serialize the same way.
  #
  # `repeated_within_run` says this test ran more than once in at least one run — a table-driven
  # loop or a shared example group — which is what separates "slow in twelve runs" from "run three
  # times in each of four". `recorded_count` and `run_count` are the two operands beside it.
  #
  # `timed` / `timed_count` / `untimed_count` keep a blank duration from being read as a zero. A row
  # that reaches this list untimed is ordinary, not a defect: an example that never ran has no
  # duration to report.
  def serialized_slowest_test_row(row)
    {
      spec_identity_id: row.spec_identity_id,
      total_seconds: row.total_seconds,
      slowest_seconds: row.slowest_seconds,
      run_count: row.run_count,
      recorded_count: row.recorded_count,
      timed_count: row.timed_count,
      untimed_count: row.untimed_count,
      timed: row.timed?,
      repeated_within_run: row.repeated_within_run?,
      moved: row.moved?,
      renamed: row.renamed?,
      descriptions: row.descriptions,
      files_seen: row.files_seen,
      declared_layers: row.declared_layers
    }
  end

  private

  attr_reader :overview

  delegate :repository, :history_runs, :requested_branch, :requested_unstable_test,
           to: :overview, private: true

  # The presenter, or `nil` when no ranking was allowed — memoized across the nil with `defined?`
  # rather than `||=`, for the reason `unstable_tests` states below and under the same double read
  # (`show` asks for the window block's `grouped` and then for the rows).
  #
  # ⭐ THIS SITE ASKS FOR THE WINDOW OLDEST FIRST, AND THAT IS ITS WHOLE SUBTLETY — the one place
  # this gate is NOT a copy of its flakiness sibling, which sits ten lines below and is otherwise
  # line-for-line identical.
  #
  # `SlowestTests.for` needs the window OLDEST FIRST — it takes `runs.last` as its ANCHOR, the run
  # that decides WHICH TESTS ARE IN THE LIST AT ALL (its ⭐ PARTITION section) — and says so by
  # asking `history_runs.oldest_first`. The orientation itself was decided once, at the load: the
  # query orders `(created_at, id) DESC` — NEWEST first — and the window carries that fact, so
  # this site asks for the end it needs instead of performing a remembered `.reverse`. What the
  # orientation is worth naming for has not changed: handing the anchor the wrong end DOES NOT
  # RAISE — `validate_anchor!` checks tenancy only, and an old run of the same repository passes
  # it. What comes back is a fully-populated, plausible block that ranks the OLDEST run's slowest
  # tests, reports THAT run's figures in `recorded_count` / `resolved_count` / `timed_count`, and
  # names it in `anchor_run` — an answer to a question nobody asked, wearing the shape of the
  # right one. `spec/requests/api/v1/repository_slowest_tests_spec.rb` guards it by asserting the
  # served `anchor_run` is the NEWEST run of the window, which fails if this site ever asks for
  # the wrong orientation.
  #
  # The adjacent precedent is what made it easy to walk into and is NOT a licence: `UnstableTests.for`
  # is order-INDIFFERENT — it reads `runs.map(&:id)` and `runs.size` and nothing else, and says so —
  # so `unstable_tests` below hands the window straight in, asking for no end, and is right to.
  # `RepositoryGrowthSerializer#spec_directory_window_growth` is the OTHER anchor site, and asks for the same
  # orientation this one does.
  #
  # The no-mutation rule is `RunWindow`'s to enforce, guaranteed by the object rather than
  # restated by its readers — the reasoning lives in the `== Non-mutating, by construction`
  # header of `app/models/run_window.rb`.
  #
  # NO SECOND WINDOW QUERY, and that is deliberate rather than incidental: `history_runs` is
  # materialized once, and both `UnstableTests` and `SlowestTests` document their window as handed
  # in precisely so two surfaces cannot come to be drawn on two windows that agree today with no
  # structural reason to keep agreeing.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart — see `serialized_slowest_tests_window` for why an unfiltered
  # window is refused rather than answered.
  def slowest_tests
    return @slowest_tests if defined?(@slowest_tests)

    @slowest_tests =
      requested_branch && SlowestTests.for(repository, history_runs.oldest_first, branch: requested_branch)
  end

  # The presenter, or `nil` when no comparison was allowed — memoized, because `show` reads it
  # twice: once for the window block's `grouped` and once for the rows. Without the memo the whole
  # thing is built twice and the block's four reads become eight, which is what the cost examples
  # next door count.
  #
  # MEMOIZED ACROSS THE NIL — `defined?` rather than `||=` — so the memo means "already decided"
  # rather than "already truthy". That distinction is free TODAY: `requested_branch &&`
  # short-circuits before any read, so re-evaluating the nil case costs nothing and a `||=` would
  # behave identically. It stops being free the moment this gate consults anything that costs, and
  # the shape that cannot regress is the one that does not depend on the answer being truthy.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart. See `serialized_unstable_tests_window` for why an unfiltered
  # window is refused rather than answered.
  def unstable_tests
    return @unstable_tests if defined?(@unstable_tests)

    @unstable_tests =
      requested_branch && UnstableTests.for(repository, history_runs, branch: requested_branch)
  end
end
