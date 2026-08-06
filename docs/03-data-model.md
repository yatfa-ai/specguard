# Data Model

SpecGuard's schema is deliberately small: four domain tables plus the `vector` extension. The
central object is **`spec_intents`** — one row per declared test intent, carrying its embedding.

## Entity-relationship

```
users 1───* repositories 1───* api_keys
                │
                └── 1───* test_runs
                │            │
                └── 1───* spec_intents *── (optional) test_runs
                             │
                             └─ embedding (vector(1536), HNSW index)
```

- A `user` owns many `repositories` (GitHub OAuth identity).
- A `repository` has many `api_keys` (CI/agent auth) and many `test_runs` + `spec_intents`.
- A `test_run` is one CI run's metadata. A `spec_intent` optionally points at the `test_run` that
  *last observed* it (audit trail), but its true ownership is `(repository, file_path, line_number)`.

## Migration (Rails 8 + pgvector)

The migration is split into two concerns for clarity: enable the extension, then create tables in
dependency order. `enable_extension` is idempotent and safe on any Postgres 16+ with `pgvector`
installed.

```ruby
# db/migrate/20260101000001_create_spec_guard_tables.rb
class CreateSpecGuardTables < ActiveRecord::Migration[8.0]
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
      t.string  :status,   default: "annotated"     # see note below
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
```

### A note on `spec_intents.status`

The column allows `annotated|unannotated`, but only `annotated` rows are ever written: `entity`,
`action`, `behavior` and `layer` are all NOT NULL, and an unannotated test has none of them.
Unannotated tests are counted into `test_runs.total_specs_count` and produce no row here — which
is why the repository-wide annotated ratio reads the latest `TestRun`'s counters rather than
counting rows in this table. Counting rows here would return 100% for every repository, forever.

### Dependencies

- `pgvector` installed on the Postgres cluster (`CREATE EXTENSION vector` needs superuser the
  first time; Rails `enable_extension` handles the `CREATE`).
- The [`neighbor`](https://github.com/ankane/neighbor) Ruby gem — gives ActiveRecord the `t.vector`
  column type and the `.nearest_neighbors` query method used in
  [Duplicate Detection](05-duplicate-detection.md).

## Why these indexes

| Index | Serves |
|---|---|
| `users(github_uid)` unique | OAuth login lookup |
| `repositories(github_full_name)` unique | one SpecGuard repo per GitHub `org/repo` |
| `api_keys(token_digest)` unique | Bearer auth in O(1), constant-time digest compare |
| `spec_intents(entity)` / `(repository, entity, action)` | the **pre-filter** before vector search |
| `spec_intents(repository, file_path, line_number)` unique | **idempotent ingestion** — re-running a commit upserts instead of duplicating |
| `spec_intents` HNSW on `embedding` | the **vector** search itself |

## ActiveRecord models (summary)

```ruby
class User < ApplicationRecord
  has_many :repositories, dependent: :destroy
end

class Repository < ApplicationRecord
  belongs_to :user
  has_many :api_keys,  dependent: :destroy
  has_many :test_runs, dependent: :destroy
  has_many :spec_intents, dependent: :destroy
end

class ApiKey < ApplicationRecord
  belongs_to :repository
  # token_digest only; the raw token is shown once at creation, never stored.
  has_secure_token :token, length: 36   # generates on create; we digest before save
  before_save -> { self.token_digest = Digest::SHA256.hexdigest(token) if token }
end

class TestRun < ApplicationRecord
  belongs_to :repository
  has_many :spec_intents
end

class SpecIntent < ApplicationRecord
  belongs_to :repository
  belongs_to :test_run, optional: true
  # neighbor gem: has_neighbors :embedding
  validates :layer, inclusion: %w[unit integration request system]
end
```

## Lifecycle: ingestion → upsert

Ingestion does **not** blindly insert. For each spec in the payload:

1. Look up `spec_intents` by `(repository_id, file_path, line_number)`.
2. If it exists → update `entity/action/behavior/layer/embedding/test_run_id` in place.
3. If not → insert.

This is what makes re-running the same commit, or re-running CI after a flaky failure, safe: the
intent row is the **current of record** for that test location, not an append-only log. The
append-only history lives in `test_runs` (one row per CI run, with aggregate counts).

## Idempotency and concurrency

- The unique index on `(repository, file_path, line_number)` is the correctness backstop. If two
  ingestion requests race for the same location, the loser hits a unique violation and the service
  retries as an update (or uses `ON CONFLICT … DO UPDATE`).
- Line numbers shift when tests are inserted above; this is acceptable for v1 (a moved test gets
  a fresh intent row, the old one is orphaned and ages out). A future `fingerprint` column
  (hash of surrounding context) is the documented upgrade path.

## Retention

`test_runs` grows unbounded with CI activity. The roadmap includes a retention policy (default:
keep the latest N runs per repo + all runs from `main`). `spec_intents` is *not* truncated — it is
the working set.
