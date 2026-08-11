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

## Migrations

An index on a table ingestion writes to must be built with `algorithm: :concurrently`, which
requires `disable_ddl_transaction!`:

```ruby
class AddSomethingToSpecObservations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :spec_observations, %i[repository_id created_at], algorithm: :concurrently
  end
end
```

A plain `CREATE INDEX` holds a lock that blocks every writer for the whole build, and reads are
unaffected — which is what makes it quiet enough to have slipped through twice. The rule covers
`spec_observations` (20,000 rows per run, one bulk `upsert_all` per ingest) and `test_runs` (one
row per run); an index on a table the same migration creates is exempt, because it has no writers
to block. `spec/migrations/concurrent_index_build_spec.rb` fails the suite when it is missed, and
`lib/spec_guard/migration_index_lint.rb` carries the reasoning and the list of merged migrations
that predate the guard.

It applies however the index is spelled, not just to `add_index`: `t.index` and `t.references`
under `change_table`, `add_reference` (which builds an index by **default** — that is how one
reached `spec_observations` without the word "index" appearing), and raw `CREATE INDEX` in an
`execute`, which is how the vector indexes are built because `add_index` cannot express
`USING hnsw (embedding vector_cosine_ops)`. In raw SQL the spelling is `CREATE INDEX CONCURRENTLY`,
and `disable_ddl_transaction!` is required there too.

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

### GitHub repository access (incremental authorization)

Sign-in asks for `read:user,user:email` and nothing more, so a visitor who only wants to look at a
dashboard never hands over access to their repositories. The broader `repo` scope is requested
lazily, at the moment someone first registers a repository, from the registration page itself —
the same OAuth provider, with the scope overridden on the request phase, and OmniAuth's `origin`
carrying the user back to where they were. `SpecGuard::GithubOauth::SIGN_IN_SCOPE` and
`REPOSITORY_SCOPE` are the two asks.

That token is what closes the squatting gap: registering a repository picks from the list GitHub
says you have, and `GithubOwnership` re-asks GitHub server-side whether you are an **admin** of
the one you picked before the record is created. Every write of `github_full_name` clears that
same gate — registration and rename both — and it fails closed, including when GitHub is
unreachable.

The token is **encrypted at rest** (Active Record Encryption, `users.github_access_token`). Keys
come from ENV, then credentials, then a fallback derived from `secret_key_base`, so a fresh
checkout boots with nothing configured — see `config/initializers/active_record_encryption.rb`,
which documents what rotating `secret_key_base` costs you (nothing but a re-authorization).

```sh
export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=...        # optional; `bin/rails db:encryption:init`
export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=...
export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=...
```

Specs never reach api.github.com either: `spec/support/github_api.rb` installs a deterministic
fake through `GithubApi.factory`, the same public seam production code would swap.

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
