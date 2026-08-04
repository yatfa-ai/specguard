# SpecGuard Engine — Documentation

SpecGuard is a standalone platform for **semantic test telemetry and duplicate-test
prevention**. It reads the declared *intent* of each test (the `@intent` annotation),
detects cross-layer behavioral duplication with vector search, and surfaces test-density
health — primarily for AI coding agents, but useful for any team that wants its test
suite to stay coherent as it scales.

The companion client standard is the **OpenTestIntent** protocol: a tiny, language-agnostic
annotation that every test can carry.

---

## What problem does this solve?

AI coding agents (and busy humans) tend to **add** tests but rarely **consolidate** them. Over
time a single behavior — e.g. *"checkout is rejected when the card is expired"* — gets covered
independently at the unit, request, and system layers, by different authors who didn't know the
others existed. The suite grows, slows down, and starts to lie: a "coverage" number goes up while
real understanding of what is tested goes down.

SpecGuard answers two questions, cheaply and before duplication lands:

1. **"Is this behavior already tested?"** — asked by an agent *before* it writes a new spec.
2. **"Where is my test suite bloated or thin?"** — asked by a human looking at a repo dashboard.

---

## Documents

| # | Document | What it covers |
|---|----------|----------------|
| — | [Overview & Architecture](01-overview.md) | Purpose, components, stack, request flows, glossary |
| 1 | [OpenTestIntent Protocol](02-open-test-intent-protocol.md) | The `@intent` annotation standard + JSON Schema |
| 2 | [Data Model](03-data-model.md) | Schema, pgvector migration, indexes, model relationships |
| 3 | [API Reference](04-api-reference.md) | Auth, `POST /ingest`, `POST /check-intent`, errors |
| 4 | [Duplicate-Detection Engine](05-duplicate-detection.md) | Embeddings, hybrid search, similarity threshold |
| 5 | [Client Gem (`specguard-rspec`)](06-client-gem.md) | Linter, RSpec formatter, CI wiring |
| 6 | [Web Dashboard](07-web-dashboard.md) | Minimal Hotwire UI scope and metrics |
| 7 | [Roadmap](08-roadmap.md) | Phased implementation plan with acceptance criteria |
| 8 | [Design System (inherited from yatfa)](09-design-system.md) | Tokens, components, layout, drift lint — inherited wholesale, not redesigned |

---

## Repository layout

SpecGuard is split across **four repositories** under the `specguard-full/` workspace. The split
keeps the platform, the client, the open protocol, and the infrastructure independently versioned
and independently visible.

```
specguard-full/                 # workspace (not itself a repo — holds the 4 checkouts)
├── docs/                       # master integration spec ← you are here (cross-repo)
├── specguard/                  # repo 1 — Rails platform (API + dashboard + pgvector)
├── specguard-rspec/            # repo 2 — client Ruby gem (linter + RSpec formatter)
├── open-test-intent/             # repo 3 — the open annotation protocol + JSON Schema
└── specguard-infra/            # repo 4 — Kubernetes manifests, deploy, release wiring
```

### Repository map

| Repo | Owns |
|---|---|
| [`specguard`](https://github.com/yatfa-ai/specguard) | The platform: API (`/ingest`, `/check-intent`), Hotwire dashboard, data model, vector engine. Holds the master `docs/`. |
| [`specguard-rspec`](https://github.com/yatfa-ai/specguard-rspec) | Client Ruby gem: `specguard-lint` CLI + `SpecGuard::RSpecFormatter`. Published to RubyGems. |
| [`open-test-intent`](https://github.com/yatfa-ai/open-test-intent) | The vendor-neutral annotation standard + canonical JSON Schema. Not SpecGuard-specific. |
| [`specguard-infra`](https://github.com/yatfa-ai/specguard-infra) | Deploy: k8s manifests, release Jobs, secrets layout. Mirrors the yatfa-infra pattern. |

> **GitHub org / namespace is TBD** before the repos go public. The docs reference repos by name
> only, not by org prefix, so the choice doesn't ripple through the spec.

---

## Dogfooding: built with yatfa

SpecGuard is itself a **yatfa** project. The human-authored seed — this `docs/` tree and the four
repo skeletons (READMEs only) — is the entire handoff. **Every commit after the seed is authored
by yatfa agents**, executing the [roadmap](08-roadmap.md) phase by phase.

This is the marketing case: a complete product — platform, client library, open protocol,
infrastructure — shipped by autonomous agents from a spec. If that's interesting, the git history
of every repo above is the evidence.

---

## At a glance

- **Stack:** Ruby on Rails 8 (API + minimal Hotwire UI), PostgreSQL 16 + `pgvector`, Solid Queue.
- **UI:** yatfa's design system inherited wholesale — Tailwind v4 + DaisyUI v5 + ViewComponent
  (`UI::*`) + a drift lint. See [Design System](09-design-system.md).
- **Auth:** GitHub OAuth (OmniAuth) for humans; hashed Bearer API keys for CI/agents.
- **Embeddings:** OpenAI `text-embedding-3-small` (1536-dim) behind a swappable interface.
- **Core primitive:** one row in `spec_intents` per declared test intent, with its embedding.
- **Core query:** hybrid search = exact `entity` match **filtered by** cosine vector similarity.
