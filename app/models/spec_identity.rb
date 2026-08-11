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
# cannot drift out from under it. One consequence worth stating rather than leaving to be found: a
# test that *gains* an `@intent` changes which text represents it, from its name to its triple, and
# those are usually far enough apart to miss (measured below: 0.86 for a representative pair). It
# therefore starts a new identity. That is the settled model working, not a defect in it — an
# annotated test is matched by its declaration, and until the declaration existed there was nothing
# to match by.
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
  # observations the same test". The two must never share a constant, and this one must sit
  # *strictly above* the duplicate threshold — a pair the duplicate engine is meant to report as two
  # redundant tests has to resolve to **two** identities. A matching threshold at or below 0.88
  # would silently merge exactly the pairs that product surface exists to show, destroying the
  # finding and welding two histories together at the same time.
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
