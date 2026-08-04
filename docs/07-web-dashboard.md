# Web Dashboard (Minimal Hotwire UI)

The dashboard is deliberately small. SpecGuard's value is in its **API** (the agent check and the
CI ingestion); the UI exists only to onboard a repo, mint an API key, and read health at a glance.
It is not an admin console and not a test-management tool.

Built on **yatfa's inherited design system** ([see Design System](09-design-system.md)) — Tailwind v4
+ DaisyUI v5 + the `UI::*` ViewComponent library, server-rendered via Hotwire/Turbo, no SPA. Every
surface uses the `app-*` token system and the sanctioned type ramp; the drift lint enforces it. Do
not introduce a separate visual language — if something isn't covered, add a `UI::*` component.

## Authentication

- **GitHub OAuth** via OmniAuth. No passwords are stored; `users` holds only `github_uid`,
  `github_handle`, `email`, `avatar_url`.
- A user can register any GitHub `org/repo` they can prove ownership of (proof strategy TBD in
  Phase 4 — likely a one-time check against the GitHub App or a verify-file in the repo).
- Sessions are cookie-based; sign-out clears the session.

## Screens

### 1. Repositories index (`/`)

- List of the signed-in user's registered repositories.
- Per-repo summary card: annotated ratio, last ingested commit, intent count.
- "Register new repository" flow → enter `org/repo` → create → land on the repo page.

### 2. Repository detail (`/repositories/:id`)

The health dashboard for one repo. This is the main UI surface.

**Header metrics:**

| Metric | Definition |
|---|---|
| Annotated ratio | `annotated_specs_count / total_specs_count` of the latest run, as a percentage |
| Total intents | `spec_intents` count for the repo |
| Latest run | `commit_sha` (short), `branch`, `duration`, timestamp |

**Layer distribution** — a breakdown of intents per layer (`unit` / `integration` / `request` /
`system`), shown as a bar chart. A repo heavily skewed toward one layer (e.g. 90% `unit`, 2%
`system`) is a smell, not necessarily a problem — the chart surfaces it for a human to interpret.

**Entity density (top N)** — the entities with the most intents, sorted descending. This is the
"where is my suite bloated?" answer: a single `Order` entity with 130 intents across all layers is
a duplication candidate worth reviewing. Clicking an entity drills into its intent list with
duplicate scores highlighted.

**Recent runs** — a compact list of the last few `test_runs` with their annotated ratios, so a
human can see adoption trending up or down.

### 3. API keys (`/repositories/:id/api_keys`)

- List existing keys (name, `last_used_at`, created_at). The digest is never shown; the token is
  shown **once** at creation in a copyable box with a "you won't see this again" warning.
- "Create API key" → name it → reveal token once → store it in CI secrets immediately.
- Revoke key → deletes the row (soft or hard, TBD; `last_used_at` makes revocation audits easy).

## What the dashboard explicitly does NOT do

- **No test browsing/editing.** It is not a replacement for your repo. The deepest it goes is a
  read-only list of intents for an entity, with `file_path:line_number` links back to the source.
- **No pass/fail history visualization.** Whether tests passed is not SpecGuard's domain; that's
  your CI's job. We store `duration_seconds` for run health, not per-example results.
- **No alerting.** v1 is read-only observation. Threshold-based alerts ("annotated ratio dropped
  below 50%") are a roadmap item, not a launch feature.

## Metrics derivations (cheat sheet)

All dashboard numbers derive from the two tables — no separate analytics store:

- **Annotated ratio** → `test_runs` latest row: `annotated_specs_count / total_specs_count`.
- **Layer distribution** → `SELECT layer, COUNT(*) FROM spec_intents WHERE repository_id = ? GROUP BY layer`.
- **Entity density** → `SELECT entity, COUNT(*) FROM spec_intents WHERE repository_id = ? GROUP BY entity ORDER BY count DESC LIMIT 10`.
- **Recent runs** → `SELECT * FROM test_runs WHERE repository_id = ? ORDER BY id DESC LIMIT 10`.

These are cheap queries on indexed columns; no materialized views needed for v1.
