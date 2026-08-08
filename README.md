# SpecGuard

> Suite intelligence for very large test suites — primarily for AI coding agents.

SpecGuard is telemetry infrastructure for a test suite too large for anyone to hold in their head.
It does not run your tests and does not gate CI on missing annotations.

**Live today.** Your CI posts each run; SpecGuard records the run's totals and its shards and
answers what the suite costs to run, how much of it SpecGuard can see, and how fast it is growing —
in a dashboard, and at `GET /api/v1/repository` for agents.

**The direction, not yet built.** Reading what each test is called and what it declares it verifies
(the optional [`@intent`](https://github.com/yatfa-ai/open-test-intent) annotation) into a row per
test, and building per-test duration, suite-wide duplicate clustering and refactoring guidance on
top of it — the map an agent navigates. Ingestion stores nothing per test today, so none of those
answers has data behind it and nothing in this repository serves them.

The line between the two, file by file, is in [what's here](#whats-here).

## What's here

The platform: a Ruby on Rails 8 application providing

- `POST /api/v1/ingest` — CI telemetry ingestion (JSONL test-run payloads). Records a run's
  totals and its shards; it does not yet store a row per test,
- `GET /api/v1/repository` — the agent-readable repository summary: the key's repository, the
  latest run's suite size, annotated share and cost, and a bounded history of the runs before it
  ([response shape](docs/DEVELOPMENT.md#get-apiv1repository--the-response-shape)),
- a minimal Hotwire dashboard for repo health and API-key management,
- a PostgreSQL + pgvector data model with HNSW-indexed intent embeddings — migrated and indexed,
  and not yet written by the application.

Per-test duration, suite-wide duplicate clustering and the refactoring guidance built on them are
the product's direction and are **not implemented**; nothing in this repository serves them today.

## Stack

Rails 8 · PostgreSQL 16 + pgvector · Solid Queue · OmniAuth (GitHub) · OpenAI embeddings (swappable)
· **UI inherited from yatfa** — Tailwind v4 + DaisyUI v5 + ViewComponent (`UI::*`) + a drift lint.

## Related repositories

- [`specguard-rspec`](https://github.com/yatfa-ai/specguard-rspec) — client Ruby gem (linter + formatter)
- [`open-test-intent`](https://github.com/yatfa-ai/open-test-intent) — the annotation protocol SpecGuard consumes

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="100%">
  </a>
</p>
