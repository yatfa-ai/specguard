# Development

Phase 1 of SpecGuard: a bootable Rails 8 app carrying the inherited design system, the pgvector
data model, and both auth paths. Ingestion (P2), the duplicate-detection engine (P3) and the
dashboard metrics (P4) build on this.

## Requirements

| Thing | Version | Notes |
|---|---|---|
| Ruby | see `.ruby-version` | |
| PostgreSQL | 16+ | **with `pgvector` installed** — the schema does `enable_extension "vector"` |
| Node | 20+ | *only* to rebuild the stylesheet (DaisyUI is an npm package). Not needed to boot or test. |

Installing pgvector:

```sh
# Debian/Ubuntu
sudo apt-get install postgresql-17-pgvector
# macOS
brew install pgvector
# Docker
docker run -e POSTGRES_PASSWORD=postgres -p 5432:5432 pgvector/pgvector:pg17
```

## Setup

```sh
bin/setup --skip-server     # bundle, db:prepare, clear logs
bin/rails db:prepare
bundle exec rspec           # green
bin/dev                     # http://localhost:3000
```

`bin/ci` runs the whole gate: gem audit, importmap audit, the design-system drift lint, the
stylesheet freshness check, and the suite.

## GitHub OAuth (human sign-in)

The client id/secret are secrets and are **not** committed. Register an OAuth app at
<https://github.com/settings/developers> with the callback URL
`http://localhost:3000/auth/github/callback`, then either export env vars:

```sh
export GITHUB_CLIENT_ID=...
export GITHUB_CLIENT_SECRET=...
```

or put them in encrypted credentials (`bin/rails credentials:edit`):

```yml
github:
  client_id: ...
  client_secret: ...
```

With neither set the app still boots and the whole suite still runs — the provider is mounted with
a placeholder, and the sign-in panel says so rather than dead-ending you. See
`config/initializers/omniauth.rb`.

Specs never talk to GitHub: `spec/support/omniauth.rb` puts OmniAuth in test mode and drives the
real callback action with a mock identity.

## API keys (CI/agent auth)

Only the SHA-256 digest is ever persisted, so the raw token genuinely cannot be recovered — it
lives in memory for exactly the request that created it and is handed to the view through the
flash. That is what makes the reveal-once UI honest rather than cosmetic.

```sh
curl -H "Authorization: Bearer sgk_..." http://localhost:3000/api/v1/repository
# => {"repository":{...},"api_key":{...},"latest_run":{...},"history_window":{...},"history":[...]}

curl -H "Authorization: Bearer nope" http://localhost:3000/api/v1/repository
# => 401 {"error":"unauthorized",...}
```

### `GET /api/v1/repository` — the response shape

The agent-readable half of the repository page: which repository the key resolves to, what the
suite looked like the last time CI reported, and the bounded tail of what it looked like before
that. Every figure is read off the same rows `repositories#show` renders from
(`Repository#latest_test_run` and `#recent_test_runs`, which share an ordering tie-break included),
so the API and the dashboard cannot name different commits for the same repository.

```json
{
  "repository": {
    "id": 12,
    "full_name": "acme/billing-service",
    "name": "billing-service",
    "registered_at": "2026-07-01T09:14:22Z"
  },
  "api_key": {
    "name": "ci",
    "last_used_at": "2026-08-07T11:02:00Z"
  },
  "latest_run": {
    "commit_sha": "a1b2c3d4e5f6",
    "branch": "main",
    "total_specs": 20000,
    "annotated_specs": 5000,
    "annotated_ratio": 0.25,
    "duration_seconds": 74.25,
    "shards": {
      "count": 4,
      "timed_count": 4,
      "machine_seconds": 253.75,
      "coverage": { "duration_seconds": 4, "machine_seconds": 4 }
    },
    "ingested_at": "2026-08-07T11:01:58Z"
  },
  "history_window": {
    "order": "ingested_at_desc,ingest_sequence_desc",
    "tie_break_served": false,
    "branch_scope": "all_branches",
    "limit": 10,
    "returned": 2
  },
  "history": [
    {
      "commit_sha": "a1b2c3d4e5f6",
      "branch": "main",
      "total_specs": 20000,
      "annotated_specs": 5000,
      "annotated_ratio": 0.25,
      "duration_seconds": 74.25,
      "shard_count": 4,
      "suite_size_measured": true,
      "ingested_at": "2026-08-07T11:01:58Z"
    },
    {
      "commit_sha": "9f8e7d6c5b4a",
      "branch": "spike/extract-billing",
      "total_specs": 400,
      "annotated_specs": 116,
      "annotated_ratio": 0.29,
      "duration_seconds": 11.5,
      "shard_count": 0,
      "suite_size_measured": true,
      "ingested_at": "2026-08-07T10:44:03Z"
    }
  ]
}
```

**`null` is never a stand-in for a measurement.** Everything nullable below distinguishes "not
reported" from a real zero, because a client cannot tell them apart after the fact:

| Field | `null` means |
| --- | --- |
| `api_key.last_used_at` | the key has never authenticated a request |
| `latest_run` | **CI has never reported for this repository** — not a zeroed block. A repo whose CI never ran must not serialize byte-identically to one that ran and found an empty suite. |
| `latest_run.branch` | the client did not say. `POST /api/v1/ingest` accepts a body without it. |
| `latest_run.duration_seconds` | no wall clock was reported. `0.0` would assert the run took no time. |
| `latest_run.annotated_ratio` | the run reported **zero tests**, so there is no share to take. The counts are still present, so a client can compute its own. |
| `latest_run.shards` | the run was assembled from **one shard or none** — the entire unsharded corpus. There is no composition to disambiguate: one shard's MAX *is* its SUM. The key is always present. |
| `latest_run.shards.machine_seconds` | not one shard reported a timing. `0.0` would assert the suite was free. |
| `history[].branch` / `.duration_seconds` / `.annotated_ratio` | exactly what the same-named `latest_run` field means. A history row is the same row `latest_run` serializes, minus the per-shard cost figures. |

**`history` is the one exception, and it is a list rather than a block.** It is `[]` — never
`null` — for a repository whose CI has never reported. The rule above exists because a zeroed
*block* asserts measurements nobody took: a `latest_run` of zeros claims a run happened and found
nothing. An empty *list* asserts nothing of the kind — "no runs" is exactly what zero rows means,
and it is the same answer you get after filtering a populated history down to a branch that never
ran. Nulling it would force every consumer to handle two spellings of the empty case before it
could iterate. `latest_run` stays `null` in that same response; the two are consistent, not in
conflict.

`annotated_ratio` is the **0–1 fraction**, the same unit `POST /api/v1/ingest` answers with — never
the 0–100 percentage `TestRun#annotated_ratio` renders for the dashboard. The 100× gap between the
two is invisible in a JSON body.

#### The two cost figures, and what each was measured over

A sharded suite delivers itself over N requests and `Ingest::RunRecorder` folds all of them onto
one run, recomputing the counts as the SUM of the shards and `duration_seconds` as the **MAX**.
That MAX is correct — shards run concurrently, so the slowest one is the run's wall clock — but it
is not what the suite *cost*. Four shards of 61.0s, 58.5s, 74.25s and 60.0s are a 74.25s wait and
253.75s of machine time, a 3.4× gap that widens with every shard added.

- `duration_seconds` — the **wall clock**, MAX over the shards. Unchanged in key, type and value
  from before the `shards` block existed.
- `shards.machine_seconds` — what the suite **cost**, SUM over the shards.
- `shards.count` — how many shard rows the run was assembled from. A count of *recorded shards*,
  not of distinct CI jobs: the unique index on `(test_run_id, shard_id)` is partial
  (`WHERE shard_id IS NOT NULL`), so a client that shards without exposing an index the gem
  recognises gets one row per delivery.
- `shards.timed_count` — how many of those reported a duration. Shard durations are nullable and
  ingest accepts a shard without one, so a silent shard is an ordinary state.
- `shards.coverage` — **how many shards each cost figure was computed over**, keyed by the figure's
  own JSON name. `coverage.duration_seconds` is the MAX's denominator, `coverage.machine_seconds`
  the SUM's, and `count` is what the run has. When they differ, the SUM is a *floor* and the MAX is
  a maximum over a subset — which may well have excluded the slowest shard, since a cancelled or
  timed-out job usually is. Counts rather than the dashboard's prose ("slowest of the 3 that
  reported") so a client can divide rather than parse English.

The dashboard's Overview panel renders the same two figures under coverage-stating labels; this
block is how a client reconstructs those labels for itself.

#### `history` — how the suite grew, without differencing two polls

Without it, the only way to learn that the suite grew is to call this endpoint twice and subtract
one `total_specs` from the next — which is exactly the subtraction `TestRun` spends eighteen lines
of its own documentation forbidding, because two runs are only comparable under conditions a poll
cannot see. `history` serves the rows themselves, plus the facts that decide whether any two of
them may be differenced at all.

**`history` is not a series.** `history_window.branch_scope` is `all_branches`, and it means what
it says: these are the repository's runs interleaved across every branch CI reports from, so
`history[0]` and `history[1]` are routinely two different branches and the difference between their
`total_specs` is **not** a change in the suite. The dashboard's Recent-runs panel carries that same
warning as a caption under its heading; a machine client has no caption, so the fact is structural
here — every row carries its own `branch`, and a client that wants a series filters on it first.

Before differencing two rows, check both:

- `suite_size_measured` — `false` when the run reported **zero tests**. It has a count but not a
  measurement, and a difference taken against it describes the report rather than the suite.
- `shard_count` — how many shards the row was assembled from. A run's `total_specs` is the SUM over
  the shards recorded *so far*, so differencing an in-flight sharded run against a complete one
  reports a deletion no commit made. Equal counts is the same rule `TestRun#assembled_like?`
  applies on the dashboard.

Deliberately **not** a `shards` sub-block like `latest_run` carries. The preload that makes this
window cheap primes the shard *count* alone, so per-shard cost figures on ten rows would be ten
extra queries — and `assembled_like?` reads the count, not the costs. The full cost figures stay on
`latest_run`, which is one row.

`history_window` is the contract, as tokens rather than prose:

| Field | Meaning |
| --- | --- |
| `order` | `"ingested_at_desc,ingest_sequence_desc"` — **both** keys. Rows are ordered by ingest time descending, ties broken by ingest sequence descending. |
| `tie_break_served` | `false`. The second ordering key is **not** a field on a row, so the ordering is not reproducible from what you hold — see below. |
| `branch_scope` | `"all_branches"`. The array was never filtered to one branch. |
| `limit` | The bound, currently `10`. |
| `returned` | How many rows this response actually carries. |

**Read the array in the order it arrived.** Two runs ingested in the same instant carry the same
`ingested_at`, and the key that orders them — the ingest sequence — is not served on a row, here or
on `latest_run`. So a client that re-sorts on `ingested_at` alone scrambles exactly those pairs and
can end up disagreeing with `latest_run` about which commit is newest. `history[0]` is the same row
as `latest_run` **always**, including the same-instant case; re-sorting is the one way to break
that.

`limit` is a bound, not a page: ten rows is ten rows whether the suite holds three tests or twenty
thousand, and there is no cursor to continue. `returned == limit` is how you learn the suite has
run at least ten times and this is the tail — the inference you would otherwise draw wrongly from a
full array.

## The design system

Inherited from yatfa wholesale — see the *SpecGuard — Design System* spec. The short version:

- Tokens are `--app-*` custom properties exposed as `app-`prefixed utilities through
  **`@theme inline`** (not plain `@theme`) in `app/assets/tailwind/application.css`. That
  indirection is what lets `[data-theme]` recolour the app at runtime with no rebuild.
- Headings use the 4-step ramp (`text-app-h1`…`h4`) — never raw `text-xl`/`2xl`/`3xl`.
- Buttons are `UI::ButtonComponent` (or `UI::ButtonComponent.classes` for `button_to`) — never
  raw DaisyUI `btn`.
- Panels carry `border-app-panel-border` + `shadow-app`. In dark, `--app-border` is byte-identical
  to `--app-surface-raised`, so a plain 1px border is invisible; the fix is panel-scoped on
  purpose. Do not "fix" the global `--app-border`.
- A new surface gets a new `UI::*` primitive, never a one-off in a view.

### The drift lint

```sh
bin/rails lint:design_system                  # check
bin/rails lint:design_system:update_baseline  # shrink-only; FORCE=1 to accept growth
```

`config/lint/design_system_drift_baseline.yml` is frozen at **0/0/0**. SpecGuard is greenfield —
there is no legacy to grandfather, so any offender is a regression that fails CI.

### Rebuilding the stylesheet

`app/assets/builds/tailwind.css` is **committed**. DaisyUI comes from npm (`@plugin "daisyui"`),
so a clone without Node could not compile CSS — and Propshaft raises on a missing stylesheet,
which would break `bundle exec rspec` on a fresh checkout. Committing the compiled file keeps
setup Node-free.

After changing any view, component or token:

```sh
npm install
bin/rails tailwindcss:build
```

`bin/ci` re-runs that build and fails if the committed file is stale, so it cannot silently
drift. (The check skips itself where npm is unavailable.)

## Data model

Four tables plus the `vector` extension, per the *SpecGuard — Data Model* spec. The load-bearing
constraint is the unique index on `(repository_id, file_path, line_number)`: it is the identity of
a spec intent and the backstop that makes Phase 2's ingestion idempotent. `spec_intents.embedding`
is `vector(1536)` with an HNSW index for cosine similarity, queried through the `neighbor` gem.
