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
# => {"repository":{...},"api_key":{...},"latest_run":{...},"history_window":{...},"history":[...],"branches_window":{...},"branches":[...]}

curl -H "Authorization: Bearer nope" http://localhost:3000/api/v1/repository
# => 401 {"error":"unauthorized",...}
```

### `GET /api/v1/repository` — the response shape

The agent-readable half of the repository page: which repository the key resolves to, what the
suite looked like the last time CI reported, and the bounded tail of what it looked like before
that. Every figure is read off the same rows `repositories#show` renders from
(`Repository#latest_test_run` and `#recent_test_runs`, which share an ordering tie-break included),
so the API and the dashboard cannot name different commits for the same repository.

Takes one optional query parameter, `?branch=`, which narrows `history` — and only `history` — to a
single branch. The names you may put in it are served in
[`branches`](#branches--which-names-branch-may-take), which is why they are two blocks and not one.
See [`history`](#history--how-the-suite-grew-without-differencing-two-polls) below. The body shown
here is the response with **no** parameter.

```json
{
  "repository": {
    "id": 12,
    "full_name": "acme/billing-service",
    "name": "billing-service",
    "registered_at": "2026-07-01T09:14:22Z"
  },
  "api_key": {
    "name": "ci",
    "last_used_at": "2026-08-07T11:02:00Z"
  },
  "latest_run": {
    "commit_sha": "a1b2c3d4e5f6",
    "branch": "main",
    "total_specs": 20000,
    "annotated_specs": 5000,
    "annotated_ratio": 0.25,
    "duration_seconds": 74.25,
    "shards": {
      "count": 4,
      "timed_count": 4,
      "machine_seconds": 253.75,
      "coverage": { "duration_seconds": 4, "machine_seconds": 4 },
      "rows": [
        { "shard_id": "3", "duration_seconds": 74.25 },
        { "shard_id": "1", "duration_seconds": 61.0 },
        { "shard_id": "4", "duration_seconds": 60.0 },
        { "shard_id": "2", "duration_seconds": 58.5 }
      ],
      "balanced_wall_clock_seconds": 63.4375,
      "wall_clock_excess_seconds": 10.8125,
      "per_shard": [
        { "shard_id": "1", "duration_seconds": 61.0, "total_specs": 5000 },
        { "shard_id": "2", "duration_seconds": 58.5, "total_specs": 5000 },
        { "shard_id": "3", "duration_seconds": 74.25, "total_specs": 5000 },
        { "shard_id": "4", "duration_seconds": 60.0, "total_specs": 5000 }
      ]
    },
    "ingested_at": "2026-08-07T11:01:58Z"
  },
  "history_window": {
    "order": "ingested_at_desc,ingest_sequence_desc",
    "tie_break_served": false,
    "branch_scope": "all_branches",
    "branch": null,
    "limit": 10,
    "returned": 2
  },
  "history": [
    {
      "commit_sha": "a1b2c3d4e5f6",
      "branch": "main",
      "total_specs": 20000,
      "annotated_specs": 5000,
      "annotated_ratio": 0.25,
      "duration_seconds": 74.25,
      "shard_count": 4,
      "timed_shard_count": 4,
      "suite_size_measured": true,
      "ingested_at": "2026-08-07T11:01:58Z"
    },
    {
      "commit_sha": "9f8e7d6c5b4a",
      "branch": "spike/extract-billing",
      "total_specs": 400,
      "annotated_specs": 116,
      "annotated_ratio": 0.29,
      "duration_seconds": 11.5,
      "shard_count": 0,
      "timed_shard_count": 0,
      "suite_size_measured": true,
      "ingested_at": "2026-08-07T10:44:03Z"
    }
  ],
  "branches_window": {
    "order": "run_count_desc,last_run_at_desc,name_asc",
    "tie_break_served": false,
    "run_count_limit": 30,
    "walk_limit": 500,
    "walk_cut": false,
    "returned": 2
  },
  "branches": [
    { "name": "main", "run_count": 1, "run_count_capped": false },
    { "name": "spike/extract-billing", "run_count": 1, "run_count_capped": false }
  ]
}
```

**`null` is never a stand-in for a measurement.** Everything nullable below distinguishes "not
reported" from a real zero, because a client cannot tell them apart after the fact:

| Field | `null` means |
| --- | --- |
| `api_key.last_used_at` | the key has never authenticated a request |
| `latest_run` | **CI has never reported for this repository** — not a zeroed block. A repo whose CI never ran must not serialize byte-identically to one that ran and found an empty suite. |
| `latest_run.branch` | the client did not say. `POST /api/v1/ingest` accepts a body without it. |
| `latest_run.duration_seconds` | no wall clock was reported. `0.0` would assert the run took no time. |
| `latest_run.annotated_ratio` | the run reported **zero tests**, so there is no share to take. The counts are still present, so a client can compute its own. |
| `latest_run.shards` | the run was assembled from **one shard or none** — the entire unsharded corpus. There is no composition to disambiguate: one shard's MAX *is* its SUM. The key is always present. |
| `latest_run.shards.machine_seconds` | not one shard reported a timing. `0.0` would assert the suite was free. |
| `latest_run.shards.rows` / `.balanced_wall_clock_seconds` / `.wall_clock_excess_seconds` | the wall clock **cannot honestly be decomposed yet**, for one of two reasons the payload does not distinguish — see below. All three null *together*, never individually: they are three readings of one decomposition, and a floor without the rows it was taken over is a figure a client cannot check. `rows` is `null` rather than a partial list, because a list ordered "slowest first" that is missing shards names the wrong head. Note that `per_shard` below is **not** null in this state: it claims no ordering, so nothing about it goes wrong when a shard is silent. |
| `latest_run.shards.per_shard[].shard_id` | the client did not name that slice. A positional index would be a name nothing in CI answers to, and it would point at a different slice on the next run. |
| `latest_run.shards.per_shard[].duration_seconds` | that shard reported no timing. `total_specs` beside it is still a real count, and `0` there is a real count too — a shard that loaded no specs, not a shard that said nothing. |
| `history[].branch` / `.duration_seconds` / `.annotated_ratio` | exactly what the same-named `latest_run` field means. A history row is the same row `latest_run` serializes, minus the per-shard cost figures. |
| `branches` | **never `null`** — `[]` instead, by the list rule below. No field on a row is nullable either: a row exists because a branch has runs, so `name`, `run_count` and `run_count_capped` are always present. |
| `branches_window` | **never `null`**, and served on every request — with or without `?branch=`, and including one whose `branches` came back empty. Its fields are bounds on the walk, which are facts about how SpecGuard looked rather than about what it found, so there is no state in which they are unknown. |

**The two lists are the exception, and they are lists rather than blocks.** `history` and
`branches` are each `[]` — never `null` — for a repository whose CI has never reported. The rule
above exists because a zeroed *block* asserts measurements nobody took: a `latest_run` of zeros
claims a run happened and found nothing. An empty *list* asserts nothing of the kind — "no runs" is
exactly what zero rows means, and it is the same answer you get after filtering a populated history
down to a branch that never ran, or after cataloguing a repository whose every run named no branch.
Nulling either would force every consumer to handle two spellings of the empty case before it could
iterate. `latest_run` stays `null` in that same response; all three are consistent, not in
conflict.

`annotated_ratio` is the **0–1 fraction**, the same unit `POST /api/v1/ingest` answers with — never
the 0–100 percentage `TestRun#annotated_ratio` renders for the dashboard. The 100× gap between the
two is invisible in a JSON body.

#### The cost figures and the decomposition, and what each was measured over

A sharded suite delivers itself over N requests and `Ingest::RunRecorder` folds all of them onto
one run, recomputing the counts as the SUM of the shards and `duration_seconds` as the **MAX**.
That MAX is correct — shards run concurrently, so the slowest one is the run's wall clock — but it
is not what the suite *cost*. Four shards of 61.0s, 58.5s, 74.25s and 60.0s are a 74.25s wait and
253.75s of machine time, a 3.4× gap that widens with every shard added.

- `duration_seconds` — the **wall clock**, MAX over the shards. Unchanged in key, type and value
  from before the `shards` block existed.
- `shards.machine_seconds` — what the suite **cost**, SUM over the shards.
- `shards.count` — how many shard rows the run was assembled from. A count of *recorded shards*,
  not of distinct CI jobs: the unique index on `(test_run_id, shard_id)` is partial
  (`WHERE shard_id IS NOT NULL`), so a client that shards without exposing an index the gem
  recognises gets one row per delivery.
- `shards.timed_count` — how many of those reported a duration. Shard durations are nullable and
  ingest accepts a shard without one, so a silent shard is an ordinary state.
- `shards.coverage` — **how many shards each cost figure was computed over**, keyed by the figure's
  own JSON name. `coverage.duration_seconds` is the MAX's denominator, `coverage.machine_seconds`
  the SUM's, and `count` is what the run has. When they differ, the SUM is a *floor* and the MAX is
  a maximum over a subset — which may well have excluded the slowest shard, since a cancelled or
  timed-out job usually is. Counts rather than the dashboard's prose ("slowest of the 3 that
  reported") so a client can divide rather than parse English.
- `shards.rows` — **which** shard, not just how many. Every shard's own `shard_id` and
  `duration_seconds`, **slowest first**, so `rows.first` is the shard the run waited on and the
  list walks down to the fastest. The four figures above say a run was assembled from four parts
  and cost 253.75s between them; not one of them is a shard, so a client reading only those cannot
  learn which part it waited on.
  - `shard_id` is served **raw and nullable, never a position number**. A client that shards
    without naming its slices sends nothing and gets `null` back — numbering the rows would hand
    the reader a name CI never used, one that points at a different slice next run. The prose
    spelling (`"shard 3"` / `"an unnamed shard"`) is the dashboard's; build your own from the raw
    value, or correlate it against your CI config, which is what the raw value is for.
  - `duration_seconds` is a **raw float**, on the rule the two figures above already follow. It is
    the same per-shard column the SUM and the MAX were taken over, so a client can re-derive both.
- `shards.balanced_wall_clock_seconds` — the shortest wall clock any arrangement of these shards
  could have produced: `machine_seconds` spread perfectly evenly across `count`. A **lower bound
  and never a target** — tests are not arbitrarily divisible, and a single example longer than
  this floor makes it unreachable on its own. Nothing here claims such a split exists, only that
  none can go under it; a client rendering this owes its reader that wording.
- `shards.wall_clock_excess_seconds` — `duration_seconds` minus that floor: the part of the wait
  attributable to **how the suite was divided** rather than to the suite itself. For the body
  above, 74.25s against a 63.4375s floor is 10.8125s of the wait that a different split could in
  principle have returned.
- `shards.per_shard` — **each shard's duration beside the test count it was measured over.** The
  figures above say how much the run's wait exceeded an even split; they cannot say *why*, and the
  two causes take opposite actions. `duration = test count × cost per test`, so a shard that ran
  long either held more tests than its siblings, or held the same number of individually dearer
  ones. Both print identically from durations alone. What separates them is **which partitioner
  closes the gap**, not whether one can: machine time is invariant under re-partitioning and the
  floor is `machine ÷ shard_count`, so a duration-weighted split reaches the floor either way,
  while a split by count only reaches it when the per-test costs are already even.
  - `shard_id` — `null` when the client did not name the slice, never a positional index: a name
    nothing in CI answers to is worse than no name.
  - `duration_seconds` — `null`, never `0.0`, for a shard that reported no timing.
  - `total_specs` — `0` is a real value. A shard can load no specs, and that row has a wall clock
    with no denominator. **The endpoint serves the two operands and never the quotient**, partly so
    the client owns that decision and partly because a served rate would have to invent an answer
    there.
  - **Delivery order, not slowest-first.** Sort it yourself if you want a ranking; a duration-ranked
    read puts nulls first in Postgres, so the shard that reported *nothing* would head a list read
    as "slowest".
  - **Why this is not folded into `rows`.** The two overlap — every shard in `rows` is here too,
    with one more column — but they are served under different gates and neither gate suits the
    other. `rows` is withheld whenever the decomposition is untrustworthy, because a *ranking* is
    what goes wrong mid-delivery or with a silent shard. A test count does not go wrong in either
    state: it is written on every POST that lands. Folding `total_specs` into `rows` would withhold
    a known count on exactly the runs where a reader most wants it.

  A shard is an arbitrary partition of the suite and not a directory, so this answers *which
  partition of this run is expensive per test* — never *which code is expensive*.

Those last three are served **only when the decomposition is honest**, and are `null` — all three,
still present — otherwise. Two distinct states produce that `null`, and the payload does not
distinguish them, so the difference is recorded here:

- **A shard reported no timing** (`timed_count` < `count`). The run will *never* decompose: a row
  counted in the denominator but missing from the SUM drags the floor down and pushes the excess
  up by exactly the same amount, so both figures would move in the direction that manufactures a
  finding. Asking again does not help.
- **The run's shards are still arriving.** SpecGuard picks a run up the instant its *first* shard
  lands, and a half-delivered run has every shard present timed — so this state is invisible in
  `count` and `timed_count`, which agree with each other while both are still climbing. The
  decomposition is withheld until deliveries settle (a 15-minute quiet period on the shard rows).
  This `null` is **transient**: once deliveries settle the three keys fill in, unless one of the
  shards still to arrive turns out to be untimed, which drops the run into the state above.

A client that needs to tell them apart today can: `timed_count == count` alongside three `null`s is
the second state, and worth retrying; `timed_count < count` is the first, and is final.

The dashboard's Overview panel renders these same figures under coverage-stating labels — the two
cost figures, and the rows, floor and excess beneath them; this block is how a client reconstructs
those labels for itself.

#### `history` — how the suite grew, without differencing two polls

Without it, the only way to learn that the suite grew is to call this endpoint twice and subtract
one `total_specs` from the next — which is exactly the subtraction `TestRun` spends eighteen lines
of its own documentation forbidding, because two runs are only comparable under conditions a poll
cannot see. `history` serves the rows themselves, plus the facts that decide whether any two of
them may be differenced at all.

**`history` is not a series — until you ask for one.** By default `history_window.branch_scope` is
`all_branches`, and it means what it says: these are the repository's runs interleaved across every
branch CI reports from, so `history[0]` and `history[1]` are routinely two different branches and
the difference between their `total_specs` is **not** a change in the suite. The dashboard's
Recent-runs panel carries that same warning as a caption under its heading; a machine client has no
caption, so the fact is structural here — every row carries its own `branch`.

**Do not filter the array client-side. Ask the server.** `?branch=` is not a convenience: filtering
what you received cannot work, because the bound was already spent before you saw it. On a
repository whose CI reports on every PR, the ten most recent runs are routinely all feature
branches, so `history.filter(r => r.branch === "main")` returns `[]` while `main` holds thirty runs
in the same table — and there is no cursor to reach past the window. `?branch=main` puts the
predicate in the same query as the bound, which is the only way to get a series. The name to put in
it comes from [`branches`](#branches--which-names-branch-may-take), not from `history`.

```sh
curl -H "Authorization: Bearer sgk_..." \
  "http://localhost:3000/api/v1/repository?branch=main"
```

| Request | `branch_scope` | `branch` | `limit` | `history` holds |
| --- | --- | --- | --- | --- |
| no `branch` param | `"all_branches"` | `null` | `10` | the interleaved tail across every branch |
| `?branch=` (blank) | `"all_branches"` | `null` | `10` | identical to the above — blank means *no filter* |
| `?branch=main` | `"single_branch"` | `"main"` | `30` | only `main`'s runs, newest first |
| `?branch=never-ran` | `"single_branch"` | `"never-ran"` | `30` | `[]` |
| `?branch[]=main` (non-string) | `"all_branches"` | `null` | `10` | `200`, unfiltered — the filter did not apply |

Four things worth knowing before you use it:

- **A narrowed window reaches further back — 30 rows, not 10.** Ten interleaved rows is a sample of
  what CI has been doing lately; ten rows of *one* branch is an afternoon, and the question a series
  answers is what the suite has done over a month. It is the same depth the dashboard's suite-size
  chart uses. `limit` always reports **which bound actually applied**, so you never have to know
  this rule to read `returned == limit`.
- **An unknown branch returns `[]`, never a substituted branch's rows.** The dashboard falls back to
  its current anchor for a branch it does not recognise and renders a visible notice saying so; you
  have no notice. Silently receiving `feature/x` rows after asking for `main` would be a growth
  series computed for the wrong branch with nothing in the body to detect it. `history_window.branch`
  restates what the server filtered on, so `[]` with `"branch": "main"` means *`main` has no runs* —
  not *your filter was ignored*. Compare it against what you sent.
- **`latest_run` is not re-anchored.** It names the repository's newest run under every request;
  only `history` narrows. So under `?branch=main` on a repository whose newest run is on
  `feature/x`, `history[0]` is a `main` row and `latest_run` is the `feature/x` one — they are
  *supposed* to differ, and `branch_scope` is what says so. The `history[0] == latest_run` identity
  below holds for the **unfiltered** window.
- **Runs that reported no branch are unselectable.** `branch` is nullable and ingest accepts a body
  without it, so `null` means *"the client did not say"* — a different fact from any branch name.
  No `?branch=` value matches those rows, because pooling every anonymous run from every branch and
  every machine into one "series" would be fiction. They still appear in the unfiltered window.

Before differencing two rows, check both:

- `suite_size_measured` — `false` when the run reported **zero tests**. It has a count but not a
  measurement, and a difference taken against it describes the report rather than the suite.
- `shard_count` — how many shards the row was assembled from. A run's `total_specs` is the SUM over
  the shards recorded *so far*, so differencing an in-flight sharded run against a complete one
  reports a deletion no commit made. Equal counts is the same rule `TestRun#assembled_like?`
  applies on the dashboard.
- `timed_shard_count` — how many of those shards reported a **duration**. This is the denominator
  of the row's own `duration_seconds`, which on a sharded run is the MAX over the shards that
  *reported* — not over `shard_count`. A shard's timing is nullable and a cancelled or timed-out
  job usually is the slowest one, so four timed shards at a 600s wall clock and four shards whose
  two slowest went silent at 180s carry an identical `shard_count` and an identical
  `suite_size_measured`: differencing them on `duration_seconds` alone reports a 70% speedup that
  is entirely telemetry loss. `0` — never `null`, never absent — when nothing was timed, and `0`
  for the shardless corpus, where there were no parts to time.

`machine_seconds` is deliberately **not** here, and neither is a `shards` sub-block like
`latest_run` carries. A client differencing two rows needs to know they were assembled from the
same number of parts and over how much of them each figure was measured — not what each part cost.
The preload that makes this window cheap takes both counts in one grouped aggregate; anything
further (`machine_seconds`) would be one extra query per row. The full cost figures stay on
`latest_run`, which is one row.

`history_window` is the contract, as tokens rather than prose:

| Field | Meaning |
| --- | --- |
| `order` | `"ingested_at_desc,ingest_sequence_desc"` — **both** keys. Rows are ordered by ingest time descending, ties broken by ingest sequence descending. Unchanged by `?branch=`: the predicate rides along with the same `ORDER BY` rather than re-sorting anything. |
| `tie_break_served` | `false`. The second ordering key is **not** a field on a row, so the ordering is not reproducible from what you hold — see below. |
| `branch_scope` | `"all_branches"` when the window was not narrowed, `"single_branch"` when `?branch=` applied. A token to compare, not a caption to parse. |
| `branch` | The branch the server filtered on, or `null` when it did not. Always present. It restates what the **server** did, which is not always what you sent — a blank or non-string `?branch=` is no filter, and this key is how you find that out. |
| `limit` | The bound **actually applied**: `10` unfiltered, `30` narrowed. |
| `returned` | How many rows this response actually carries. |

`branch_scope` and `branch` are two keys rather than one token like `"branch:main"` on purpose: you
compare the scope against a fixed vocabulary you can hard-code, and read the name out of `branch`
without parsing. A token carrying the name would be neither.

**Read the array in the order it arrived.** Two runs ingested in the same instant carry the same
`ingested_at`, and the key that orders them — the ingest sequence — is not served on a row, here or
on `latest_run`. So a client that re-sorts on `ingested_at` alone scrambles exactly those pairs and
can end up disagreeing with `latest_run` about which commit is newest. In the **unfiltered** window
`history[0]` is the same row as `latest_run` **always**, including the same-instant case; re-sorting
is the one way to break that. (Under `?branch=` the two legitimately differ — see above.)

`limit` is a bound, not a page: ten rows is ten rows whether the suite holds three tests or twenty
thousand, and there is no cursor to continue. `returned == limit` is how you learn the suite has run
at least `limit` times and this is the tail — the inference you would otherwise draw wrongly from a
full array. If you hit it on a narrowed window, you have thirty runs of that branch and there is
more behind them.

#### `branches` — which names `?branch=` may take

`?branch=` needs a name and, before this block existed, nothing in the response gave you one. The
only branch names a client ever saw were the per-row `branch` values in `history` — and unfiltered
that array is the ten-row *interleaved* window described above, which on a repository whose CI
reports on every PR is routinely ten `feature/*` rows with the trunk nowhere in it. **To filter you
need a name; the only place to read a name was the one window that systematically hides the one you
want.**

Guessing does not converge either: an unknown branch and a real branch that has simply never run
both answer `history: []` with `"branch"` echoing your ask, byte for byte. There is no signal to
probe against. `branches` is that signal — it is the set of names `?branch=` can match, and nothing
outside it will ever return a row.

It is served on **every** request, with or without `?branch=`, for the reason the dashboard's
Suite-growth panel gives for loading its selector unconditionally: the client that needs the list
most is the one that has not selected anything yet.

```json
"branches": [
  { "name": "main", "run_count": 30, "run_count_capped": true },
  { "name": "spike/extract-billing", "run_count": 4, "run_count_capped": false }
]
```

| Field | Meaning |
| --- | --- |
| `name` | A branch that has runs. Pass it back as `?branch=` verbatim. |
| `run_count` | How many runs it holds, **capped** at `branches_window.run_count_limit`. |
| `run_count_capped` | `true` when the count *stopped* at that cap rather than finishing. `run_count: 30, run_count_capped: true` means *at least* thirty. |

**The cap is a boolean beside the number, never a `"30+"` string.** The dashboard renders exactly
that caption; a client comparing two branches would have to strip the `+` before it could subtract,
and a count that stopped is a different fact from a count that finished. Both are served, and
neither is spelled into the other. `run_count` stops there because that is how far
`?branch=`'s own window reaches — counting a trunk's forty thousand runs would answer a question no
endpoint here asks.

**Runs that reported no branch are absent.** `null` means *"the client did not say"*, and the
anonymous runs of every machine are not one branch — offering them a name here would offer a name
`?branch=` deliberately refuses to match. They still appear in the unfiltered `history`.

`branches_window` carries the bounds, on the same tokens-not-prose rule as `history_window`:

| Field | Meaning |
| --- | --- |
| `order` | `"run_count_desc,last_run_at_desc,name_asc"` — most history first, ties to the branch pushed to most recently, then to its name. |
| `tie_break_served` | `false`. The middle key is not a field on a row, so **read the array in the order it arrived** — two branches with equal counts carry nothing that says which the server put first. |
| `run_count_limit` | Where each row's `run_count` stops counting: `30`. |
| `walk_limit` | How many branches SpecGuard walks: `500`. |
| `walk_cut` | `true` when the walk **may have stopped short** — the list is a prefix, and a branch's absence from it is not evidence that branch has no runs. See below. |
| `returned` | How many rows this response carries. Can exceed `walk_limit` by one when `?branch=` pinned a branch the walk did not reach, which is why it is not a substitute for `walk_cut`. |

**`walk_cut` is the one you must not ignore.** The walk is *name-ordered* — it asks the index for
the next branch alphabetically — so past `walk_limit` what you hold is an **alphabetical prefix** of
the repository, and "most history first" is an ordering over the branches SpecGuard reached rather
than over the branches there are. On a repository with 2,900 `feature/*` branches, the five hundred
walked are `feature/000…`, and `main` — with a hundred runs — is not among them. Under
`walk_cut: true`, **a branch's absence from this list is not evidence that it has no runs**; ask for
it with `?branch=` anyway. Under `walk_cut: false` the list is every branch that has a run.

**The two directions are not equally sharp, and the asymmetry is deliberate.** `walk_cut` is
derived by comparing what the walk returned against `walk_limit` with `>=`, so a repository holding
*exactly* `walk_limit` branches reports `true` although the walk reached every one of them. That
direction over-warns by design — its cost is a client re-probing a branch with `?branch=` that was
already in the list, which answers correctly — and the same derivation runs behind the dashboard's
own panel. `walk_cut: false` carries no such slack: it is reached only by returning fewer rows than
the bound, so it means the walk finished and the list is complete.

Bounded that way, and not near the size of a display list, on purpose: the dashboard shows eight
branches, and cutting the *walk* anywhere near eight would hand the history sort an arbitrary
alphabetical prefix and drop the trunk out of the very ordering that exists to keep it in. That
display bound is not applied here — a JSON array has no row of links to fit.

**`?branch=` and `branches` agree inside one response.** A branch you filtered on is pinned into the
walk's result, so a body that serves thirty `main` rows in `history` cannot omit `main` from
`branches` even past `walk_limit`. Pinning cannot invent one: a branch with no runs drops out here
exactly as it answers `[]` there.

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
