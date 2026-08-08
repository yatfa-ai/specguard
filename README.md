# SpecGuard

> Suite intelligence for very large test suites — primarily for AI coding agents.

SpecGuard is telemetry infrastructure for a test suite too large for anyone to hold in their head.
It does not run your tests and does not gate CI on missing annotations. Your CI posts each run to
`POST /api/v1/ingest`; `GET /api/v1/repository` answers what the suite costs to run and how fast it
is growing, and a Hotwire dashboard renders the same figures.

**This file is bootstrap only, and deliberately stable.** It is not a status page and not an API
reference, and landing a feature should not require editing it. What it does not carry lives in
exactly one place each:

- **What is built, and what is only designed** — the yatfa knowledge base. Start at *Project
  Goals*: it is the repositioned statement of what SpecGuard is for and it wins wherever an older
  article disagrees with it. *Data Model*, *Duplicate-Detection Engine* and *API Reference* (the
  auth model, the ingest envelope, the error shapes) carry the detail. *Overview & Architecture*
  and *Roadmap* are annotated there as superseded — on framing and on the phase plan respectively
  — so read them for history, not for status. Single source: there is no second copy in this
  repository to drift against them.
- **The API contract** — `spec/requests/api/v1/*`. Those request specs pin each response's keys
  exactly, and are reviewed on every change, so they are the live contract rather than a
  description of one.
- **The schema** — `db/schema.rb`.

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
bundle exec rspec           # green
bin/dev                     # http://localhost:3000
```

## The gate

```sh
bin/ci
```

Gem audit, importmap audit, the design-system drift lint, the stylesheet freshness check, and the
suite. `config/ci.rb` is the list.

## Auth

### GitHub OAuth (human sign-in)

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
`config/initializers/omniauth.rb`. Specs never talk to GitHub: `spec/support/omniauth.rb` puts
OmniAuth in test mode and drives the real callback action with a mock identity.

### API keys (CI/agent auth)

Minted per repository in the dashboard and revealed once. Only the SHA-256 digest is ever
persisted, so the raw token genuinely cannot be recovered — it lives in memory for exactly the
request that created it. That is what makes the reveal-once UI honest rather than cosmetic.

```sh
curl -H "Authorization: Bearer sgk_..." http://localhost:3000/api/v1/repository
curl -H "Authorization: Bearer nope"    http://localhost:3000/api/v1/repository   # => 401
```

## The design system and the stylesheet

Inherited from yatfa wholesale — the rules are in the *SpecGuard — Design System* article, and the
drift lint enforces them against a shrink-only baseline
(`config/lint/design_system_drift_baseline.yml`) frozen at **0/0/0**. SpecGuard is greenfield, so
there is no legacy to grandfather and any offender is a regression that fails CI.

```sh
bin/rails lint:design_system                  # check
bin/rails lint:design_system:update_baseline  # shrink-only; FORCE=1 to accept growth
```

`app/assets/builds/tailwind.css` is **committed**. DaisyUI comes from npm (`@plugin "daisyui"`), so
a clone without Node could not compile CSS — and Propshaft raises on a missing stylesheet, which
would break `bundle exec rspec` on a fresh checkout. Committing the compiled file keeps setup
Node-free. After changing any view, component or token:

```sh
npm install
bin/rails tailwindcss:build
```

`bin/ci` re-runs that build and fails if the committed file is stale, so it cannot silently drift.
(The check skips itself where npm is unavailable.)

## Related repositories

- [`specguard-rspec`](https://github.com/yatfa-ai/specguard-rspec) — client Ruby gem (linter + formatter)
- [`open-test-intent`](https://github.com/yatfa-ai/open-test-intent) — the annotation protocol SpecGuard consumes

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="100%">
  </a>
</p>
