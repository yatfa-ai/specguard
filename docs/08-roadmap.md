# Roadmap

Phases 0–5, each independently shippable where dependencies allow. Earlier phases are
prerequisites for later ones (annotated in *Depends on*). Each phase lists **deliverables** and
**acceptance criteria** so an agent (or human) can tell when it's done.

The numbering is a build order, not a document index.

---

## Phase 0 — Repos & scaffolding

**Depends on:** nothing. Establishes the four repositories so all later work has a home.

**Deliverables**
- Four git repositories initialized (see the [repository map](README.md#repository-map)):
  - `specguard` — the Rails platform (holds the master `docs/` spec).
  - `specguard-rspec` — the client Ruby gem.
  - `open-test-intent` — the protocol spec + canonical JSON Schema (the protocol doc moves here from the master spec).
  - `specguard-infra` — Kubernetes manifests, release Jobs, secrets layout.
- Each repo seeded with its `README.md` and a stack-appropriate `.gitignore`.
- The master integration spec (`docs/`) committed to `specguard`.

**Acceptance**
- All four repos exist on GitHub, each with a README that correctly describes its scope.
- The protocol JSON Schema in `open-test-intent` validates against the worked examples in the
  protocol doc.

---

## Phase 1 — Backend base & auth

**Depends on:** nothing.

Bootstrap the Rails app, the database, and both auth paths.

**Deliverables**
- `rails new specguard --css=tailwind` (API + minimal web).
- **Scaffold the inherited design system** (see [Design System](09-design-system.md)): port yatfa's
  `application.tailwind.css` token foundation, the `app/components/ui/*` ViewComponent library +
  `ApplicationComponent`, DaisyUI v5 dark/winter themes, and `SpecGuard::DesignSystemLint` with a
  **shrink-only baseline starting at `0/0/0`**. This is a **Phase 1 gate** — every later UI surface
  builds on it, so it must land before any view.
- Add `pgvector` + the [`neighbor`](https://github.com/ankane/neighbor) gem.
- Run the [schema migration](03-data-model.md).
- OmniAuth GitHub provider: sign in / sign out, `users` table populated.
- `ApiKey` generation: create + digest-store + reveal-once UI; Bearer auth middleware.
- Repository registration flow (UI: create `org/repo` row).

**Acceptance**
- A user can sign in with GitHub, register a repo, and create an API key whose raw token is shown
  exactly once.
- An authenticated `curl` with the Bearer key hits a protected endpoint; a bad key gets `401`.

---

## Phase 2 — Ingestion pipeline

**Depends on:** Phase 1.

Stand up the telemetry path: CI → SpecGuard.

**Deliverables**
- `POST /api/v1/ingest` with Bearer auth + JSON-Schema validation of each `intent`.
- `EmbeddingGenerator` service (OpenAI default, swappable).
- Solid Queue job that embeds each annotated spec and upserts `spec_intents` on
  `(repository, file_path, line_number)`.
- `TestRun` creation with derived counts.
- `202 Accepted` response; ingestion never fails on missing annotations.

**Acceptance**
- POSTing a synthetic run with 2 annotated + 1 unannotated spec creates a `TestRun` with correct
  counts and 2 `spec_intents` rows carrying 1536-dim embeddings.
- POSTing the same payload again updates rows in place (no duplicates) — verifiable by row count
  and the unique location index holding.
- A malformed `intent` returns `400`; a valid run with zero annotations still returns `202`.

---

## Phase 3 — Vector engine & agent API

**Depends on:** Phase 2 (needs embeddings to search against).

Stand up the prevention path: agent → SpecGuard.

**Deliverables**
- `IntentChecker` service: hybrid search (entity filter + cosine ANN), threshold logic.
- `POST /api/v1/check-intent` returning the [documented response shape](04-api-reference.md#post-apiv1check-intent).
- Deterministic embedding stub for the test suite.
- Specs covering: known duplicate (reworded), same-entity different-behavior, different-entity
  near-synonym, layer-saturation reflection.

**Acceptance**
- A known-duplicate pair (behavior reworded) returns `DUPLICATE_FOUND` with score ≥ 0.88.
- A different-entity near-synonym is **not** returned (entity filter holds).
- `layer_saturation` matches the actual per-layer counts for the entity.
- Embedding-provider outage → `503`, not a silent wrong answer.

---

## Phase 4 — Web dashboard (minimal Hotwire)

**Depends on:** Phase 2 (needs data to display).

**Deliverables**
- Repositories index with per-repo summary cards.
- Repository detail page: annotated ratio, layer distribution chart, top-N entity density,
  recent runs.
- API keys management page (create with reveal-once, revoke).

**Acceptance**
- After ingesting a few synthetic runs, the detail page shows correct annotated ratio, layer
  bars, and entity-density list — all matching direct SQL of the same queries.
- An API key can be created and revoked from the UI.
- Every surface uses `UI::*` components and `app-*` tokens; `SpecGuard::DesignSystemLint` passes at
  its `0/0/0` baseline (no ad-hoc headings, raw palette colors, or raw `btn`).

---

## Phase 5 — RSpec gem & linter

**Depends on:** Phases 2–3 (the gem talks to those endpoints). Can start in parallel with Phase 4.

**Deliverables**
- Separate repo `specguard-rspec`.
- `bin/specguard-lint` CLI: discover `@intent:` in changed (or all) `*_spec.rb`, validate against
  the OpenTestIntent JSON Schema, exit `1` on malformed annotations, never fail on missing ones.
- `SpecGuard::RSpecFormatter`: build the run payload from example metadata + source-file annotation
  scan, POST to `/ingest`, fall back to `log/test_results.jsonl` when no API key, never block CI.

**Acceptance**
- Running the linter on a fixture with a truncated `behavior` exits `1` and names the file + reason.
- Running the linter on a clean diff with no annotations exits `0`.
- Wiring the formatter into a sample RSpec project produces a `POST /ingest` that lands as a
  `TestRun` + `spec_intents` in SpecGuard.
- Killing network mid-run does **not** fail the RSpec run (formatter logs and exits silently).

---

## Cross-cutting / later (not numbered)

Items that are real but intentionally out of the initial 5-phase launch:

- **Batch check-intent** (`/check-intents`, plural) to amortize embedding round-trips for agents
  considering many specs.
- **Retention policy** for `test_runs` (latest N per repo + all `main`).
- **`fingerprint` column** on `spec_intents` so moved tests (line shifts) keep their identity.
- **Threshold tuning per repo** — make `DUPLICATE_THRESHOLD` a repository setting, not a constant.
- **Annotated-ratio gate** — optional CI policy that blocks when adoption drops below a floor.
- **Alerting** — notify on annotated-ratio regression or layer-skew spikes.
- **Non-Ruby clients** — `specguard-pytest` etc., enabled by the protocol being language-agnostic.
