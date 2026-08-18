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

### GitHub repository access (App installation)

Sign-in asks for `read:user,user:email` and nothing more, so a visitor who only wants to look at a
dashboard never hands over anything about their repositories. Connecting repositories is a
separate mechanism entirely: installing the **SpecGuard GitHub App** and choosing repositories in
GitHub's own picker.

That installation is what closes the squatting gap, and it is a stronger proof than the one it
replaced. Only somebody who administers a repository can install an App on it, so a repository
being in your installation *is* GitHub's statement that it is yours to register — there is no
permission field to read. `InstallationRepositories` re-asks GitHub server-side on every write of
`github_full_name` (registration and rename both), and it fails closed, including when GitHub is
unreachable.

This replaced an OAuth `repo` grant — GitHub's "Full control of private repositories", read **and
write**, across everything you and your organizations could reach — which existed only to read one
boolean off `GET /repos/:owner/:repo`. The App asks for **Metadata: read-only** and nothing else.
`Contents: read` is deliberately not requested: nothing here reads repository code, and adding a
permission later forces re-consent on every existing installation.

**Nothing repository-reaching is persisted.** There is no token column and no encryption to
configure. What is stored is one public numeric installation id (`github_installations`); the
credential SpecGuard actually reads GitHub with is an installation access token minted on demand
from the App's private key and discarded within the hour (`GithubAppCredentials`). A database dump
carries no credentials.

Five values identify the App, none of them committed:

```sh
export GITHUB_APP_ID=123456
export GITHUB_APP_SLUG=specguard                # the app's URL name, for the install link
export GITHUB_APP_PRIVATE_KEY="$(cat key.pem)"
export GITHUB_APP_CLIENT_ID=Iv1....             # the App's own OAuth client, for the
export GITHUB_APP_CLIENT_SECRET=...             #   install-time code exchange
```

or under `github_app:` in encrypted credentials. Two settings on the App itself are load-bearing
and cannot be asserted from here: its **Setup URL** must be `<host>/github/installation/callback`,
and **"Request user authorization (OAuth) during installation"** must be on — that is what makes
GitHub send a `code` alongside `installation_id`, and the code is the only thing proving the person
arriving at the setup URL is entitled to the installation they arrived carrying. See
`config/initializers/github_app.rb`.

With none of it set the app still boots and the whole suite still runs: `configured?` reports the
absence and the connect UI explains what is missing rather than bouncing you to a github.com URL
built from placeholders. **Development and test never need a real App** — a developer who wants
connected repositories seeds `GithubInstallation` rows from the console.

Specs never reach api.github.com either: `spec/support/github_api.rb` installs a deterministic
fake through `GithubApi.factory`, the same public seam production code swaps, and no spec needs an
App id, a private key or a minted token.

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

### The annotation schema, downloadable

Every `@intent` this app ingests is validated against OpenTestIntent v1. A deployment serves that
schema for download, unauthenticated, at:

```
GET /schemas/open-test-intent.v1.json
```

It is a **convenience mirror**, byte-identical to the canonical document. The canonical copy — and
the address the schema's own `$id` names — lives in the vendor-neutral `open-test-intent`
repository, pinned to its `schema-v1.0` tag:

```
https://raw.githubusercontent.com/yatfa-ai/open-test-intent/schema-v1.0/schemas/open-test-intent.v1.json
```

`vendor/schemas/open-test-intent.v1.json` is this app's vendored copy of those same bytes, pinned to
the upstream blob hash by `spec/services/open_test_intent_spec.rb` so it cannot drift from its
publisher unnoticed.

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="100%">
  </a>
</p>
