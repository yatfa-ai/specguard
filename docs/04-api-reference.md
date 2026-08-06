# API Reference

All endpoints live under `/api/v1` and are JSON-only. Two paths exist:

- **`POST /api/v1/ingest`** — CI telemetry (called by the `specguard-rspec` formatter).
- **`POST /api/v1/check-intent`** — duplicate check (called by an AI agent before writing a spec).

Both require a repository API key. The web dashboard uses GitHub OAuth session auth and is
out of scope for this reference.

## Authentication

```
Authorization: Bearer sg_live_<token>
```

- The token is created per-repository in the dashboard and shown **once**. SpecGuard stores only
  `token_digest` (SHA-256); the raw token cannot be recovered.
- Auth resolves the `repository` from the key, so request bodies do **not** carry a `repository_id`.
- A missing/invalid/expired key returns `401`. A valid key for a deactivated repository returns `403`.

### Example

```bash
curl -X POST https://specguard.example.com/api/v1/check-intent \
  -H "Authorization: Bearer sg_live_abc123" \
  -H "Content-Type: application/json" \
  -d '{"proposed_intent":{"entity":"Order","action":"checkout","behavior":"rejects checkout on expired card","layer":"request"}}'
```

---

## POST /api/v1/ingest

Submit the result of one test run as JSONL-ish JSON (an array of specs under a run header).
The `specguard-rspec` formatter builds this payload automatically; the shape is documented here
for non-Ruby clients.

### Request body

```json
{
  "commit_sha": "a1b2c3d4e5",
  "branch": "main",
  "duration_seconds": 45.2,
  "specs": [
    {
      "file_path": "spec/requests/orders_spec.rb",
      "line_number": 45,
      "status": "annotated",
      "intent": {
        "entity": "Order",
        "action": "checkout",
        "behavior": "returns 402 payment required on expired card",
        "layer": "request"
      }
    },
    {
      "file_path": "spec/models/user_spec.rb",
      "line_number": 12,
      "status": "unannotated",
      "intent": null
    }
  ]
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `commit_sha` | string | yes | Short or full SHA; used for the `TestRun` record |
| `branch` | string | no | For dashboard filtering |
| `duration_seconds` | float | no | Whole-run wall time |
| `specs[].file_path` | string | yes | Repo-relative path |
| `specs[].line_number` | integer | yes | 1-indexed line of the test (the `it`/`test` declaration) |
| `specs[].status` | enum | yes | `annotated` \| `unannotated` |
| `specs[].intent` | object \| null | yes if `annotated` | Matches [OpenTestIntent](02-open-test-intent-protocol.md#3-json-schema-validation-contract); `null` when `unannotated` |

### Processing

1. Create a `TestRun` (`commit_sha`, `branch`, `duration`, counts derived from `specs`). The counts
   are derived server-side from `specs[]` and never read from the client.
2. For each `annotated` spec: enqueue an `EmbeddingJob` that embeds `"{entity} {action} {behavior}"`
   and **upserts** the `spec_intent` on `(repository, file_path, line_number)`.
3. For each `unannotated` spec: **count it, do not persist it.** It contributes to the run's
   `total_specs` — which is the denominator of the annotated-ratio metric — and produces no
   `spec_intent` row. There is nothing to store: `spec_intents.entity/action/behavior/layer` are
   all NOT NULL, and an unannotated spec has none of them. A run of 2 annotated + 1 unannotated
   spec therefore yields one `TestRun` with `total_specs: 3, annotated_specs: 2` and **two**
   `spec_intent` rows.
4. Return `202 Accepted` immediately; embeddings resolve asynchronously on Solid Queue.

This async design means `/check-intent` may not reflect an ingestion that just landed — the
client should not treat ingest+check as a synchronous round-trip.

### Response — `202 Accepted`

```json
{
  "test_run_id": 4288,
  "total_specs": 142,
  "annotated_specs": 119,
  "annotated_ratio": 0.838,
  "embedding_status": "queued"
}
```

| Field | Type | Notes |
|---|---|---|
| `annotated_ratio` | float | **A 0–1 fraction**, not a percentage: 119/142 = `0.838`, to three decimal places. The web dashboard shows the same figure as a percentage (`83.8%`) via `TestRun#annotated_ratio`; the API deliberately reports the fraction so a client never has to guess which unit it is holding. |
| `embedding_status` | enum | `queued` once the embedding job has been scheduled for this run's annotated specs. `pending` means the run was accepted and counted but nothing has been scheduled — the state while the embedding pipeline is not yet wired up. It is never reported as `queued` unless work was actually enqueued. |

### Errors

| Status | When |
|---|---|
| `400` | Malformed JSON, an envelope field missing or of the wrong type, or an `intent` that fails JSON-Schema validation. The body is `{"error": "bad_request", "message": …, "details": [...]}`, where every per-spec message names the offending spec by `file_path:line_number`. |
| `401` | Missing/invalid API key |

Two further codes appeared in earlier drafts of this contract and are **not** part of it:

- **`403` — "key valid but repository deactivated."** There is no deactivation concept in the
  product: `repositories` has no such column, and no code path can produce this. Removed rather
  than deferred; if repository deactivation is ever built, the code comes back with it.
- **`422` — a spec whose `file_path`/`line_number` is already owned by a different entity.**
  Unreachable from an asynchronous `202`: the endpoint answers before any `spec_intent` is
  touched, and the write itself upserts in place (see `03-data-model.md`), so there is no
  conflict for it to report.

Ingestion is **never** a CI failure mode for missing annotations — only for malformed ones. This
is deliberate: adoption must be opt-in and gradual. A run in which *every* spec is unannotated is
a valid run and returns `202`.

---

## POST /api/v1/check-intent

Ask whether a behavior an agent is *about to test* is already covered. Returns duplicates and
per-layer density for the proposed entity.

### Request body

```json
{
  "proposed_intent": {
    "entity": "Order",
    "action": "checkout",
    "behavior": "rejects checkout if the user's saved payment card is expired",
    "layer": "request"
  }
}
```

All four OpenTestIntent fields are required; the request is validated against the same JSON Schema
as ingestion.

### Response — `200 OK`

The shape is fixed; only `status` and the payload contents change.

```json
{
  "status": "DUPLICATE_FOUND",
  "duplicate_detected": true,
  "similar_intents": [
    {
      "file_path": "spec/services/billing/checkout_service_spec.rb",
      "line_number": 88,
      "layer": "unit",
      "behavior": "rejects the transaction on an expired card and emits a payment_failed event",
      "similarity_score": 0.93
    }
  ],
  "layer_saturation": {
    "unit": 12,
    "request": 85,
    "system": 24
  },
  "recommendation": "DUPLICATE DETECTED (93% similarity). Behavior is ALREADY covered in 'spec/services/billing/checkout_service_spec.rb:88' (unit layer). DO NOT create a new spec on 'request' layer."
}
```

### Status values

| `status` | `duplicate_detected` | Meaning |
|---|---|---|
| `DUPLICATE_FOUND` | `true` | ≥1 existing intent at/above the similarity threshold |
| `NO_DUPLICATE` | `false` | No match above threshold; the proposed test is genuinely new |
| `PARTIAL_MATCH` | `false` | Closest match is in a "review" band (see below) — not a duplicate, but worth a human glance |

### The similarity bands

- **≥ 0.88** → `DUPLICATE_FOUND`. The agent should not write a new spec.
- **0.75 – 0.88** → `PARTIAL_MATCH`. Surfaced in `similar_intents` but `duplicate_detected: false`.
  Useful for "did you mean this?" hints.
- **< 0.75** → not returned.

Threshold rationale is in [Duplicate Detection](05-duplicate-detection.md#threshold-rationale).

### Errors

| Status | When |
|---|---|
| `400` | Proposed intent fails JSON-Schema validation |
| `401` / `403` | Same as `/ingest` |
| `503` | Embedding provider unavailable (the *proposed* intent must be embedded to search; if the provider is down, we fail rather than answer blind) |

---

## Rate limiting & cost notes

- `/check-intent` costs **one embedding API call** per request (to embed the proposal). It is the
  only per-request external cost and is the main reason agents should batch consideration, not
  spam the endpoint.
- `/ingest` costs **one embedding call per annotated spec**, but asynchronously and deduplicated —
  re-running an unchanged commit embeds nothing (the behaviors haven't changed, so the upsert is a
  no-op once embeddings are cached on the row).
- Both endpoints are rate-limited per API key. Limits are configurable per repository.
