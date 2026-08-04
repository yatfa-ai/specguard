# SpecGuard

> Semantic test telemetry and duplicate-test prevention — primarily for AI coding agents.

SpecGuard reads the declared *intent* of each test (the
[`@intent`](https://github.com/yatfa-ai/open-test-intent) annotation), detects cross-layer behavioral duplication with
pgvector similarity search, and surfaces test-suite density health. It does not run your tests
and does not gate CI on missing annotations.

**Status:** specification + scaffolding stage. Built entirely by yatfa agents from the
[master spec](docs) — see the dogfooding note there.

## What's here

The platform: a Ruby on Rails 8 application providing

- `POST /api/v1/ingest` — CI telemetry ingestion (JSONL test-run payloads),
- `POST /api/v1/check-intent` — agent duplicate check (hybrid vector search),
- a minimal Hotwire dashboard for repo health and API-key management,
- a PostgreSQL + pgvector data model with HNSW-indexed intent embeddings.

This repo also holds the **master integration spec** under `docs/` (architecture, data model,
API, engine, roadmap) shared across all SpecGuard repositories.

## Stack

Rails 8 · PostgreSQL 16 + pgvector · Solid Queue · OmniAuth (GitHub) · OpenAI embeddings (swappable)
· **UI inherited from yatfa** — Tailwind v4 + DaisyUI v5 + ViewComponent (`UI::*`) + a drift lint
(see [`docs/09-design-system.md`](docs/09-design-system.md)).

## Related repositories

- [`specguard-rspec`](https://github.com/yatfa-ai/specguard-rspec) — client Ruby gem (linter + formatter)
- [`open-test-intent`](https://github.com/yatfa-ai/open-test-intent) — the annotation protocol SpecGuard consumes
- [`specguard-infra`](https://github.com/yatfa-ai/specguard-infra) — deployment

## Documentation

Full design docs live in [`docs/`](docs). Start at [`docs/README.md`](docs/README.md).
