# SpecGuard

> Suite intelligence for very large test suites — primarily for AI coding agents.

SpecGuard tells you the truth about a test suite too large for anyone to hold in their head: what
it costs to run, where it is growing, and where it repeats itself. It reads what each test is
called and what it declares it verifies (the optional
[`@intent`](https://github.com/yatfa-ai/open-test-intent) annotation) plus runtime facts from CI,
and turns that into a map an agent can navigate. It does not run your tests and does not gate CI on
missing annotations.

**Status:** early. Ingestion and the dashboard are live; the per-test data model behind most of the
suite-intelligence answers is not built yet — see [what's here](#whats-here) for the line between
the two.

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
