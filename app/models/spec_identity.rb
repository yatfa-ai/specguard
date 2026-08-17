# frozen_string_literal: true

require "digest"

# One test, across every run that ever observed it. The durable half of test identity; the run-local
# half is {SpecObservation}, which points here.
#
# A row is created the first time a repository ingests a test whose text nothing already matches,
# and is *found again* on every subsequent run by embedding that run's text and asking for the
# nearest neighbour. It is never created positionally and never keyed positionally — see the
# migration (`db/migrate/20260811120000_create_spec_identities.rb`) for why this table exists rather
# than a reshaped `spec_intents`, and why `embedding` is `NOT NULL`.
#
# == What a match is, and what it is not
#
#   identity = repository.spec_identities
#                        .nearest_neighbors(:embedding, vector, distance: "cosine",
#                                           threshold: MATCH_DISTANCE)
#                        .first
#
# `text` and `embedding` move on exactly one transition and are otherwise **immutable**. A match
# refreshes only where the test was last seen — `file_path`, `line_number`, `last_seen_test_run_id`
# — so the thing a history hangs off cannot drift out from under it. Those three move FORWARD only:
# see `SIGHTING_NOT_OLDER` below, which is what stops an observation from a run older than the one
# already named here from reporting a last known path that has travelled backwards in time.
#
# The transition is a test GAINING an `@intent`. Which text represents it changes from its name to
# its triple, and the two are usually far enough apart to miss (measured below: 0.86 for a
# representative pair, and 0.8614 even for a triple that strictly contains the whole name) — so
# nothing similarity can do finds the row again. `Ingest::IdentityResolver#upgrade_from_name` moves
# the row onto the declaration instead, in place and keeping its id, because a test that acquired a
# declaration is the test it already was and its history is the same history. It is the only writer
# of these columns after the insert, it goes one way only — never intent→name, which would let an
# ordinary rename masquerade as a de-annotation — and it is deliberately NOT in `RESIGHTABLE`: an
# ordinary re-sighting still moves nothing but where the test was seen.
class SpecIdentity < ApplicationRecord
  # Which of {Ingest::SpecSignal}'s sources supplied `text`. `SpecSignal::SOURCES` also carries
  # `:none`; it is absent here on purpose — a spec with no text has nothing to embed, so no row is
  # ever written for one and a `:none` value would describe a state this table cannot reach.
  SOURCES = %w[intent name].freeze

  # **The matching threshold: two texts are the same test at cosine ≥ 0.95.**
  #
  # This is the *matching* threshold and it is explicitly **not** the duplicate-detection threshold
  # (0.88 / 0.75, SpecGuard — Duplicate-Detection Engine). Same embedding, opposite questions: that
  # one asks "are these two tests redundant with each other", this one asks "are these two
  # observations the same test". The two must never share a constant, and this one sits *strictly
  # above* the duplicate threshold, so a pair that merely *reads* alike — the 0.88–0.95 band —
  # resolves to **two** identities while still being reportable as two redundant tests. A matching
  # threshold at or below 0.88 would silently merge exactly the pairs that product surface exists to
  # show, destroying the finding and welding two histories together at the same time.
  #
  # == Where that separation stops, which is not a threshold question
  #
  # It buys nothing against *exact* duplicates — and those are the ones the shipped surface actually
  # reports. `SpecObservation.repeated_descriptions_in` (SPGD-344) groups on `name`, so what it
  # shows is examples sharing a `full_description` **verbatim**: a table-driven loop, a shared
  # example group, the same description in two files. Identical text embeds to an identical vector,
  # so `Ingest::IdentityResolver#nearest` matches them at cosine 1.0 whatever this number is; and if
  # it somehow missed, the `(repository_id, text_digest)` conflict key is an equality on that same
  # text and lands them on one row anyway. Both mechanisms agree, and they agree on **one** identity
  # for two tests.
  #
  # No threshold can separate them, because under this model there is nothing to separate them BY:
  # identity is the text and only the text, and their text is the same. So a run's two observations
  # point at one row, its last known path is whichever of the two the resolver reached last, and
  # that row's history interleaves two tests' measurements. That is the settled model reaching its
  # edge, not a defect in this constant — but it is a real property of these rows, and whoever
  # builds clustering on them (SPGD-114 slice 4) needs it stated rather than discovered. Both halves
  # are demonstrated against real rows in `spec/services/ingest/identity_resolver_spec.rb` rather
  # than asserted about the constant here.
  #
  # == What the number is derived from
  #
  # The behaviour this slice exists for does not depend on the threshold at all: a test that moved
  # ten lines has *identical* text, `EmbeddingGenerator::LocalProvider` is a pure function of that
  # text, and neither path nor line number is a feature of it — so the move scores exactly 1.0. The
  # threshold's whole job is to bound how far from identical a match may be.
  #
  # Measured on the shipped provider (`ruby -r./app/services/embedding_generator -e` over
  # representative pairs; re-derivable in seconds, which is why the pairs are named rather than the
  # numbers merely asserted):
  #
  #   same text, differing only in whitespace/punctuation   1.00   ← must match
  #   a corrected typo                                      0.95
  #   one word appended to the description                  0.94
  #   singular → plural                                     0.89
  #   a lexically similar but DIFFERENT test                0.80   ← must not match
  #   the same behaviour reworded                           0.62   ← must not match (a rename)
  #   a sibling example in the same file                    0.41
  #   an unrelated rename of the same test                  0.29
  #
  # 0.95 admits the first band and refuses everything from 0.89 down, which is where "a different
  # test" starts. It errs deliberately: a threshold set too low merges two tests permanently and
  # corrupts both histories, while one set too high starts a new history for a trivially edited test
  # — which is what the settled model prescribes for a rename anyway. The failure modes are not
  # symmetric, so the threshold is not centred.
  #
  # == Why hash collisions do not move it
  #
  # SPGD-252 measured `LocalProvider` over a full census of all 199,990,000 pairs of 20,000 real
  # RSpec example names from one repository (discourse@`f3c568c`), comparing the shipped 1536-bucket
  # vector against the same features in a collision-free unbounded space. Mean |hashed − exact|
  # cosine error **0.0196**; the largest overstatement anywhere in the census **+0.274**; at cosine
  # ≥ 0.88, **119** false matches (1 in 1.68 million) — and **zero** of them, at every threshold
  # from 0.75 to 0.95, involved a pair the collision-free algorithm scores as unrelated. Every false
  # match was a near-miss nudged across the line, never an invented resemblance. Hashing is not what
  # decides this number; the bands above are.
  MATCH_SIMILARITY = 0.95

  # What `nearest_neighbors(threshold:)` wants, which is a cosine *distance* — `1 - similarity`.
  # Derived rather than written as 0.05 so the two can never disagree.
  MATCH_DISTANCE = 1 - MATCH_SIMILARITY

  # Everything a re-observation may move: where the test was last seen, and nothing else. `text`,
  # `text_digest`, `signal_source` and `embedding` are absent because they are the identity itself;
  # `created_at` is absent so a row keeps when the test first appeared.
  #
  # The four excluded columns have exactly two writers after the insert and neither of them is a
  # re-sighting. `Ingest::IdentityResolver#upgrade_from_name` moves all four, on the single
  # transition where a test acquires a declaration; `Ingest::IdentityResolver#refresh` moves `text`,
  # `text_digest` and `embedding`, on the single transition where a description drifts into a
  # spelling this repository's provider cannot tell apart from the stored one — the row is already
  # matched at cosine 1.0 and re-sighted, and moving its spelling is what stops that match costing
  # an embed and an index lookup on every ingest forever.
  #
  # Adding them here to serve either case would make EVERY ordinary re-observation start rewriting
  # `text` — the exclusion is what makes an identity stable, so each transition that moves it says
  # so itself, by id, in its own guarded statement, rather than being folded into this list.
  RESIGHTABLE = %i[file_path line_number last_seen_test_run_id updated_at].freeze

  # **A sighting may never move a row BACKWARDS in time**, and this is the one place that is
  # decided — for both of the two paths that re-sight a row rather than inside either of them.
  #
  # == Why this is an invariant of the table and not an ordering discipline
  #
  # "Last known path" is last-writer-wins: `file_path`, `line_number` and `last_seen_test_run_id`
  # move together, so whichever observation is written LAST has the final word. That is correct
  # within one run — two examples sharing a description genuinely have no order between them, which
  # `MATCH_SIMILARITY` above records — and it is wrong the moment the writers span runs, because
  # then one of them IS older and the row would end up naming a run that another run has already
  # superseded.
  #
  # {Ingest::IdentityResolver}'s cross-run sweep made that reachable in the ordinary case: it
  # resolves rows of EARLIER runs alongside this one's, so a single pass holds observations from
  # several runs of the same test. Ordering the pass chronologically is the obvious answer and it
  # does not survive contact — the sweep's other axis, fairness, wants a key (`embed_failure_count`)
  # that is inversely correlated with age, and one iteration order cannot serve both. So the
  # ordering stopped being the mechanism and this became it: any order at all is now safe, because
  # a write that would move the row backwards simply does not happen.
  #
  # == What "older" means
  #
  # `(created_at, id)`, which is the ordering every recency question in this application is asked
  # in — `Repository#latest_test_run`, `#recent_test_runs` and `#previous_test_run_on_branch` all
  # sort by exactly this pair, and the last of them explains at length why both halves are needed:
  # `created_at` alone mis-orders a same-instant pair and `id` alone can disagree with the clock,
  # since ids are assigned at INSERT and `created_at` in Ruby before it. A row-value comparison, so
  # the tie-break is the same one the panels use rather than a second definition of "newer".
  #
  # Two PK probes of a small table per re-sighting. Against the embedding and the ANN lookup this
  # loop already does per row, that is not the cost worth economising on, and the alternative —
  # holding both runs in Ruby — is a query per observation at the 20,000-example design point.
  #
  # `NULL` passes: a row that has never been sighted has no sighting to be older than. So does a
  # `last_seen_test_run_id` whose run has been deleted (the FK nullifies rather than cascades, and
  # a `NOT EXISTS` over the missing row is true) — with nothing to compare against, the sighting in
  # hand is the best-known answer and lands.
  SIGHTING_NOT_OLDER = <<~SQL.squish
    (spec_identities.last_seen_test_run_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM test_runs seen, test_runs sighted
       WHERE seen.id = spec_identities.last_seen_test_run_id
         AND sighted.id = %<sighted_run>s
         AND (seen.created_at, seen.id) > (sighted.created_at, sighted.id)))
  SQL

  private_constant :SIGHTING_NOT_OLDER

  # The alias the batched match path gives the `VALUES` list it joins against, and therefore the
  # name the guard below reads the sighting run out of. Public, and a constant rather than a letter
  # written twice, because two places have to agree on it: {Ingest::IdentityResolver#resight_all}
  # spells `AS v (…)` and this spells `v.last_seen_test_run_id`, and a guard that named a table
  # alias nobody defined would be a syntax error at best and a silently different join at worst.
  SIGHTING_VALUES_ALIAS = "v"

  # The guard as a WHERE clause, for the match path — {Ingest::IdentityResolver#resight_all}, which
  # re-sights a WHOLE PAGE in one statement and therefore has no single run id to bind: each row of
  # its `VALUES` list carries its own, and the guard reads it off that row exactly as
  # `RESIGHT_ON_CONFLICT` below reads its own off `excluded`.
  #
  # It replaced a `?`-bound spelling of the same clause, which existed only while that path issued
  # one `UPDATE` per observation. Two instantiations rather than three, and — either way — **never a
  # second spelling of the guard**: `SIGHTING_NOT_OLDER` is `private_constant`, so a caller cannot
  # format it itself, and relaxing that so it could is precisely how a copy of this predicate would
  # enter the tree. That is the whole reason the guard lives here for both paths rather than inside
  # either of them.
  #
  # Per row and deliberately not hoisted out of the statement: it compares each identity against the
  # sighting proposed FOR THAT identity, so a page whose rows resolve to different identities gets
  # one verdict per row and not one for the page.
  #
  # A guard that fails means the UPDATE matches that row not at all, which is the whole point: the
  # identity is left exactly as it was, `updated_at` included, because nothing about it changed. The
  # caller still links its observation to the row — being older than the last sighting does not make
  # an observation any less an observation OF this test.
  #
  # No binds, so this returns raw SQL rather than a sanitized fragment: the only value it
  # interpolates is the alias above, which is a constant of this class.
  def self.sighting_not_older_than_values
    format(SIGHTING_NOT_OLDER, sighted_run: "#{SIGHTING_VALUES_ALIAS}.last_seen_test_run_id")
  end

  # The same guard as an `ON CONFLICT DO UPDATE SET` clause, for the insert path —
  # {Ingest::IdentityResolver#claim_identity}, where the losing side of an upsert race lands its
  # sighting on the winner. That path's own comment calls itself "an ordinary re-sighting", and an
  # invariant that held on one of the two ways to re-sight a row would not be an invariant.
  #
  # It is reachable outside a race, too: `#nearest` is an approximate index lookup, so an
  # under-recalled miss on text that already HAS an identity arrives here rather than at `#resight`
  # — and the row it lands on may well have been sighted by a newer run than the one that missed.
  #
  # Built FROM `RESIGHTABLE` rather than beside it, so this clause and the `#resight` UPDATE move
  # the same columns for the same reason that constant exists: two hand-written lists are two
  # definitions of what a re-sighting is. Postgres reads an unqualified `excluded.x` as the row
  # proposed for insert and `spec_identities.x` as the row already there, so a column whose guard
  # fails is set to the value it already holds — a no-op write rather than a skipped one, which is
  # what keeps this a single statement.
  #
  # The four `CASE`s share one verdict even though each evaluates the predicate separately: every
  # `SET` expression in one statement reads the row as it was BEFORE the update, so the guard on
  # `last_seen_test_run_id` — which the predicate itself reads — cannot see a value another clause
  # of the same statement has already moved. The four columns land together or not at all, which is
  # what makes this the same atomic re-sighting `#resight` performs.
  RESIGHT_ON_CONFLICT = RESIGHTABLE.map do |column|
    "#{column} = CASE WHEN #{format(SIGHTING_NOT_OLDER, sighted_run: 'excluded.last_seen_test_run_id')} " \
      "THEN excluded.#{column} ELSE spec_identities.#{column} END"
  end.join(", ").freeze

  # What one `<=>` actually costs the planner, and the reason `.near_duplicate_pairs_in` sets it.
  #
  # **Necessary, and on its own not sufficient** — it is one of the two corrections that together
  # get the HNSW index chosen; the other is the literal tenant bind argued at
  # `.near_duplicate_pairs_in`, which carries the 2×2 measurement showing each is load-bearing.
  # Read that table before touching either: with the corrected price alone the read still takes
  # 66.6s on the sort plan, which is why a sweep of this value over four orders of magnitude was
  # observed to leave the plan unmoved at every setting.
  #
  # The planner is not being stupid; it is being told a false price. `cpu_operator_cost` defaults to
  # 0.0025 — "the cost of processing one operator or function call" — calibrated so that 1.0 is one
  # sequential page read, and it is charged once per `<=>`. But `<=>` on this column is 1,536
  # multiply-accumulates and two square roots, not one comparison. Under the default the sort path's
  # 3,000 distance calls are priced at 7.5 while the HNSW descent's own overhead is priced honestly,
  # so the wrong plan wins on paper and loses by an order of magnitude in practice.
  #
  # So the statement states the real price: the default, times the number of dimensions the operator
  # actually walks. **Derived from `EmbeddingGenerator::DIMENSIONS`** rather than written as 3.84, so
  # a future change of embedding width re-prices the operator instead of leaving a stale literal
  # behind. It is a correction to an input, not a thumb on the scale — every plan the planner
  # compares is re-priced by the same true fact, and the sort path loses because it really does call
  # the operator three thousand times more often. That "not a thumb on the scale" is also why it
  # cannot work alone: an honest price applied to a dishonest row count is still a wrong answer, and
  # re-pricing both paths equally cannot flip a comparison. Correcting the count is what makes the
  # correction bite.
  #
  # == What this is NOT
  #
  # Not `hnsw.ef_search`, not `hnsw.iterative_scan`, and not a recall decision of any kind. Those
  # decide how HARD the index looks and are handed to **SPGD-72** by name at {Ingest::IdentityResolver#nearest};
  # nothing here touches them, and this setting changes only WHICH plan is chosen, never what a
  # chosen plan returns. Left alone, the recall question stays exactly where that method put it.
  #
  # Not `enable_sort = off` or any other `enable_*` switch either, and deliberately. Those assert
  # that the planner is wrong; these two corrections assert that it was misinformed, and then inform
  # it. The distinction is not stylistic: a disabled node stays disabled for every relation in the
  # statement — including the outer `ORDER BY`, which has no index to fall back on — and it keeps
  # forcing the index long after the repository has shrunk to a size where scanning really is
  # cheaper. A corrected price and a corrected count leave the planner free to make that call, and
  # on a small tenant it correctly still declines the index.
  VECTOR_OPERATOR_COST = 0.0025 * EmbeddingGenerator::DIMENSIONS

  belongs_to :repository
  # The run that last observed this test. Optional because the FK nulls rather than cascades.
  belongs_to :last_seen_test_run, class_name: "TestRun", optional: true

  # Nullified rather than cascaded: an observation is a measurement that happened, and it did not
  # stop happening because the identity it resolved to was removed.
  has_many :spec_observations, dependent: :nullify

  # Gives `.nearest_neighbors(:embedding, …)`. Its scope hard-filters `.where.not(embedding: nil)`,
  # which is why the column is `NOT NULL` — see the migration.
  has_neighbors :embedding

  validates :text, :text_digest, :file_path, :line_number, :embedding, presence: true
  validates :signal_source, inclusion: { in: SOURCES }
  validates :text_digest, uniqueness: { scope: :repository_id }

  # SHA-256 hex of the text, and the only place that mapping is defined. The unique index is on this
  # rather than on `text` because `text` is unbounded and a btree entry over ~2704 bytes is rejected
  # outright — a long `full_description` would turn the race this key exists to survive into a 500.
  def self.digest_for(text) = Digest::SHA256.hexdigest(text.to_s)

  # Every pair of tests in ONE repository whose texts read alike enough to be worth a human's
  # attention — each row an EDGE, together with what the seed end weighed in ONE run, in examples
  # and wall clock. {NearDuplicateClusters} owns the threshold, the neighbour cap, the run and the
  # grouping; this method owns only the statement, which is the sibling arrangement
  # `SpecObservation`'s grouped reads and `RepeatedDescriptions` already use.
  #
  # == Why this is one statement and not `nearest_neighbors` in a loop
  #
  # {Ingest::IdentityResolver#nearest} is the call shape for ONE probe vector, and `neighbor`'s
  # scope can only ever be that: it builds an `ORDER BY embedding <=> $1` around a vector handed in
  # from Ruby. Asking it for every identity in a repository is one round trip per test — 20,000 of
  # them at the design point, per page view — which is the shape SPGD-369 rules out by name. A
  # `LATERAL` join asks the same question of every row inside a single statement, so the round trips
  # are constant in the size of the suite while the work per row stays capped at `neighbours`. The
  # operator and the distance convention are `neighbor`'s own (`<=>` is pgvector cosine distance,
  # `1 - similarity`), so the two reads cannot disagree about what a cosine means.
  #
  # **Never all-pairs.** 20,000 identities is 199,990,000 pairs — the exact census SPGD-252
  # measured, and it took a forked 16-worker sweep to get through a corpus a *tenth* that size. The
  # inner `ORDER BY … LIMIT` is what the HNSW index answers, so each row costs an approximate
  # descent rather than a scan of its siblings.
  #
  # == The two filters inside the LATERAL, and why neither is a `WHERE` outside it
  #
  # `signal_source` partitions the search rather than filtering its result. An intent-derived text
  # is a joined triple (`"{entity} {action} {behavior}"`) and a name-derived one is human prose;
  # {Ingest::SpecSignal} is explicit that *"they are not the same evidence"*, and a cosine taken
  # across the two genres compares vocabulary conventions as much as content. Partitioning inside
  # the subquery means a name-derived test's ten candidates are ten *name-derived* candidates —
  # filtering afterwards would spend the cap on rows that can never qualify and quietly under-report
  # the smaller partition.
  #
  # ⭐ `repository_id` is the tenant boundary, and it is bound as a LITERAL — `n.repository_id = ?`,
  # the same repository the outer `WHERE` already pins — rather than correlated as
  # `n.repository_id = a.repository_id`. Similarity does not get to cross tenants here for the same
  # reason it does not in `#nearest`; the two spellings say that identically, and were verified to
  # return byte-identical result sets. The correlated one reads better and is the one to reach for.
  # **It was measured to cost the plan**, so the worse-reading spelling is the one that ships, and
  # the reason is written down here because a later reader will otherwise "tidy" it back.
  #
  # A correlated `n.repository_id = a.repository_id` hides the VALUE from the planner. Inside a
  # LATERAL it cannot know which tenant `a` will hand over — equivalence-class propagation does not
  # cross the subquery boundary, so the outer `a.repository_id = 7` never reaches the inner scan —
  # and it falls back to `1/ndistinct(repository_id)`. On a table of 13,200 identities across 122
  # repositories that estimates **113 sibling rows against an actual 2,999**: a 26× underestimate,
  # which is what makes sorting the siblings look cheaper than descending the index. Bound as a
  # literal, the planner reads that one value's own statistics and estimates 3,142 — and chooses
  # the index.
  #
  # ⭐ This and {VECTOR_OPERATOR_COST} are each necessary and neither is sufficient. Measured on the
  # identical statement over identical rows, 3,000 identities in the target tenant:
  #
  #   correlated tenant + default price ....... sort plan, 64.8s
  #   correlated tenant + corrected price ..... sort plan, 66.6s
  #   literal tenant    + default price ....... sort plan, 65.8s
  #   literal tenant    + corrected price ..... HNSW,       5.7s
  #
  # The bottom two rows are why a cost sweep alone can never fix this, and the diagonal is why
  # either fix alone reads as a failure: a price is only meaningful multiplied by a count, and the
  # count was wrong by 26×. Raising the price while the count stays wrong re-prices the HNSW path
  # by the same factor, so the comparison never flips however far it is pushed. Correcting the
  # count while the price stays wrong leaves 2,999 cosine distances valued at 7.5 in total, which
  # is still cheaper on paper than any index descent. Only both together make the planner's
  # arithmetic match the machine's.
  #
  # == The weight join, which is the whole point of the read
  #
  # `(repository_id, text_digest)` is UNIQUE (db/schema.rb), so **every exact duplicate in a suite
  # is already collapsed onto one identity row before this statement runs** — see the "Where that
  # separation stops" section above, which hands exactly this consequence to this slice. A
  # three-example table-driven loop sharing one description is ONE row here. Counting identity rows
  # would therefore report a suite's most-repeated tests as its least-repeated ones.
  #
  # So the seed's weight is re-expanded through `spec_observations.spec_identity_id` — served by
  # `index_spec_observations_on_spec_identity_id` — into the examples that actually resolved to it
  # and the wall clock they actually cost. **Do not "simplify" this join away**: without it the
  # object is blind to precisely the duplicates the shipped `RepeatedDescriptions` panel reports.
  #
  # == ⭐ And the weight join is scoped to ONE run, which the `<=>` above deliberately is not
  #
  # The two halves of this statement have two different grains ON PURPOSE, and the asymmetry is the
  # correction rather than an inconsistency. WHICH texts read alike is a question about the
  # repository — an identity outlives the run that observed it, which is what makes suite-wide
  # clustering reachable here and nowhere else. HOW MUCH those texts weigh is a question about a
  # suite, and a suite is a run.
  #
  # Unscoped, this subquery counts one row per *(test × every run it was ever observed in)*, so
  # every figure it feeds grows with how often the repository has ingested rather than with what its
  # suite contains. The same three-example loop reports 3 after one ingest and 30 after ten, and the
  # ranking one rung up — cumulative wall clock — would order clusters by *(per-run cost × runs
  # ingested)*, so a cheap cluster outranks an expensive one once it has enough history behind it.
  # A number that is only correct on a repository that ingested exactly once is not a number this
  # object may print.
  #
  # It is also the convention of the table being joined. Every aggregate on {SpecObservation} takes
  # a `test_run` or a list of run ids, and its single exemption, `.directory_growth_between`, states
  # why it is allowed to span runs: it *"pairs none"* — it counts each run's rows separately and
  # subtracts two integers. Pooling several runs' rows into one `COUNT(*)` and one `SUM` is neither
  # the convention nor the exemption, and `example_count` already means "examples in a run"
  # everywhere else in this model.
  #
  # A member the run never observed therefore weighs 0 rather than being dropped: a test that was
  # deleted, renamed, or simply not selected still keeps its identity row, and it is still part of
  # the group that reads alike. {NearDuplicateClusters::Cluster#unobserved_members?} is where that
  # is said out loud.
  #
  # Only the SEED end of each edge carries weight, and that is sufficient rather than a gap: cosine
  # is symmetric, so an identity close enough to be someone's neighbour is itself a seed with at
  # least one qualifying neighbour of its own, and therefore appears in this result with its own
  # weight row. `LEFT JOIN … ON TRUE` because the aggregate subquery yields one row unconditionally
  # — an identity the run did not observe comes back as `0` examples, which is a fact about that
  # run rather than a row to drop.
  #
  # == What a missed neighbour costs here, which is not what it costs on ingest
  #
  # `#nearest` explains at length that HNSW applies `repository_id` *after* the index scan, so a
  # small tenant's true nearest neighbour can fall outside the `hnsw.ef_search` candidates. There it
  # splits a history in two. Here it merely under-reports a cluster: a group of four presented as a
  # group of three, on a panel that is already explicit about presenting rather than concluding.
  # Different exposure, same measurement — and that measurement is **SPGD-72's**, not this read's.
  #
  # == The plan is corrected, not forced, and it takes both corrections
  #
  # Postgres will not choose the HNSW index for this shape on its own. It is wrong about two
  # separate things at once: it prices `<=>` as one ordinary operator call, and inside the LATERAL
  # it cannot see which tenant it is counting, so it estimates 113 siblings where there are 2,999.
  # Believing that fetching a repository's every identity and sorting them by distance is cheap, it
  # does exactly that — the all-pairs join this read exists to avoid, measured at 64.8s against
  # 5.7s for the same rows. {VECTOR_OPERATOR_COST} corrects the price and the literal tenant bind
  # corrects the count; the 2×2 measurement showing that neither alone moves the plan is in the
  # filters section above, and the price's own argument is at the constant.
  #
  # @param neighbours [Integer] the per-row cap, `k`. Bounded work per row is what makes the
  #   statement's cost linear rather than quadratic; the cost is that an identity with more than `k`
  #   near neighbours has some of its edges dropped. {NearDuplicateClusters} counts the rows that
  #   hit the cap and says so rather than letting the truncation pass for a finding.
  # @param similarity [Float] cosine floor, inclusive. Converted to the `<=>` distance here so the
  #   comparison lands in SQL rather than being re-derived in Ruby over every returned row.
  # @param run_id [Integer, nil] the run the WEIGHT columns are measured in — never the clustering,
  #   which spans runs. `nil` is a repository that has ingested nothing yet: `o.test_run_id = NULL`
  #   is unknown for every row, so every identity comes back at 0 examples, which is the honest
  #   weight of a suite nobody has reported.
  # @return [Array<Array>] `[id, text, signal_source, file_path, line_number, example_count,
  #   total_seconds, timed_count, neighbour_id, similarity]` per edge. `total_seconds` is nil for an
  #   identity none of whose examples in that run were timed, and `example_count` is 0 for one the
  #   run did not observe.
  def self.near_duplicate_pairs_in(repository, similarity:, neighbours:, run_id:)
    sql = sanitize_sql_array([ <<~SQL, repository.id, neighbours, run_id, repository.id, 1 - similarity ])
      SELECT a.id, a.text, a.signal_source, a.file_path, a.line_number,
             w.example_count, w.total_seconds, w.timed_count,
             b.neighbour_id, 1 - b.distance AS similarity
      FROM spec_identities a
      CROSS JOIN LATERAL (
        SELECT n.id AS neighbour_id, n.embedding <=> a.embedding AS distance
        FROM spec_identities n
        WHERE n.repository_id = ?
          AND n.signal_source = a.signal_source
          AND n.id <> a.id
        ORDER BY n.embedding <=> a.embedding
        LIMIT ?
      ) b
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS example_count,
               SUM(o.duration_seconds) AS total_seconds,
               COUNT(o.duration_seconds) AS timed_count
        FROM spec_observations o
        WHERE o.spec_identity_id = a.id
          AND o.test_run_id = ?
      ) w ON TRUE
      WHERE a.repository_id = ?
        AND b.distance <= ?
      ORDER BY a.id, b.distance, b.neighbour_id
    SQL

    # A transaction of its own, because the corrected price is transaction-scoped and outside one
    # Postgres would discard it — the read would silently revert to the plan that takes 69 seconds.
    # Read-only, so it costs a BEGIN/COMMIT pair and nothing else.
    #
    # == And the price is restored, because the scope is narrower than it looks
    #
    # `SET LOCAL` binds to the TRANSACTION, not to the block that issued it, and
    # `ActiveRecord::Base.transaction` JOINS an ambient transaction rather than opening its own. So
    # a caller that wraps this read in a transaction of theirs would carry `cpu_operator_cost = 3.84`
    # into every statement they ran afterwards — re-pricing queries that have no 1536-dimension
    # operator anywhere in them, from a method they called for its return value. `requires_new:` is
    # not the fix either: a savepoint is not a new transaction as far as a GUC is concerned.
    #
    # So the previous value is read first and put back after, through `set_config(…, true)` — the
    # function spelling of `SET LOCAL`, which takes the value as a bind instead of as string
    # interpolation and does not warn when there is no transaction to be local to. The restore is on
    # the success path only, and that is sufficient rather than an oversight: a statement that
    # raised has aborted the transaction, and an aborted transaction can only be rolled back, which
    # discards the setting outright.
    previous_cost = connection.select_value("SHOW cpu_operator_cost")

    transaction do
      set_operator_cost(VECTOR_OPERATOR_COST)
      rows = connection.select_all(sql).cast_values
      set_operator_cost(previous_cost)
      rows
    end
  end

  # `SET LOCAL` as a function call, so the value binds instead of interpolating.
  def self.set_operator_cost(value)
    connection.execute(sanitize_sql_array([ "SELECT set_config('cpu_operator_cost', ?, true)", value.to_s ]))
  end
  private_class_method :set_operator_cost

  # How many identities this repository holds, and how they split across the two signal sources —
  # the denominator every coverage figure {NearDuplicateClusters} states is a fraction OF.
  #
  # A second round trip, and it has to be. The pair read above returns only identities that HAVE a
  # near neighbour, so no window over it could ever count the ones that do not — and "no test in
  # this suite reads like another" and "this suite has three tests in it" produce the identical
  # empty list. Verbatim the argument `.description_presence_in` gives for its own extra read.
  #
  # Split by source because the partition is real: a repository that is 4,000 name-derived
  # identities and 12 intent-derived ones has two populations of very different confidence, and a
  # single "12 of 4,012 clustered" hides which of the two was searched.
  #
  # @return [Hash{Symbol=>Integer}] `identity_count`, `intent_count`, `name_count`.
  def self.clusterable_population_in(repository)
    counts = where(repository_id: repository.id).pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(*) FILTER (WHERE signal_source = 'intent')"),
      Arel.sql("COUNT(*) FILTER (WHERE signal_source = 'name')")
    )

    { identity_count: counts[0].to_i, intent_count: counts[1].to_i, name_count: counts[2].to_i }
  end

  # @return [true] the text came from a declared `@intent` triple.
  def from_intent? = signal_source == "intent"

  # @return [true] the text was inferred from the example's `full_description`.
  def from_name? = signal_source == "name"

  def location = "#{file_path}:#{line_number}"
end
