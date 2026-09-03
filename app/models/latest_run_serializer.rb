# frozen_string_literal: true

# THE `latest_run` BLOCK, ASSEMBLED ONCE AT A DECLARED DEPTH — the run-level facts of one
# repository's newest run, served identically to whichever surface is listing or opening it.
#
# ## Why one serializer, and why a depth
#
# Two surfaces need these facts. `GET /api/v1/repository` and `GET /api/v1/repositories/:id`
# serve the block in FULL — every rollup, every drill-in, the whole decomposition of a run's wall
# clock — because a client that has opened ONE repository is asking "why did this run take as long
# as it did". `GET /api/v1/repositories` serves it at LIST depth, because a client choosing
# between thirty repositories is asking a different question — which of them CI reported to most
# recently, and what each suite costs — and answering it should not require opening any of them.
#
# The naming rule this API holds itself to — the two surfaces do not get to name the same facts
# differently — used to be enforced by hand: a comment on one controller stated it, another
# restated it for its own block, and the previous revision of the ticket that commissioned this
# class forbade coining new key names and coined two in the same breath. A rule kept by memory is
# kept until someone forgets. One serializer with a depth parameter makes the rule structural: the
# list entry and the detail page are the SAME CODE, and the only thing that varies is how far down
# it goes. A later reader adding a key opens this one file and sees both depths side by side.
#
# ## What travels at which depth
#
# Both depths serve the run-level scalars — `commit_sha`, `branch`, `total_specs`,
# `annotated_specs`, `annotated_ratio`, `suite_size_measured`, `duration_seconds`, `ingested_at`
# — and the shard facts NESTED under `shards`, mirroring the detail endpoint verbatim. The full
# depth adds everything that answers *why this run took as long as it did*: `intent_readings`, the
# four rollups, the five drill-ins, and — inside `shards` — the coverage pair, the wall-clock
# decomposition and the settling-window pair. Those stay off the list entry, and two of them are
# arrays that an unpaginated list has no business fanning out per repository.
#
# `shards` keeps its key names exactly as the detail endpoint serves them (`count`,
# `timed_count`, `machine_seconds`), never flattened onto the run — flattening would mint wire
# names that exist today only as `TestRun` method names, in a public JSON body that cannot be
# renamed later without breaking clients. `last_shard_arrived_at` stays out of the list depth for
# a QUERY-BUDGET reason rather than a preference: `ShardCountPreloading#preload_shard_counts`
# primes the three scalars in one grouped aggregate and deliberately nothing else, and
# `TestRun#last_shard_arrived_at` reads `MAX(updated_at)` out of `shard_totals`, which the
# module's own comment records as still costing one `pick` per row — serving it across an
# unpaginated list would reintroduce exactly the N+1 the module exists to kill.
#
# ## What this class is handed
#
# `test_run` may be NIL — "this repository's CI has never reported" — and `nil` is the whole
# answer then, never a zero-filled block. The FULL depth also needs `overview:` — the
# `RepositoryOverview` holding the ask — because its drill-in blocks read `params` through the
# `Requested*Param` concerns and are the overview's to build. Those methods stay there and are
# reached through this collaborator; everything pure lives here. `#serialized_shards` and
# `#serialized_shard_rows` were pure functions of the `TestRun` handed to them before this class
# existed (no instance state, no `params`), which is what made this extraction a move rather than
# a rewrite.
#
# ## The invariant this class is under
#
# The full depth is byte-identical to the block `RepositoryOverview#serialized_latest_run` served
# before the extraction — key for key, order for order, comment for comment where the comments
# moved with the keys. `spec/requests/api/v1/repository_latest_run_spec.rb` is that net and passes
# untouched; a net edited to make a refactor pass is not a net.
class LatestRunSerializer
  # The depth `GET /api/v1/repositories` serves on every entry: the run-level scalars and the
  # nested shard scalars, and nothing that opens the run up.
  LIST_DEPTH = :list

  # The depth the two overview routes serve: everything, drill-ins included.
  FULL_DEPTH = :full

  DEPTHS = [LIST_DEPTH, FULL_DEPTH].freeze

  # `overview:` is required at full depth and unused at list depth — the drill-in blocks it
  # supplies read `params`, which this class deliberately does not hold. Refused loudly at
  # construction rather than as a `nil` NoMethodError three calls deep, so the omission names
  # itself: "the full depth needs the overview that holds the ask" is a sentence a reader can act
  # on, a stack trace into `full_body` is one they have to reconstruct.
  def initialize(test_run, depth:, overview: nil)
    unless DEPTHS.include?(depth)
      raise ArgumentError, "unknown depth #{depth.inspect}; expected one of #{DEPTHS.inspect}"
    end
    if depth == FULL_DEPTH && overview.nil?
      raise ArgumentError, "the full depth serves the ask-dependent drill-in blocks and needs " \
                           "the RepositoryOverview that holds the ask"
    end

    @test_run = test_run
    @depth = depth
    @overview = overview
  end

  # `nil` — not a zeroed block — when CI has never reported. A repository whose CI has never run
  # must not serialize byte-identically to one that ran and genuinely found an empty suite; that is
  # the conflation the Overview panel refuses too (see RepositoriesController#show).
  # A repository-wide ratio floored at 0.0 cannot express the difference, which is why this reads
  # the run.
  def body
    return nil if test_run.nil?

    depth == LIST_DEPTH ? list_body : full_body
  end

  private

  attr_reader :test_run, :depth, :overview

  # The list depth, spelled in the order the list reads it: WHEN CI last reported, on WHAT, HOW
  # BIG the suite is, HOW WELL SpecGuard can see it, HOW LONG the run took, and WHAT IT COST.
  #
  # Every scalar here is the SAME CALL the full depth spells — a fact this class states by
  # construction and `user_repositories_spec.rb` pins by asserting the list block against the
  # detail endpoint's block for the same run, key for key. The spellings are written out in both
  # bodies rather than factored into a shared hash because the full body's ORDER is pinned
  # byte-for-byte by the detail endpoint's specs and interleaves the drill-ins between the
  # scalars — a shared hash could not preserve it, and reordering the full body to suit a shared
  # hash would change a shipped response's bytes.
  #
  # NOT RE-ANCHORED here by anything: this class is handed the run already chosen. Whether that
  # choice follows `?branch=` or `?commit_sha=` is `RepositoryOverview`'s question — see
  # `serialized_latest_run` there for the anchoring rules this block inherits untouched.
  def list_body
    {
      ingested_at: test_run.created_at.iso8601,
      # Nullable, and Ingest::Payload accepts a body without it. `null` here means "the client did
      # not say", which is a different fact from any branch name we could substitute for it.
      branch: test_run.branch,
      commit_sha: test_run.commit_sha,
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      # The 0–1 FRACTION, the same `TestRun#annotated_fraction` call `/ingest` answers this run
      # with — never the 0–100 percentage `TestRun#annotated_ratio` renders for the dashboard. The
      # 100× gap between the two is invisible in a JSON body, so two depths disagreeing about it
      # would be a silent two-orders-of-magnitude error for any client that read both. The call is
      # copied from the full depth below rather than inferred from the key name, on the same rule.
      # `null` for a run that reported no tests; the model carries why.
      annotated_ratio: test_run.annotated_fraction,
      # `TestRun#suite_size_measured?`, the same predicate the history row serves, for the same
      # reason: a run that reported zero tests has a `total_specs` but not a measurement, and a
      # ranking taken against it orders repositories by the report rather than by the suite.
      # Present on every entry that has a run — never absent, never null.
      suite_size_measured: test_run.suite_size_measured?,
      # Nullable by schema. Serializing `0.0` for an unreported duration would assert the run took
      # no time — the same "not reported" vs `0.0s` distinction the Recent runs table draws.
      #
      # On a sharded run this is the MAX over the shards — the run's WALL CLOCK, not what the
      # suite cost. `shards.machine_seconds` below is the other half of that pair.
      duration_seconds: test_run.duration_seconds,
      shards: list_shards
    }
  end

  # THE FULL DEPTH, moved verbatim from `RepositoryOverview#serialized_latest_run` — the per-key
  # reasoning below is that method's, carried with the keys it explains. Only the drill-in calls
  # gained their `overview.` prefix, because only the collaborator changed.
  #
  # ANCHORING IS NOT THIS CLASS'S QUESTION. It is handed the run already chosen — by the overview
  # at full depth (NOT re-anchored by `?branch=`, re-anchored by `?commit_sha=`; see
  # `RepositoryOverview#serialized_latest_run` for both rules and the `history[0] == latest_run`
  # identity they protect), and by the list controller at list depth (the newest run per
  # repository, resolved by `DeliveryHealthLookups#latest_test_runs_for` on the same tie-break
  # `Repository#latest_test_run` uses, so a list entry and the detail page it links to cannot name
  # different runs). A serializer that re-chose its run would be a second answer to a question one
  # caller has already answered.
  def full_body
    {
      commit_sha: test_run.commit_sha,
      # Nullable, and Ingest::Payload accepts a body without it. `null` here means "the client did
      # not say", which is a different fact from any branch name we could substitute for it.
      branch: test_run.branch,
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      # The 0–1 FRACTION, the same `TestRun#annotated_fraction` call `/ingest` answers this run
      # with — never the 0–100 percentage `TestRun#annotated_ratio` renders for the dashboard. The
      # 100× gap between the two is invisible in a JSON body, so two endpoints disagreeing about it
      # would be a silent two-orders-of-magnitude error for any client that read both. `null` for a
      # run that reported no tests; the model carries why.
      annotated_ratio: test_run.annotated_fraction,
      # HOW THIS RUN READS — the three states of `SpecObservation::READINGS` over its per-example
      # rows, unconditional and cheap (one aggregate over one run), because it is the block's answer
      # to a question every other key here left to a subtraction.
      #
      # `total_specs - annotated_specs` was the only figure a client had for "what SpecGuard cannot
      # see", and the MCP bridge repeats that sentence to an agent verbatim. It counts the examples
      # with no AUTHORED intent, which is exact, and most of those carry a `Class#method behavior`
      # description SpecGuard reads perfectly well. `unreadable` is the population that claim may be
      # made about, `derived` is the population it was wrongly made about, and both are served here
      # so no client has to phrase its own version of the distinction.
      #
      # `recorded` is shipped WITH them and is not `total_specs`. The counters above are re-derived
      # by SUM over `test_run_shards` from what each shard REPORTED; these three are counted over the
      # rows actually STORED, and a sharded or partially-redelivered run legitimately has more of the
      # first than of the second. A client dividing these by `total_specs` would be dividing two
      # populations; `recorded` is the denominator that was counted with them. It is also how a
      # client tells "this run stored no per-example detail" (`recorded: 0`, three zeros beside it)
      # from "this run is entirely unreadable", which are the same three zeros otherwise.
      #
      # `authored` deliberately does NOT replace `annotated_specs` above and no client should read it
      # as the annotation coverage figure — that is `annotated_ratio`, off the counters, answering
      # exactly as it did before this key existed. `authored` is here so the three sum to `recorded`.
      intent_readings: overview.serialized_intent_readings(test_run),
      # Nullable by schema. Serializing `0.0` for an unreported duration would assert the run took
      # no time — the same "not reported" vs `0.0s` distinction the Recent runs table draws.
      #
      # On a sharded run this is the MAX over the shards — the run's WALL CLOCK, not what the suite
      # cost. It keeps that key, that type and that value: `shards` below is added beside it rather
      # than in place of it, so nothing a client reads today changes meaning.
      duration_seconds: test_run.duration_seconds,
      shards: serialized_shards,
      spec_files: overview.serialized_spec_files(test_run),
      # BESIDE `spec_files`, never in place of it: the two rank different populations and the
      # second is not derivable from the first. See `serialized_spec_directories` on the overview.
      spec_directories: overview.serialized_spec_directories(test_run),
      # BESIDE both rollups above, and it is the grain NEITHER of them can reach: those two name
      # areas and files, and an agent holding both still cannot ask which TEST inside a 90-second
      # directory to open. See `serialized_slowest_examples` on the overview.
      slowest_examples: overview.serialized_slowest_examples(test_run),
      # BESIDE `slowest_examples`, and the grain none of the three blocks above can reach. Those
      # roll this run's rows up by where the code LIVES — the example, its file, its area — and no
      # rollup of "where" can see that two of those rows say the same thing. See
      # `serialized_repeated_descriptions` on the overview.
      repeated_descriptions: overview.serialized_repeated_descriptions(test_run),
      # ONE AREA of `spec_directories` above, opened — the first of the three keys in this block
      # that answer a question the client asked rather than one the endpoint always answers, and so
      # the first whose `null` is a fact about the REQUEST. `shards` is null for a fact about the
      # run (it had one part, which is the ordinary case) and the four rollups for a fact about its
      # rows (there were none); this one is null because no area was asked for, which is a statement
      # about neither the run nor its rows. See `serialized_spec_directory_files` on the overview.
      spec_directory_files: overview.serialized_spec_directory_files(test_run),
      # ONE FILE of that area, opened — the rung below the key above it and the last one this ladder
      # has: area → file → example, with nothing under an example to open. Its `null` is a fact
      # about the REQUEST for the same reason `spec_directory_files`' is, and it is the second key
      # on this block to which that applies rather than an exception to the rule the four rollups
      # follow. `shards` is null about the run, the four rollups about its rows, and the three
      # drill-ins about what the client asked. See `serialized_spec_file_examples` on the overview.
      spec_file_examples: overview.serialized_spec_file_examples(test_run),
      # ONE GROUP of `repeated_descriptions` above, opened — the third key on this block whose
      # `null` is a fact about the REQUEST, and the one drill-in that leaves the area → file →
      # example ladder entirely. Those two open a place; this one opens a SENTENCE, and the ranking
      # it drills out of is the only one here that is not a rollup of where the code lives. See
      # `serialized_repeated_description_examples` on the overview.
      repeated_description_examples: overview.serialized_repeated_description_examples(test_run),
      # THE FOURTH KEY ON THIS BLOCK WHOSE `null` IS A FACT ABOUT THE REQUEST, and the only drill-in
      # here that opens a POPULATION rather than a pick. The three above it open one area, one file
      # and one sentence — each the rows behind a LINE of a ranking served just above it. This one
      # opens the rows behind `total_specs` MINUS `annotated_specs`, two keys at the top of this very
      # block, which is a subtraction and names nothing.
      #
      # It is the rung `annotated_ratio` never had. Every other figure on this endpoint that reports a
      # population can be walked down to the examples it counts; the product's stated primary adoption
      # metric was the sole exception, on both surfaces — `repositories#show` prints *"SpecGuard cannot
      # see the other N tests"* and cannot name one of them either. See
      # `serialized_unannotated_examples` on the overview.
      unannotated_examples: overview.serialized_unannotated_examples(test_run),
      # THE RANKING ABOVE THE KEY DIRECTLY ABOVE IT, and the fifth `null`-is-a-fact-about-the-request
      # key on this block — served from the SAME `?unannotated_examples=` ask rather than from a new
      # parameter, so a client that never asks still pays nothing. See
      # `serialized_unannotated_directories` on the overview, where the scope difference between the
      # two keys is stated in full.
      unannotated_directories: overview.serialized_unannotated_directories(test_run),
      # `TestRun#suite_size_measured?`, the same predicate `serialized_history_row` serves and
      # for the same reason: a run that reported zero tests has a `total_specs` but not a
      # measurement, and a difference taken against it describes the report rather than the suite.
      # Served from the predicate and never re-derived inline from `total_specs`, so the endpoint,
      # the history row and the panel cannot drift on what "measured" means.
      #
      # It belongs HERE and not only on the history row, because in the unfiltered window
      # `history[0]` is the SAME ROW as this one — the identity `repository_latest_run_spec.rb`
      # pins and the ordering comment on `history_runs` protects. Withholding the key from one of
      # the two blocks let a single response body describe one row twice and disagree with itself:
      # `history[0]` saying the suite was never measured while `latest_run`, thirty lines up,
      # could not say it.
      #
      # Present on EVERY response that has a run — never absent, never null — on the rule
      # `timed_shard_count` follows: a guard a client has to test for before it can trust is not a
      # guard. A repository whose CI never reported has no `latest_run` block at all.
      suite_size_measured: test_run.suite_size_measured?,
      ingested_at: test_run.created_at.iso8601
    }
  end

  # The nested shard facts at LIST depth: the three scalars `ShardCountPreloading` primes for a
  # whole window in one grouped aggregate, and nothing else. The `multi_shard?` gate is MIRRORED,
  # not softened — `serialized_shards` below returns `nil` for a single-part run and so does this,
  # because a zero-filled block would assert "this run had one shard" where the truth is "there is
  # nothing to say about shards here". `shard_count` is primed, so evaluating the gate costs no
  # query.
  def list_shards
    return nil unless test_run.multi_shard?

    shard_scalars
  end

  # The other half of what a sharded run cost, plus the denominator each cost figure was computed
  # over. `duration_seconds` above is a MAX and `machine_seconds` here is a SUM, and on the
  # project's canonical 4-shard fixture they differ by 3.4× — a client reading only the MAX
  # understates the suite's cost, with no caption to warn it the way the Overview panel has one.
  #
  # The first three keys are `shard_scalars` below — THE ONE SHARED SLICE between the depths, so
  # the list entry's `shards` and this block's opening cannot drift — and everything after them is
  # the full depth's alone.
  #
  # STRUCTURED COUNTS, NOT PROSE. `TestRun#machine_seconds_coverage` and `#wall_clock_coverage`
  # answer this same question for the panel, but they answer it in English ("slowest of the 3 that
  # reported"), and a machine-readable client cannot act on a sentence without parsing it. So this
  # serializes the counts those sentences are built from and lets the client word it — or not word
  # it at all and just divide.
  #
  # `coverage` keys each figure by the exact JSON name the client reads it under, so there is no
  # guessing which denominator belongs to which number: `coverage.duration_seconds` is how many
  # shards the MAX was taken over, `coverage.machine_seconds` how many the SUM was taken over, and
  # `count` is how many the run has. Today both are `timed_count` — SQL's MAX and SUM skip the same
  # nulls — but each states its own rather than sharing one field, because a client should not have
  # to know that they coincide, and a figure whose coverage is inferred from a neighbour is exactly
  # the honesty gap this block exists to close.
  #
  # `null` — not an empty or zeroed block — for a run with one shard or none, which is the entire
  # unsharded corpus. There is nothing to disambiguate there (one shard's MAX *is* its SUM, zero
  # shards have neither), and `multi_shard?` is the gate every caller must sit behind: `shard_totals`
  # returns a real `0` for a shardless run, so an ungated block would print `count: 0` and a
  # `machine_seconds: null` for a laptop run that reported a perfectly good duration. The KEY stays
  # present in every response, on the same rule `latest_run` itself follows — a client tests one
  # thing (`shards == null` → "not assembled from parts") rather than distinguishing an absent key
  # from a null one.
  #
  # WHICH SHARD, not just how many. The four scalars above say a run was assembled from four parts
  # and cost 253.75s between them; not one of them is a shard, so an agent reading only those
  # cannot learn which part it waited on. `repositories#show` has rendered the full decomposition —
  # the rows, the balanced floor, the excess over it — since SPGD-192, and the three keys added
  # below are the same model accessors that panel reads, so the API and the panel cannot name
  # different figures for the same run.
  #
  # `rows` mirrors `TestRun#shard_durations`' ordering VERBATIM rather than re-sorting here, which
  # is what makes `rows.first` and the panel's `longest_shard_label` the same shard by
  # construction instead of by coincidence.
  #
  # `shard_id` RAW AND NULLABLE, never a position number. `TestRun#shard_label` argues this at
  # length: a client that shards without naming its slices sends nothing, and numbering the rows
  # would hand the reader a name CI never used — one that points at a different slice next run.
  # The prose formatting (`"shard 3"` / `"an unnamed shard"`) stays view-side; a client that wants
  # a sentence can build one, and a client that wants to correlate against its CI config needs the
  # raw value.
  #
  # RAW FLOATS, not the panel's `humanized_seconds` labels, on the rule `duration_seconds` and
  # `machine_seconds` already follow on this endpoint. Prose in JSON is a figure a client has to
  # regex before it can compute with it.
  #
  # GATED ON `#wall_clock_decomposable?` ITSELF — called, not re-spelled. Two of its three
  # conditions are easy to reach for and the third is the one that matters:
  # `shard_delivery_settled?`. `Repository#latest_test_run` picks a run up the instant its FIRST
  # shard lands, so on a half-delivered run every shard present is timed and a two-condition gate
  # waves it through with a partial SUM over a partial count — both the floor and the excess move,
  # in the direction that manufactures a finding. And the gate is a correctness requirement rather
  # than only an honesty one: `#wall_clock_excess_seconds` documents that it RAISES on a nil
  # `duration_seconds`, which is exactly the state a run whose shards said nothing is in.
  #
  # `null` — the three keys still PRESENT — when the gate fails, on this block's own rule that a
  # client tests one thing rather than distinguishing an absent key from a null one. Never a
  # partial or mis-ordered list: `duration_seconds: :desc` is NULLS FIRST in Postgres, so an
  # ungated `rows` would put the shard that reported *nothing* at the head of a list whose whole
  # contract is "slowest first".
  #
  # TWO EXTRA QUERIES AT MOST, and constant rather than minimal. Both `#shard_durations` and
  # `#shard_reports` are documented as reads beside the memoized `shard_totals` aggregate, kept
  # separate so widening `shard_totals` does not change what its other callers load — so each
  # costs one more statement. They do not fall on the same runs: `#shard_reports` feeds `per_shard`
  # and is paid by every multi-shard run, while `#shard_durations` feeds the three gated keys and
  # is paid only when `#wall_clock_decomposable?` passes. So an ungated multi-shard run costs one
  # extra, a gated one costs two, and a shardless run pays nothing at all. What is bounded is that
  # neither scales: a 40-shard matrix costs exactly what a 4-shard one does. The gate
  # `#wall_clock_decomposable?` itself adds nothing (it reads the already memoized
  # `shard_totals`).
  def serialized_shards
    return nil unless test_run.multi_shard?

    decomposable = test_run.wall_clock_decomposable?

    {
      **shard_scalars,
      coverage: {
        duration_seconds: test_run.timed_shard_count,
        machine_seconds: test_run.timed_shard_count
      },
      rows: decomposable ? serialized_shard_rows : nil,
      balanced_wall_clock_seconds: decomposable ? test_run.balanced_wall_clock_seconds : nil,
      wall_clock_excess_seconds: decomposable ? test_run.wall_clock_excess_seconds : nil,
      # WHEN the three keys above come back — the one input to `#wall_clock_decomposable?` a client
      # cannot reconstruct from anything else in this body.
      #
      # Two of that gate's three conditions are already derivable here: `multi_shard?` is
      # `count > 1` and `!some_shard_untimed?` is `timed_count == count`. So a client reading
      # `rows: null` beside those two can already conclude by elimination that delivery is still
      # settling — WHICH condition failed was never the gap. The gap is WHEN to come back, and the
      # moment is `#last_shard_arrived_at + SHARD_DELIVERY_SETTLING_PERIOD`: one term of it is a
      # column served nowhere, and the other is a constant a client would have to hardcode.
      # Both go out, so the moment is arithmetic over this body rather than a poll on a guess.
      #
      # This is the state EVERY sharded run passes through rather than an edge case:
      # `Repository#latest_test_run` picks a run up the instant its FIRST shard lands, so
      # `latest_run` renders half-delivered runs routinely. The Overview panel has said "we are
      # still waiting" in English since SPGD-192 (`repositories/show.html.erb`, the
      # `#wall_clock_decomposition_pending?` branch); this is the same fact as OPERANDS, on
      # `serialized_history_row`'s rule that a machine-readable client cannot act on a sentence
      # without parsing it. No verdict key and no prose: a client that wants "still settling" has
      # the three conditions and can word it however it likes.
      #
      # PRESENT ON BOTH BRANCHES, valued, on this block's own null-not-absent contract — and here
      # that is stronger than a convention. A key served only under `if decomposable` is invisible
      # to every pin in `spec/requests/api/v1/repository_latest_run_spec.rb`, which is exactly how
      # SPGD-234's three keys shipped named by nothing; a key served only while the gate is CLOSED
      # would reintroduce the same invisibility from the other side. Serving it unconditionally
      # also means a settled run says when it settled, which is a fact a reader wants after the
      # decomposition opens and not only before.
      #
      # `iso8601`, and `null` — never `0`, never an epoch — for a run with no shards at all, which
      # `TestRun#last_shard_arrived_at` documents as its nil case. (`serialized_shards` returns
      # `nil` wholesale below `multi_shard?`, so that nil cannot reach a client through this
      # endpoint today; the safe navigation is what keeps that true if the gate above ever widens.)
      #
      # ZERO ADDED QUERIES. `#last_shard_arrived_at` is `shard_totals[3]`, the `MAX(updated_at)`
      # that already rides along in the single memoized `pick` `count` and `timed_count` above have
      # just taken. That is also why this slice is `latest_run`-only: `ShardCountPreloading` primes
      # `shard_totals[0..2]` and says the shards' `MAX(updated_at)` "is still one `pick` per row",
      # so serving this on the 30-row `history` block is a real N+1 and a different slice.
      last_shard_arrived_at: test_run.last_shard_arrived_at&.iso8601,
      # The other term of that sum, PUBLISHED FROM THE CONSTANT and never typed as a literal, so
      # the panel and this endpoint cannot drift apart about how long settling takes. Seconds, an
      # integer, on the rule every other duration on this endpoint follows — a client adds it to
      # the timestamp above and gets the moment the decomposition becomes available.
      #
      # A configuration fact rather than a measurement, so it is served whether or not this run has
      # a `last_shard_arrived_at` to add it to: a client that reads the two keys together needs
      # both to be present to know it may compute at all.
      settling_period_seconds: TestRun::SHARD_DELIVERY_SETTLING_PERIOD.to_i,
      # The denominator of every duration above, per shard — the block's own STRUCTURED COUNTS,
      # NOT PROSE rule taken one level down. `machine_seconds` says what the run cost and
      # `coverage` says over how many shards; neither says whether the expensive shard was
      # expensive because it held more tests or because its tests cost more each, and the two take
      # opposite actions. `duration = count x cost per test`, so serving both columns lets a client
      # divide and decide — the Overview panel words that division in English, and this endpoint
      # exists so an agent does not have to parse the sentence.
      #
      # Two raw columns and no derived rate, deliberately: a `seconds_per_spec` key would be this
      # block shipping the arithmetic instead of the operands, and it would have to invent an
      # answer for a shard whose `total_specs` is `0` — a real row, since the column is
      # `null: false, default: 0`. A client dividing for itself sees the zero and decides.
      #
      # ADDED BESIDE the keys above, which keep their names, their types and their values, on the
      # rule `shards` itself followed when it was added beside `duration_seconds`.
      #
      # OVERLAPS `rows` ABOVE, and the overlap is the point rather than an oversight. SPGD-234
      # landed `rows` while this slice was in review; both list shards, and every row `rows` serves
      # appears here too with one more column. They are kept apart because they answer under
      # DIFFERENT GATES, and collapsing them would have to sacrifice one of the two:
      #
      #   - `rows` is RANKED and gated on `#wall_clock_decomposable?`. Its contract is
      #     "slowest first", and `duration_seconds: :desc` is NULLS FIRST in Postgres, so it is
      #     `null` whenever a shard reported no timing — the ordering would otherwise put the
      #     silent shard at the head of a list a client reads as the slowest one.
      #   - `per_shard` is UNRANKED delivery order, gated on `multi_shard?` alone. It makes no
      #     claim to rank, so it needs no such gate, and a test COUNT does not depend on a timing:
      #     `Ingest::RunRecorder#upsert_shard` writes `total_specs_count` on every sharded POST
      #     whether or not that shard timed itself.
      #
      # So moving `total_specs` onto `rows` would withhold a count that is perfectly well known on
      # exactly the runs where a reader most wants it — the half-delivered and partly-untimed ones
      # — and dropping `per_shard` in favour of `rows` would do the same. A client that wants the
      # ranking reads `rows`; one that wants a complete census of what each shard reported reads
      # `per_shard` and sorts for itself.
      per_shard: test_run.shard_reports.map do |shard_id, duration_seconds, total_specs|
        {
          # Nullable, and a nil one is an ordinary state rather than an omission —
          # `Ingest::RunRecorder#upsert_shard` records one row per delivery for a client that
          # shards without exposing an index the gem recognises. `null` says the client did not
          # name this slice; a positional index would hand back a name nothing in CI answers to.
          shard_id: shard_id,
          # `null`, never `0.0`, on the same rule the run's own `duration_seconds` follows.
          duration_seconds: duration_seconds,
          total_specs: total_specs
        }
      end
    }
  end

  # THE THREE SHARD SCALARS BOTH DEPTHS SERVE, spelled once — `serialized_shards` above opens with
  # them and `list_shards` is them, so the two depths' `shards` blocks share an opening by
  # construction rather than by discipline. `machine_seconds` is the SUM across the shards and
  # never the MAX, the distinction the whole block exists for: on the canonical 4-shard fixture the
  # MAX understates by 3.4×.
  #
  # `machine_seconds` is `null`, never `0.0`, when not one shard reported a timing — the rule
  # `branch`, `duration_seconds` and `annotated_ratio` already follow on this endpoint. SQL's SUM
  # returns NULL over an empty set rather than zero, and `TestRun#machine_seconds_reported?` is
  # deliberately a `nil?` check for the same reason: a run whose shards genuinely measured 0.0 has
  # a measurement, and serializing "nobody reported" as a measured zero would understate the
  # suite's cost while looking like a fact. The counts prime a real `0`.
  def shard_scalars
    {
      count: test_run.shard_count,
      timed_count: test_run.timed_shard_count,
      machine_seconds: test_run.machine_seconds
    }
  end

  # `#shard_durations` yields `[shard_id, duration_seconds, total_specs_count]` and this names the
  # two halves it serves, because a positional array would make a client index into a tuple whose
  # order it can only learn from prose — and `duration_seconds` is the one every reader sorts on.
  # The third column is deliberately dropped here rather than served: the counts go out on
  # `per_shard`, which is not behind this method's gate. See the reconciliation on `per_shard`.
  #
  # Called only from the gated branch above; it does no gating of its own, so do not call it from
  # anywhere that has not already asked `#wall_clock_decomposable?`.
  def serialized_shard_rows
    test_run.shard_durations.map do |shard_id, duration_seconds|
      { shard_id: shard_id, duration_seconds: duration_seconds }
    end
  end
end
