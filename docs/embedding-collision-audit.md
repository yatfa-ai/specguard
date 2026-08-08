# Embedding collision audit

**Question:** `EmbeddingGenerator::LocalProvider` hashes an unbounded feature space into 1536
buckets. Distinct features land in the same dimension and their weights sum. At SpecGuard's target
scale — **20,000 tests in a single repository**, all drawn from one codebase's vocabulary — does
that produce false matches often enough to matter?

**Answer, measured 2026-08-08 over all 199,990,000 pairs of a 20,000-name corpus:** no.

| | |
|---|---|
| Mean \|hashed − exact\| cosine error | **0.0196** |
| Largest overstatement anywhere in the census | **+0.274** (nothing above +0.4) |
| False matches at cosine ≥ 0.88 | **119** in 199,990,000 pairs — 1 in 1.68 million |
| …of which the collision-free algorithm scores as unrelated (< 0.3) | **0** |
| Missed matches at cosine ≥ 0.88 (hashing destroying a real similarity) | 101 |

Every single false match at every threshold tested was a **near-miss nudged across the line**, not
an invented resemblance: across 200 million pairs and four thresholds, hashing never once pushed a
genuinely-unrelated pair (collision-free cosine < 0.3) above a match threshold. Per test, that is
about **0.01 spurious neighbours at 0.88** and 0.06 at 0.75.

Feature hashing at 1536 dimensions is **not** the limiting factor for duplicate detection at this
scale. [The lexical-vs-semantic limitation](#what-this-does-not-tell-you) is.

---

## The corpus

Real RSpec example names, from one codebase, as the ticket requires — synthetic names are more
distinguishable from one another than real ones, which cluster heavily around a shared domain
vocabulary, and would have flattered the result.

| | |
|---|---|
| Source | [discourse/discourse](https://github.com/discourse/discourse) |
| Commit | `f3c568cfd26a427e9cae32063732a56bc7d334b9` (2026-08-07) |
| Paths walked | `spec/`, `plugins/` |
| Spec files scanned | 3,328 |
| Example names extracted | 39,469 |
| …skipped, interpolated description | 162 |
| …skipped, no description at all | 2,138 |
| …exact duplicate names | 60 |
| **Corpus** | **20,000**, taken by an even stride over the deduplicated sorted list |
| Name length (min / mean / max) | 13 / 99.1 / 399 characters |

Discourse was chosen because it is a single Rails codebase with an RSpec suite comfortably past
20,000 examples, so the corpus is one project's vocabulary rather than a blend of several — which
is the hard case for hashing, not the easy one.

Names are extracted by statically parsing each spec file with Prism and joining the
`describe`/`context`/`it` chain the way RSpec joins it (`describe Post` + `describe "#save"` →
`Post#save`, with no space). Static parsing rather than `rspec --dry-run` so the corpus is
reproducible from a bare clone, with none of the target project's gems or database. Examples whose
description is interpolated or absent are **skipped and counted**, never guessed at: inventing
corpus text would make this a measurement of the script's imagination.

## The method

For every pair — a full census, not a sample — two cosine similarities are computed:

* **hashed** — the vector `EmbeddingGenerator.call` actually returns and pgvector would actually
  store. 1536 dimensions, with collisions.
* **exact** — the same features with the same signed weights, but every feature keeps a dimension of
  its own in an unbounded space. Collision-free by construction.

Both come from `LocalProvider`'s own tokeniser and weighting rather than a reimplementation, so the
only difference between them is the `% 1536`. **That makes the gap between them attributable to
hashing and to nothing else** — which is the whole point, and why "exact" is the right ground truth
here.

Definitions used below, at a threshold `t`:

* **false match** — `hashed ≥ t` and `exact < t`. Hashing alone flipped the verdict to "same test".
* **missed match** — `exact ≥ t` and `hashed < t`. Counted too, because a collision can destroy a
  similarity as easily as it can invent one.

Deliberately **not** used as ground truth: human judgement about which test names *mean* the same
thing. LocalProvider does not claim to measure meaning, so scoring it against meaning would have
measured its known lexical limitation instead of the hashing question this audit exists to answer.

## The result

### Vectors

| | |
|---|---|
| Distinct features across the corpus | 13,544 |
| Dimensions available | 1,536 |
| **Crowding** | **8.8 features per dimension** |
| Mean non-zero dimensions per name, hashed | 88.9 |
| Mean non-zero dimensions per name, collision-free | 92.1 |
| Features lost to collisions *within a single name* | 3.46% |

So collisions are not hypothetical: the space is oversubscribed roughly nine to one, and a typical
name already loses ~3% of its own features to self-collision before it is compared to anything.

### Error distribution over all 199,990,000 pairs

| \|hashed − exact\| | pairs | share |
|---|---:|---:|
| < 0.001 | 9,806,366 | 4.90% |
| < 0.005 | 28,841,375 | 14.42% |
| < 0.01 | 31,964,396 | 15.98% |
| < 0.05 | 117,184,507 | 58.60% |
| < 0.1 | 11,762,694 | 5.88% |
| < 0.2 | 429,480 | 0.215% |
| < 0.4 | 1,182 | 0.0006% |
| ≥ 0.4 | **0** | 0% |

Cosine error is tightly concentrated: 94% of pairs are within 0.05, and the tail stops dead before
0.4. Because the weights are **signed**, colliding features cancel about as often as they reinforce
— a collision perturbs an inner product rather than inflating it. All-positive weights would have
made every collision a one-way push toward a false match.

### Verdict flips at each threshold

| t | hashed ≥ t | exact ≥ t | **false** | false & exact < 0.3 | missed |
|---|---:|---:|---:|---:|---:|
| 0.95 | 589 | 583 | 27 | **0** | 21 |
| 0.88 | 3,095 | 3,077 | 119 | **0** | 101 |
| 0.80 | 8,417 | 8,334 | 387 | **0** | 304 |
| 0.75 | 13,545 | 13,521 | 636 | **0** | 612 |

| t | false-match rate | spurious neighbours per test |
|---|---|---|
| 0.95 | 1.35 × 10⁻⁷ (1 in 7,407,037) | 0.003 |
| 0.88 | 5.95 × 10⁻⁷ (1 in 1,680,588) | 0.012 |
| 0.80 | 1.94 × 10⁻⁶ (1 in 516,770) | 0.039 |
| 0.75 | 3.18 × 10⁻⁶ (1 in 314,450) | 0.064 |

False and missed matches are of the same order at every threshold, which is what symmetric noise
looks like — hashing is not systematically biased toward inventing similarity.

### The worst case in the whole census

The single largest overstatement across 200 million pairs:

```
+0.2744  hashed 0.3409 / exact 0.0665
  A: Chat::GuardianExtensions chat channel#can_restore_chat? when channel is closed
     disallows a owner to restore
  B: Group delete a group redirects to groups index page
```

0.34 is nowhere near any threshold a duplicate detector would use. That is the shape of the finding:
hashing's worst error on this corpus lands far below the range where the product would act on a
score.

## What this does not tell you

**This audit is about collisions, and only about collisions.** It says the 1536-dimension hash is
faithful to the algorithm. It says nothing about whether the algorithm is faithful to *meaning* —
and it is not:

> `LocalProvider` measures **lexical** overlap. "rejects checkout on an expired card" and "rejects
> checkout when the card is expired" cluster at 0.62. "returns 402 payment required" and "declines
> the purchase" — the same behaviour in different words — score **0.00**, indistinguishable from
> two unrelated tests.

That limitation is a property of the engine, recorded in *Project Goals* (SPGD-1) and on
`EmbeddingGenerator::LocalProvider` itself. It lands differently on the product's two halves:

* **Test identity** (an unchanged test name embedding to an unchanged vector between runs) is served
  exactly, and this audit confirms hashing does not spoil it.
* **Duplicate clustering** only ever finds the duplicates that were phrased alike. Widening the
  corpus or raising the dimension count would not change that; only a semantic embedder would.

Two further honest bounds on this measurement:

* One corpus, one project. Discourse's vocabulary is Ruby/Rails/forum; another domain's test names
  will crowd the hash differently, though nothing in the result suggests it would crowd it *nine
  times* worse.
* Names inside a `shared_examples` block are extracted once under the shared block's own
  description, rather than once per including context, since the static parser cannot resolve
  inclusion. That slightly reduces near-duplicate density — in the direction of a *harder* corpus,
  not an easier one.

## What this means for thresholds

SPGD-252 deliberately did not pick a similarity threshold; that belongs to the job that uses one
(roadmap SPGD-72). This audit is the evidence such a choice should be made from:

* At every threshold from 0.75 to 0.95, collision-induced false matches are rarer than 1 in 300,000
  pairs, and none of them involve a genuinely unrelated pair. **A threshold anywhere in that range
  is not put at risk by hashing.**
* The 0.88 / 0.75 constants that appear in earlier design notes were never measured against
  anything. They remain unvalidated *as product thresholds* — this audit clears them of one specific
  worry (hash collisions) and no other.
* The number that should worry a threshold-chooser is not in this document: it is the recall lost to
  lexical-only matching. That needs its own measurement, on labelled duplicate pairs.

## Reproducing it

No Rails, no database, no API key, no network:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/discourse/discourse.git /tmp/discourse
cd /tmp/discourse && git sparse-checkout set spec plugins && git checkout f3c568c

cd /path/to/specguard
SIZE=20000 WORKERS=16 ruby script/embedding_collision_audit.rb /tmp/discourse/spec /tmp/discourse/plugins
```

The census took 250s across 16 forked workers on the machine it was run on. The script accepts any
directories containing `*_spec.rb`, so pointing it at a different suite re-answers the question for
that suite's vocabulary. Its own correctness — the name joining, and that its "hashed" vector really
is the one `EmbeddingGenerator.call` returns — is covered by
`spec/script/embedding_collision_audit_spec.rb`.
