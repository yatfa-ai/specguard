# frozen_string_literal: true

# The first row SpecGuard stores that is about **a test** rather than about a test *in one run*.
#
# `spec_observations` (SPGD-255) is per-run by construction — keyed `(test_run_id, example_id)`,
# and its own model comment states the boundary: *"the slowest tests in this repository spans runs
# and belongs to the work that settles cross-run identity."* This is that work. Until it exists a
# 20,000-test suite ingests into rows that cannot be related to the same suite's previous run, and
# growth, flakiness, duplicate clusters and overcoverage are all unanswerable.
#
# == Identity is the TEXT, and the text alone
#
# From Project Goals (SPGD-1) and SPGD-114, settled 2026-08-08: a test's identity is **semantic,
# not positional** — the `@intent` triple when there is one, the example's `full_description`
# otherwise, matched across runs by vector similarity. `file_path` / `line_number` are a **last
# known path**, never identity. A moved test is the same test; a renamed unannotated test is a
# different test. It must work at zero annotations.
#
# So this table carries the text (`text`), what supplied it (`signal_source`, from
# `Ingest::SpecSignal`), and its embedding — and the path columns are explicitly the last place the
# test was seen, updated on every match, load-bearing for nothing.
#
# == Why a new table rather than reshaping `spec_intents`
#
# `spec_intents` is attractive at a glance: it already carries `vector(1536)` with an HNSW
# `vector_cosine_ops` index, which is exactly the column and index this needs. It is the wrong home
# anyway, and not marginally:
#
# * Its unique index `index_spec_intents_on_location` is `(repository_id, file_path, line_number)`
#   — **precisely the positional key the settled model forbids**. Keeping it would make a moved
#   test a new test; dropping it leaves the table with no key at all.
# * `entity`, `action` and `behavior` are `NOT NULL`, so it structurally cannot hold a name-only
#   test. The zero-annotation cold start is the case the platform exists for, not an edge.
# * Its name is a claim. A row standing for an unannotated test is not an "intent", and a table
#   whose name says otherwise mis-describes every row in a zero-annotation repository.
#
# Reshaping it would therefore mean dropping its key, dropping three `NOT NULL`s, adding the text
# and digest columns, and renaming the table and the model — which is this migration with extra
# steps and a worse audit trail. `spec_intents` is left exactly as it is: it has no writers, but it
# does have *readers* (`Repository#spec_intents`, the "Searchable intents" figure on
# `repositories/show`, and `spec/jobs/queue_configuration_spec.rb`, which asserts its two indexes
# by name), so removing it is a separate change with its own blast radius and is not this slice's.
#
# == The conflict key: exact text, because similarity is not a constraint
#
# Two ingests of the same suite can both miss and both try to insert the same test — the ordinary
# case on a repository's first sharded run, where every shard is resolving for the first time. There
# is no positional unique key to conflict on here, by design, and Postgres cannot enforce "within
# 0.05 cosine of an existing row": a unique index is an equality, and similarity is not one.
#
# The one thing that IS exact is the text, and it is exact in exactly the case that matters — two
# concurrent misses on the same test are two ingests holding the *same string*. So the key is
# `(repository_id, text_digest)` and the insert is an upsert onto it, which makes the two racers
# converge on one row rather than raise or duplicate. A digest column rather than an index on `text`
# itself because `text` is unbounded and a btree entry over ~2704 bytes is rejected outright — a
# long `full_description` would turn a race into a 500 at the one moment this key exists to survive.
#
# Similarity still decides *matching*; this key only decides who wins a tie on identical text, which
# is the sole case a database-level rule can adjudicate at all.
#
# == `embedding` is `NOT NULL`, and that is a hazard being designed out
#
# `neighbor`'s `nearest_neighbors` scope appends `.where.not(embedding: nil)`. A NULL-embedding row
# is therefore not ranked last — it is **excluded from resolution entirely**, so it can never be
# matched and its test re-inserts as a new identity on every subsequent run, silently and forever.
#
# A row is only ever inserted *after* its embedding has been computed (the vector is what the search
# was run with), so the column can be `NOT NULL` — and then the invisible state cannot exist. The
# unresolved case does not vanish: it moves to `spec_observations.spec_identity_id`, which stays NULL
# when the embedding failed. That is a state nothing hides, because no scope filters on it. Making
# it *identifiable and retryable* is SPGD-72's; not letting it hide in this table is this migration's.
#
# == Retention
#
# `spec_observations` is pruned to `SpecObservation::BRANCH_RETENTION_RUNS` runs per branch. These
# rows are **never pruned** — that is the point of them. A test's identity outlives the window its
# measurements are kept for, so a run landing after a gap still resolves to the row it always had.
class CreateSpecIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :spec_identities do |t|
      t.references :repository, null: false, foreign_key: true

      # The text this test IS, and which of `Ingest::SpecSignal`'s two sources supplied it —
      # `"intent"` or `"name"`. The source travels with the text for the reason SpecSignal states:
      # a name-derived identity is an inference about a test, an intent-derived one is the author's
      # own declaration, and a consumer that cannot tell them apart reports both with the same
      # confidence. `SpecSignal::SOURCES` also has `:none`, which is never stored — a spec with no
      # text has nothing to embed and no identity to have.
      t.text :text, null: false
      t.string :signal_source, null: false
      # SHA-256 hex of `text`. Written by the model, never by hand — see SpecIdentity.digest_for.
      t.string :text_digest, null: false, limit: 64

      # 1536 to match EmbeddingGenerator::DIMENSIONS, which is itself fixed by the HNSW index below.
      # NOT NULL for the reason in the class comment: a NULL here is invisible to resolution.
      t.vector :embedding, limit: 1536, null: false

      # **Last known path, not identity.** Refreshed every time this identity is seen again, so a
      # test that moved ten lines reports where it is now rather than where it first appeared.
      # NOT NULL because an identity is only ever created from a `spec_observations` row, whose own
      # `file_path` and `line_number` are NOT NULL — there is no path by which either is unknown.
      t.string :file_path, null: false
      t.integer :line_number, null: false

      # The run that last observed this test. Nullable and nulled rather than cascaded: the identity
      # is durable and the run is not — runs are destroyed with their repository, and a test does
      # not stop existing because the record of when it was last seen was deleted.
      t.references :last_seen_test_run, null: true,
                                        foreign_key: { to_table: :test_runs, on_delete: :nullify }

      t.timestamps
    end

    # The convergence key — see "The conflict key" above. Named for what it means rather than after
    # the digest column it is implemented with.
    add_index :spec_identities, [:repository_id, :text_digest], unique: true,
              name: "index_spec_identities_on_text"

    # Same access method as `spec_intents`: HNSW with `vector_cosine_ops`, because resolution asks
    # for the nearest neighbour by cosine distance and nothing else. Raw SQL because Rails' index
    # DSL has no way to say `USING hnsw (embedding vector_cosine_ops)`.
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          CREATE INDEX index_spec_identities_on_embedding
            ON spec_identities
            USING hnsw (embedding vector_cosine_ops)
        SQL
      end
      direction.down { execute "DROP INDEX IF EXISTS index_spec_identities_on_embedding" }
    end

    # The link that finally lets per-run measurements be read as one test's history.
    #
    # Nullable, and that nullability is the honest record of an asynchronous pipeline rather than a
    # convenience: the observation is written inside the ingest transaction and resolved afterwards
    # by `Ingest::IdentityResolutionJob`, so between the two there is genuinely no identity to point
    # at. It also stays NULL for an observation whose embedding failed — the one visible trace of
    # the state the `NOT NULL` above refuses to let hide in `spec_identities`.
    add_reference :spec_observations, :spec_identity, null: true,
                  foreign_key: { on_delete: :nullify }

    # The intent triple, at the run grain — the field ingestion has been reading and dropping.
    #
    # `Ingest::Payload` validates `intent` against the OpenTestIntent schema and counts it into
    # `annotated_specs_count`, and then nothing writes it anywhere: `Ingest::ObservationRecorder`
    # never reads `spec["intent"]`. So every cross-run read is forced onto `name` alone, and
    # annotating a test changes nothing about its identity — the exact outcome `Ingest::SpecSignal`
    # exists to prevent.
    #
    # Stored here, at the observation, rather than passed through the job's arguments, for two
    # reasons. A 20,000-example run would put 20,000 spec hashes into `solid_queue_jobs.arguments`
    # as JSON — megabytes of payload per delivery, on the one path whose design point is exactly
    # that size. And a job argument is gone once the job is discarded, whereas a column survives, so
    # a retry (SPGD-72's) re-reads the same input rather than needing the payload replayed.
    #
    # `layer` and `preconditions` are deliberately absent: `SpecSignal::INTENT_PARTS` is
    # entity/action/behavior, because those say what the test is *about* while `layer` classifies it
    # — and a column nothing reads is a column that will be read wrongly later.
    #
    # All three nullable, together: a spec is annotated or it is not, and an unannotated example —
    # the majority of every suite mid-adoption, and all of one at zero annotations — carries none of
    # them. A partial triple never reaches here; the envelope rejects it against the schema, where
    # all three are `required`.
    add_column :spec_observations, :intent_entity, :string
    add_column :spec_observations, :intent_action, :string
    add_column :spec_observations, :intent_behavior, :text
  end
end
