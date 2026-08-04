# Overview & Architecture

## Purpose

SpecGuard is an **autonomous semantic-telemetry and duplicate-prevention** layer for test
suites. It does not run your tests and it does not assert anything about their correctness.
It observes *what each test claims to verify* and helps agents and humans avoid writing tests
that re-verify behavior already covered elsewhere.

It is built first for **AI coding agents** (which generate a large fraction of new tests and
have no memory of existing ones) and second for **human teams** who want a live map of what
their suite actually checks.

## The two questions

SpecGuard exists to answer, fast and cheaply:

1. **Before a test is written** — *"Is the behavior I'm about to test already covered, at any
   layer?"* → `POST /api/v1/check-intent`.
2. **Continuously** — *"Where is this repo's test suite duplicated, saturated, or sparse?"* →
   the web dashboard, fed by `POST /api/v1/ingest`.

Everything else is plumbing for those two answers.

## Concepts

- **Intent** — a structured declaration of *what a test verifies*, attached to the test as a
  comment (the `@intent` annotation). Defined by the [OpenTestIntent Protocol](02-open-test-intent-protocol.md).
- **Entity** — the subject under test, named as a capitalized noun: `Order`, `CheckoutService`,
  `PaymentMethod`. This is the *coarse* grouping key.
- **Action** — the operation or scenario: `checkout`, `apply_discount`, `expire`.
- **Behavior** — a short, natural-language sentence describing the expected outcome: *"returns
  402 payment required on expired card"*.
- **Layer** — the test level: `unit` | `integration` | `request` | `system`. Duplication is most
  common *across* layers (the same behavior tested at unit **and** request **and** system).
- **Annotated ratio** — `% of tests in a run that carry an `@intent`. The primary adoption metric.

## Components

```
                        ┌─────────────────────────────────────────────┐
                        │                SpecGuard (Rails)              │
                        │                                              │
   CI / RSpec run ──────►  POST /api/v1/ingest   ──►  EmbeddingGenerator │
   (specguard-rspec      │        (JSONL)              (OpenAI, async)  │
    formatter)           │                              │               │
                         │                              ▼               │
   AI coding agent ──────►  POST /api/v1/check-intent ► spec_intents     │
   (before writing a     │        (hybrid search)      (pgvector HNSW)   │
    new spec)            │                              │               │
                        │                              ▼               │
   Human ───────────────►  Web dashboard ◄─────────  health metrics    │
   (GitHub OAuth)        └─────────────────────────────────────────────┘
                                    │
                                    ▼
                          PostgreSQL 16 + pgvector
```

Three clients talk to one Rails service backed by a vector-enabled Postgres:

1. **CI (the formatter)** — at the end of an RSpec run, the `specguard-rspec` formatter ships a
   JSONL payload of every spec (annotated or not) to `/ingest`. This is the *telemetry* path.
2. **AI agent (the check)** — before generating a new spec file, the agent calls `/check-intent`
   with the *proposed* intent and gets back any duplicates plus per-layer density. This is the
   *prevention* path.
3. **Human (the dashboard)** — signs in with GitHub, registers a repo, creates an API key, and
   reads repo health.

## Request flows

### Ingestion (telemetry)

```
RSpec run ends
   │
   ▼
specguard-rspec formatter collects all examples
   │  (file_path, line_number, status, optional @intent)
   ▼
POST /api/v1/ingest  (Bearer API key)
   │
   ▼
SpecGuard: create TestRun
   │  for each annotated spec:
   │    EmbeddingGenerator.call("entity action behavior")   ← queued on Solid Queue
   ▼
upsert SpecIntent  (unique on repo + file_path + line_number)
   │  store embedding (1536-dim vector)
   ▼
dashboard metrics recompute
```

Ingestion is **idempotent on `(repository, file_path, line_number)`**: re-running the same commit
updates existing rows rather than creating duplicates (see [Data Model](03-data-model.md)).

### Intent check (prevention)

```
Agent is about to write:  describe Order, "#checkout", "rejects expired card"
   │
   ▼
POST /api/v1/check-intent  { proposed_intent: { entity, action, behavior, layer } }
   │
   ▼
SpecGuard:
   1. embed the proposed behavior  (1536-dim)
   2. filter spec_intents WHERE entity = proposed.entity
   3. rank by cosine similarity (HNSW index)
   4. keep matches with similarity ≥ 0.88
   5. compute per-layer density for that entity
   ▼
Response:  DUPLICATE_FOUND  + similar_intents[] + layer_saturation + recommendation
   │
   ▼
Agent decides: reuse the existing spec, or proceed knowing it's genuinely new
```

The hybrid design — **exact `entity` filter first, then vector similarity within that bucket** —
keeps the vector search honest: it can only surface "same behavior, different layer" matches,
not vaguely-related-but-different-entity false positives.

## Technology stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Ruby on Rails 8 | API-first; minimal Hotwire/Tailwind UI for the dashboard |
| Database | PostgreSQL 16+ | Shared instance is fine; SpecGuard owns its own DB |
| Vector search | `pgvector` + `hnsw` index | Cosine distance; no separate vector DB needed |
| Background jobs | Solid Queue | Embedding generation is async per spec |
| Auth (humans) | OmniAuth + GitHub OAuth | Sign-in only; no passwords stored |
| Auth (CI/agents) | Bearer API keys | Stored as `token_digest`, never plaintext |
| Embeddings | OpenAI `text-embedding-3-small` (1536-dim) | Behind `EmbeddingGenerator`, swappable |
| Client gem | `specguard-rspec` | RSpec formatter + standalone linter |

## Design principles

- **Telemetry, not gatekeeping.** Ingestion never fails a CI run; the linter is the only thing
  that can block, and only on *malformed* annotations — never on missing ones.
- **Cheap to ask, cheap to answer.** `/check-intent` is designed to be called on every spec an
  agent considers writing. The HNSW index + entity pre-filter keep it single-digit-millisecond.
- **One source of truth per intent.** A `(repo, file, line)` has at most one current intent row;
  history is the `test_runs` audit trail, not duplicate `spec_intents`.
- **Layer-aware.** Duplication is defined *across layers*; the data model and queries treat
  `layer` as a first-class axis, not an afterthought.
- **Swappable embeddings.** OpenAI is the default provider, but `EmbeddingGenerator` is an
  interface — a local model or a different vendor can drop in without touching callers.

## Glossary

| Term | Meaning |
|---|---|
| `@intent` | The inline annotation on a test that declares its OpenTestIntent |
| OpenTestIntent | The open annotation standard SpecGuard reads (see protocol doc) |
| SpecIntent | An ActiveRecord row: one declared intent + its embedding |
| TestRun | One CI run's metadata: commit, branch, counts, duration |
| Annotated ratio | `annotated_specs_count / total_specs_count` for a run |
| Layer saturation | Count of intents per layer for a given entity — how "full" each layer is |
| HNSW | Hierarchical Navigable Small World — the approximate-nearest-neighbor index used by pgvector |
