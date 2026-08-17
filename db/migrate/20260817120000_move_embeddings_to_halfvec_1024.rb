# frozen_string_literal: true

# Moves every embedding column from `vector(1536)` to `halfvec(1024)`.
#
# ## Why 1024, and why halfvec
#
# 1024 is `voyageai/voyage-4-lite`'s native width — the only provider this application ships after
# this migration (see `EmbeddingGenerator`). No truncation, no `dimensions` parameter: the vendor
# returns exactly this many floats.
#
# `halfvec` is pgvector's 2-byte float. It halves what every vector costs on disk and, more to the
# point, in the page cache this deployment shares with everything else on the box: 20,000 identities
# — the scale this product is built for, in ONE repository — is ~41MB of vectors at
# `halfvec(1024)` against ~123MB at `vector(1536)`. The HNSW graph is walked in the same 2-byte
# format, so the index reads half the bytes per hop as well.
#
# ⚠️ pgvector's HNSW index caps `vector` at 2000 dimensions and `halfvec` at 4000, so this choice
# also leaves room above 1024 that the previous column type did not have above 1536.
#
# ## This DROPS every stored vector, and that is the only thing it can do
#
# There is no cast from a 1536-element vector to a 1024-element one: the numbers are not a
# truncation of each other, they are a different function of the text. So the columns are dropped
# and re-added rather than altered, which discards:
#
#   * `spec_identities` — every row, because `embedding` is `NOT NULL` and a row cannot exist
#     without one. Identities are re-derived from the next ingest of each repository.
#   * `spec_intents.embedding` — nulled; the rows themselves survive, since the column is optional
#     and everything else on an intent is still true.
#   * `embedding_cache_entries` — every row. It is a cache; the entries were written under an
#     `openai:` fingerprint that nothing will ask for again.
#
# `up` is written to be safe on a populated database anyway (it states what it destroys and does it
# in one transaction), but it was run against an empty production table — 0 identities, 0 intents,
# 0 cache entries — which is why the destruction is acceptable rather than merely survivable. Doing
# this later would mean a re-embed of every row in the product.
#
# `down` restores the column TYPES so the schema can be rolled back. It cannot restore the vectors,
# and `spec_identities` is empty after either direction for the same NOT NULL reason.
class MoveEmbeddingsToHalfvec1024 < ActiveRecord::Migration[8.0]
  DIMENSIONS = 1024

  def up
    change_embeddings(to: :halfvec, limit: DIMENSIONS, opclass: :halfvec_cosine_ops)
  end

  def down
    change_embeddings(to: :vector, limit: 1536, opclass: :vector_cosine_ops)
  end

  private

  # Dropping the column takes its indexes with it, so the HNSW indexes are re-created by hand rather
  # than left to survive a type they no longer describe.
  def change_embeddings(to:, limit:, opclass:)
    # NOT NULL and no default: there is no vector to give the existing rows, so they cannot stay.
    execute "DELETE FROM spec_identities"
    execute "DELETE FROM embedding_cache_entries"

    remove_column :spec_identities, :embedding
    remove_column :spec_intents, :embedding
    remove_column :embedding_cache_entries, :embedding

    add_column :spec_identities, :embedding, to, limit: limit, null: false
    add_column :spec_intents, :embedding, to, limit: limit
    add_column :embedding_cache_entries, :embedding, to, limit: limit, null: false

    add_index :spec_identities, :embedding, using: :hnsw, opclass: opclass,
                                            name: "index_spec_identities_on_embedding"
    add_index :spec_intents, :embedding, using: :hnsw, opclass: opclass,
                                         name: "index_spec_intents_on_embedding"
  end
end
