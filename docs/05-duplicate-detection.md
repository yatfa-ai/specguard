# Duplicate-Detection Engine

The core of SpecGuard: given a *proposed* intent, find existing intents that describe the same
behavior — especially across layers. This doc covers the embedding strategy, the hybrid search,
and the threshold that separates "duplicate" from "vaguely related".

## Embedding generation

### What gets embedded

For both ingestion and check-intent, the embedded string is the concatenation:

```
"{entity} {action} {behavior}"
```

e.g. `"Order checkout returns 402 payment required on expired card"`.

Only these three fields are embedded. `layer` and `preconditions` are metadata, not semantics —
they filter and annotate results but don't shape the vector.

### Provider

`EmbeddingGenerator` is a swappable interface with one default implementation:

```ruby
# app/services/embedding_generator.rb
class EmbeddingGenerator
  Error = Class.new(StandardError)

  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text
  end

  def call
    response = OpenAI::Client.new.embeddings.create(
      model: SpecGuard.configuration.embedding_model,   # "text-embedding-3-small"
      input: @text
    )
    response.dig("data", 0, "embedding")                 # Array<Float>, length 1536
  rescue Faraday::Error, OpenAI::Error => e
    raise Error, "embedding provider failed: #{e.message}"
  end
end
```

- **Default model:** `text-embedding-3-small` → 1536 dimensions (matches `spec_intents.embedding`
  column size and the HNSW index).
- **Swapping:** implement the same `.call(text) -> Array<Float>` contract and point
  `SpecGuard.configuration.embedding_generator` at it. A local model (e.g. via Ollama) or a
  different vendor can drop in without touching `IntentChecker` or the ingestion job.
- **Dimension changes are a migration.** Switching to a 3072-dim model requires altering the
  `embedding` column, dropping/recreating the HNSW index, and re-embedding every row. There is no
  in-place resize.

## Hybrid search: entity filter + vector similarity

Pure vector search over the whole repo produces false positives — *"refund on expired order"* is
semantically near *"checkout on expired card"* but is a different behavior. SpecGuard avoids this
with a **two-stage hybrid query**:

1. **Exact filter:** restrict to `spec_intents WHERE repository_id = ? AND entity = ?`.
2. **Vector rank:** within that bucket, find nearest neighbors by cosine similarity.

```ruby
# app/services/intent_checker.rb
class IntentChecker
  DUPLICATE_THRESHOLD = 0.88
  PARTIAL_BAND        = 0.75

  def self.call(repository:, proposed_intent:)
    embedding = EmbeddingGenerator.call(
      "#{proposed_intent[:entity]} #{proposed_intent[:action]} #{proposed_intent[:behavior]}"
    )

    candidates = repository.spec_intents
                           .where(entity: proposed_intent[:entity])
                           .nearest_neighbors(:embedding, embedding, distance: :cosine)
                           .limit(5)

    similar = candidates.map do |intent|
      similarity = 1 - intent.neighbor_distance   # cosine distance → similarity
      next if similarity < PARTIAL_BAND
      intent.attributes.slice("file_path", "line_number", "layer", "behavior")
            .merge("similarity_score" => similarity.round(3))
    end.compact

    layer_saturation = repository.spec_intents
                                 .where(entity: proposed_intent[:entity])
                                 .group(:layer)
                                 .count

    build_response(similar, layer_saturation, proposed_intent)
  end
end
```

### Why entity-first?

- **Precision.** The vector space can only confuse behaviors *within* the same subject. A
  `User`-entity match can never drown out an `Order` query.
- **Speed.** The entity index shrinks the candidate set before the (more expensive) ANN scan; the
  HNSW index then operates on a small partition.
- **Honest duplication.** Cross-layer duplication is, by construction, the same `entity` tested at
  different `layer`s. Filtering by entity guarantees the "same behavior, different layer" case is
  the *only* thing that can surface.

## `neighbor_distance` vs `similarity_score`

The `neighbor` gem returns `neighbor_distance` = **cosine distance** (0 = identical, 2 = opposite).
Humans and the API speak in **similarity** (1.0 = identical). The conversion is one line:

```ruby
similarity = 1 - neighbor_distance
```

This is why `similarity_score` in API responses can be `0.93` while the underlying query sorts by
ascending distance. Never expose raw distance in the API.

## Threshold rationale

| Band | Similarity | Status | Treatment |
|---|---|---|---|
| Duplicate | ≥ 0.88 | `DUPLICATE_FOUND` | Agent should not write the spec |
| Partial | 0.75 – 0.88 | `PARTIAL_MATCH` | Surfaced, but `duplicate_detected: false` |
| Unrelated | < 0.75 | (not returned) | — |

- **0.88** is empirical, tuned for "same behavior, reworded." At this threshold, *"returns 402
  payment required on expired card"* and *"rejects the transaction on an expired card and emits a
  payment_failed event"* reliably cluster as duplicates. It is a `configuration` value, not a
  constant — repos with terser or more verbose `behavior` prose may want to tune it.
- **0.75** catches "adjacent" behaviors worth a human glance without crying wolf. Below that,
  results are noise.
- The threshold operates on `behavior`-dominated embeddings; entity is already an exact filter, so
  the threshold does not need to compensate for cross-entity drift.

## Response shaping

`IntentChecker.build_response` produces the compact payload an LLM agent can act on without a
second round-trip:

- `status` + `duplicate_detected` — the go/no-go.
- `similar_intents[]` — *where* it's already covered (`file_path:line_number`, layer, behavior,
  score), sorted by score descending.
- `layer_saturation` — counts per layer for that entity, so the agent sees *"unit: 12, request: 85,
  system: 24"* and understands the request layer is already saturated even if this specific
  behavior weren't a duplicate.
- `recommendation` — a single imperative sentence the agent can cite verbatim in its reasoning.

The recommendation generator is deliberately verbose and prescriptive ("DO NOT create a new spec
on 'request' layer") because agents follow explicit instructions more reliably than hints.

## Cost & latency profile

| Operation | Cost | Latency |
|---|---|---|
| Embed the proposal | 1 OpenAI call | ~100–200 ms (provider-bound) |
| Entity filter + ANN | 1 indexed query | single-digit ms (HNSW on a small partition) |
| Layer saturation | 1 `GROUP BY` | negligible |

The embedding call dominates. For agents that check many candidate specs in one session, a future
batch endpoint (`/check-intents`, plural) will amortize provider round-trips.

## Testing the engine

Specs for `IntentChecker` should include:

- A known-duplicate pair (reworded behavior) → asserts `DUPLICATE_FOUND` with score ≥ 0.88.
- A same-entity, genuinely-different behavior → asserts `NO_DUPLICATE` (or `PARTIAL_MATCH` at most).
- A different-entity near-synonym → asserts it is **not** returned (entity filter holds).
- An entity with skewed layer distribution → asserts `layer_saturation` reflects it.

Use a deterministic embedding stub in the test suite (fixed vectors per input string) so the
threshold assertions don't depend on a live provider. The `EmbeddingGenerator` interface makes
this a one-line swap in `spec/support`.
