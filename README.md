# SpecGuard

> Semantic test telemetry and duplicate-test prevention — primarily for AI coding agents.

SpecGuard reads the declared *intent* of each test (the
[`@intent`](https://github.com/yatfa-ai/open-test-intent) annotation), detects cross-layer behavioral duplication with
pgvector similarity search, and surfaces test-suite density health. It does not run your tests
and does not gate CI on missing annotations.

**Status:** specification + scaffolding stage.

## What's here

The platform: a Ruby on Rails 8 application providing

- `POST /api/v1/ingest` — CI telemetry ingestion (JSONL test-run payloads),
- `POST /api/v1/check-intent` — agent duplicate check (hybrid vector search),
- `GET /api/v1/repository` — the agent-readable repository summary: the key's repository, the
  latest run's suite size, annotated share and cost, and a bounded history of the runs before it
  ([response shape](docs/DEVELOPMENT.md#get-apiv1repository--the-response-shape)),
- a minimal Hotwire dashboard for repo health and API-key management,
- a PostgreSQL + pgvector data model with HNSW-indexed intent embeddings.

## Stack

Rails 8 · PostgreSQL 16 + pgvector · Solid Queue · OmniAuth (GitHub) · OpenAI embeddings (swappable)
· **UI inherited from yatfa** — Tailwind v4 + DaisyUI v5 + ViewComponent (`UI::*`) + a drift lint.

## Related repositories

- [`specguard-rspec`](https://github.com/yatfa-ai/specguard-rspec) — client Ruby gem (linter + formatter)
- [`open-test-intent`](https://github.com/yatfa-ai/open-test-intent) — the annotation protocol SpecGuard consumes

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="620">
  </a>
</p>
