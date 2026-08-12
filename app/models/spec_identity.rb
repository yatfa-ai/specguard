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
# `text` and `embedding` are **immutable** once written. A match refreshes only where the test was
# last seen — `file_path`, `line_number`, `last_seen_test_run_id` — so the thing a history hangs off
# cannot drift out from under it. Those three move FORWARD only: see `SIGHTING_NOT_OLDER` below,
# which is what stops an observation from a run older than the one already named here from reporting
# a last known path that has travelled backwards in time.
#
# One consequence worth stating rather than leaving to be found: a test that *gains* an `@intent`
# changes which text represents it, from its name to its triple, and those are usually far enough
# apart to miss (measured below: 0.86 for a representative pair). It therefore starts a new identity.
# That is the settled model working, not a defect in it — an annotated test is matched by its
# declaration, and until the declaration existed there was nothing to match by.
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

  # @return [true] the text came from a declared `@intent` triple.
  def from_intent? = signal_source == "intent"

  # @return [true] the text was inferred from the example's `full_description`.
  def from_name? = signal_source == "name"

  def location = "#{file_path}:#{line_number}"
end
