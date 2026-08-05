# Development

Phase 1 of SpecGuard: a bootable Rails 8 app carrying the inherited design system, the pgvector
data model, and both auth paths. Ingestion (P2), the duplicate-detection engine (P3) and the
dashboard metrics (P4) build on this.

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
bin/rails db:prepare
bundle exec rspec           # green
bin/dev                     # http://localhost:3000
```

`bin/ci` runs the whole gate: gem audit, importmap audit, the design-system drift lint, the
stylesheet freshness check, and the suite.

## GitHub OAuth (human sign-in)

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
`config/initializers/omniauth.rb`.

Specs never talk to GitHub: `spec/support/omniauth.rb` puts OmniAuth in test mode and drives the
real callback action with a mock identity.

## API keys (CI/agent auth)

Only the SHA-256 digest is ever persisted, so the raw token genuinely cannot be recovered — it
lives in memory for exactly the request that created it and is handed to the view through the
flash. That is what makes the reveal-once UI honest rather than cosmetic.

```sh
curl -H "Authorization: Bearer sgk_..." http://localhost:3000/api/v1/repository
# => {"repository":{...},"api_key":{...}}

curl -H "Authorization: Bearer nope" http://localhost:3000/api/v1/repository
# => 401 {"error":"unauthorized",...}
```

## The design system

Inherited from yatfa wholesale — see the *SpecGuard — Design System* spec. The short version:

- Tokens are `--app-*` custom properties exposed as `app-`prefixed utilities through
  **`@theme inline`** (not plain `@theme`) in `app/assets/tailwind/application.css`. That
  indirection is what lets `[data-theme]` recolour the app at runtime with no rebuild.
- Headings use the 4-step ramp (`text-app-h1`…`h4`) — never raw `text-xl`/`2xl`/`3xl`.
- Buttons are `UI::ButtonComponent` (or `UI::ButtonComponent.classes` for `button_to`) — never
  raw DaisyUI `btn`.
- Panels carry `border-app-panel-border` + `shadow-app`. In dark, `--app-border` is byte-identical
  to `--app-surface-raised`, so a plain 1px border is invisible; the fix is panel-scoped on
  purpose. Do not "fix" the global `--app-border`.
- A new surface gets a new `UI::*` primitive, never a one-off in a view.

### The drift lint

```sh
bin/rails lint:design_system                  # check
bin/rails lint:design_system:update_baseline  # shrink-only; FORCE=1 to accept growth
```

`config/lint/design_system_drift_baseline.yml` is frozen at **0/0/0**. SpecGuard is greenfield —
there is no legacy to grandfather, so any offender is a regression that fails CI.

### Rebuilding the stylesheet

`app/assets/builds/tailwind.css` is **committed**. DaisyUI comes from npm (`@plugin "daisyui"`),
so a clone without Node could not compile CSS — and Propshaft raises on a missing stylesheet,
which would break `bundle exec rspec` on a fresh checkout. Committing the compiled file keeps
setup Node-free.

After changing any view, component or token:

```sh
npm install
bin/rails tailwindcss:build
```

`bin/ci` re-runs that build and fails if the committed file is stale, so it cannot silently
drift. (The check skips itself where npm is unavailable.)

## Data model

Four tables plus the `vector` extension, per the *SpecGuard — Data Model* spec. The load-bearing
constraint is the unique index on `(repository_id, file_path, line_number)`: it is the identity of
a spec intent and the backstop that makes Phase 2's ingestion idempotent. `spec_intents.embedding`
is `vector(1536)` with an HNSW index for cosine similarity, queried through the `neighbor` gem.
