# frozen_string_literal: true

# The whole SpecGuard schema, per the "SpecGuard — Data Model" spec: four domain tables plus the
# `vector` extension. Tables are created in dependency order.
#
# The unique index on (repository_id, file_path, line_number) is the identity of an intent and the
# correctness backstop for idempotent ingestion in Phase 2 — a re-run of the same commit upserts
# rather than duplicating. Get it wrong here and every later phase inherits the bug.
class CreateSpecGuardTables < ActiveRecord::Migration[8.1]
  def up
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :users do |t|
      t.string  :github_uid,    null: false, index: { unique: true }
      t.string  :github_handle, null: false
      t.string  :email
      t.string  :avatar_url
      t.timestamps
    end

    create_table :repositories do |t|
      t.references :user, null: false, foreign_key: true
      t.string :github_full_name, null: false, index: { unique: true } # "org/repo"
      t.string :name,             null: false
      t.timestamps
    end

    create_table :api_keys do |t|
      t.references :repository, null: false, foreign_key: true
      t.string   :token_digest, null: false, index: { unique: true }
      t.string   :name, default: "Default CI Key"
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :test_runs do |t|
      t.references :repository, null: false, foreign_key: true
      t.string  :commit_sha, null: false
      t.string  :branch
      t.integer :total_specs_count,     default: 0
      t.integer :annotated_specs_count, default: 0
      t.float   :duration_seconds
      t.timestamps
    end

    create_table :spec_intents do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :test_run,                  foreign_key: true # nullable: last run that saw it
      t.string  :file_path, null: false
      t.integer :line_number, null: false
      t.string  :entity,   null: false, index: true
      t.string  :action,   null: false, index: true
      t.text    :behavior, null: false
      t.string  :layer,    null: false              # unit|integration|request|system
      t.string  :status,   default: "annotated"     # annotated|unannotated
      t.vector  :embedding, limit: 1536             # OpenAI text-embedding-3-small
      t.timestamps
    end

    # Identity of an intent: a given test location in a repo has exactly one current intent.
    add_index :spec_intents, [:repository_id, :file_path, :line_number], unique: true,
      name: "index_spec_intents_on_location"
    # Fast entity filtering before the vector search narrows within the bucket.
    add_index :spec_intents, [:repository_id, :entity, :action]

    # Approximate nearest-neighbor index for cosine similarity.
    execute <<~SQL
      CREATE INDEX index_spec_intents_on_embedding
        ON spec_intents
        USING hnsw (embedding vector_cosine_ops);
    SQL
  end

  def down
    drop_table :spec_intents
    drop_table :test_runs
    drop_table :api_keys
    drop_table :repositories
    drop_table :users
    # leave the `vector` extension for other potential consumers
  end
end
