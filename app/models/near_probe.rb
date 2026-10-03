# frozen_string_literal: true

# THE `?near=` PROBE READ — the one surface that answers "what exists near this behavior phrase?"
# for a repository, and the disclosures that let a client judge the answer instead of trusting it.
#
# Built for SPGD-1544 as key work item 1 of roadmap SPGD-1102's four independently shippable
# slices. Before it, the only similarity read on `spec_identities` was the stored near-duplicates
# census — which answers "which pairs are redundant with each other", never "what is near X". The
# probe embeds the caller's phrase once (through the shipped provider and shipped cache), ranks
# the repository's identities through the single tenant-filtered ANN seam, and returns the
# top-10 with per-hit similarity, signal source, last-known path and the weight the latest run
# measured. It is served by `RepositoryOverview` behind the `?near=` opt-in — see
# `RequestedNearParam` for the ask's guard and `repository_near_probe_spec.rb` for the wire
# contract.
#
# == ⭐ THE FLOOR IS THE CENSUS'S OWN, READ — AND IT FILTERS A RANKED READ, NEVER A WRITE
#
# Slice 1 (SPGD-1544) applied no floor, so "these are near" and "these are merely the
# least-distant of everything" were byte-indistinguishable on the wire. Slice 2 (SPGD-1548) gives
# the read `NearDuplicateClusters::SIMILARITY` (0.85) — "as near as two tests the census itself
# would pair", the only semantic-similarity bar the system has — READ from the census, never
# restated, and disclosed on every answer as `similarity_floor`, in the census's own naming.
#
# ⛔ It is explicitly NOT `SpecIdentity::MATCH_SIMILARITY` (0.95): that constant is the *matching*
# threshold ("is this the same test?") and its own comment says the two must never share a
# constant. Importing it would answer "is this behavior already tested?" — the owner-rejected
# `/check-intent` posture. The floor discloses and filters a RANKED read; it never gates a write
# and never issues a verdict.
#
# * Membership compares the RAW `neighbor_distance` against `NearDuplicateClusters::DISTANCE`,
#   before the two-decimal display rounding, so rounding can never flip membership: a hit whose
#   similarity displays as exactly the floor still counts as near.
# * The floor is a Ruby post-filter. The ANN statement is byte-unchanged — no `threshold:`,
#   nothing added to the query — so the read keeps its measured shape and does not import
#   `MATCH_DISTANCE` semantics by accident.
# * Order of operations: floor-filter the hits, weigh the SERVED page only (no weight query is
#   spent on dropped hits), derive `signal_sources` composition in memory from the served page.
#
# Slices 3-4 of the roadmap own MCP reach and contract docs; none of that lives here.
#
# == The three silences are distinct, and the shape keeps them distinct
#
# A client that cannot tell "nothing is near" from "nothing was searched" from "the search could
# not run" has been handed an empty list wearing three different meanings. This block never
# hands one over:
#
# * `status: "provider_unconfigured"` — the deployment has no embedding provider configured
#   (`EmbeddingGenerator.configured?` is false), so no probe can be embedded. `ranked` is `nil`:
#   no ranking was attempted, and a `null` is not renderable as an empty list.
# * `status: "embedding_failed"` — the provider was asked and refused. Same `ranked: nil`, plus
#   the provider's own failure message in `error` — the same honesty convention the census
#   family holds for its mid-recompute window, moved to the one live failure this read has.
# * `status: "ok"` with `ranked: []` — the search RAN and found nothing near. Two different
#   findings wear this empty list, and the denominator that rides EVERY ok answer
#   (`identity_count`, one counted statement) tells them apart:
#   - `identity_count: 0` — the repository holds no identities (nothing has been ingested);
#   - `identity_count: N > 0` with `best_below_floor_similarity` — identities exist and none
#     reaches the floor. The nearest one's rounded similarity is served so "nothing near" is a
#     FINDING a client can verify, never a fabricated zero. It comes from the in-memory hits:
#     zero extra queries.
#
# == The cost, and why the guard behind the ask matters
#
# The no-ask path costs zero queries and zero embeds — the concern gate answers before this
# class is ever constructed. An ask costs: one fingerprint read (an environment read, not a
# query), one cache read, at most one embed per NOVEL probe (a paid HTTPS round trip on the
# shipped provider — a repeated probe is served from `EmbeddingCacheEntry` and buys nothing),
# one cache write on the miss, one ANN statement, one weight query (none when the floor leaves
# no hit to weigh) and one `identity_count` statement. The seam's `SET LOCAL` directive counts as
# a statement too, so the ok ask path costs four. That is why the
# parameter's guard is a value-carrying sibling's and not the flag's: the malformed shapes it
# refuses would otherwise bill the provider on every request a broken serializer makes.
#
# == The ANN statement goes through the seam, and the price answer is `false`
#
# `SpecIdentity.with_hnsw_planner_setup(correct_operator_price: false)` — the same answer
# `Ingest::IdentityResolver#nearest` gives, and for the same measured reason rather than a
# copied one: the seam's `correct_operator_price:` is each read's own per-call-site answer to a
# question the seam comment holds explicitly open ("should the price also apply to `#nearest`?"),
# and THIS read mirrors `#nearest`'s shape — one probe vector, tenant-filtered, top-N, the exact
# one-probe shape SPGD-375 measured directive-only at recall 1.000. It inherits that measured
# setup and does NOT answer the held-open price question on anyone's behalf; a second hand-rolled
# setup is forbidden by the seam's own comment and none exists here. The statement itself copies
# `#nearest`'s three deliberate differences for a top-N read: no `threshold:` (the floor is a
# Ruby post-filter, above), `.order(:id)` kept (it merges after the distance `ORDER BY` as the determinism
# tiebreak that forces the Incremental Sort — without it, tied distances could serve a different
# ten to identical asks), and the select list widened to what each hit discloses. The cap is
# `NearDuplicateClusters::NEIGHBOURS` read from the census rather than restated: 10 is the
# neighbour cap the census's own pair read uses, and one constant should stay one constant.
#
# == The weights are the latest run's, and the run rides the response's anchor
#
# The example/wall-clock weight per hit is measured over `spec_observations.spec_identity_id`
# scoped to ONE run — the same convention every `SpecObservation` aggregate holds (`spec_identity.rb`'s
# "the weight join is scoped to ONE run" section owns the argument: unscoped, the figures grow
# with how often the repository has ingested rather than with what its suite contains). The run
# is the caller's, passed in by `RepositoryOverview#serialized_near` as its `latest_test_run`
# memo — so a `?commit_sha=` ask weights the probe against the same run the rest of the body
# describes, and the read cannot name a different run from the blocks beside it. A run from
# another repository is a caller's bug and is refused, on
# `NearDuplicateClusters.validate_run!`'s rule. `nil` — a repository that has never ingested —
# weighs every hit at the census's unobserved semantics: `example_count` 0, `timed_count` 0,
# `total_seconds` nil, with no query issued.
#
# One grouped statement covers all ten hits, read off the same three aggregates the census's
# LATERAL weight join selects (`COUNT(*)`, `SUM(duration_seconds)`, `COUNT(duration_seconds)`).
# The census takes them inline in its pair-read SQL; this read cannot — it is a separate
# statement by the query budget's own pin, and folding it into the ANN statement (a `COUNT(*)
# OVER ()`-style widening) was rejected because it would stop the top-N scan from terminating
# early. A hit the run did not observe weighs 0 rather than being dropped, exactly as the
# census's members do.
class NearProbe
  # What the per-hit `similarity` number is a measurement OF, stated on the block in the census's
  # own `similarity_basis` convention: a similarity served without its basis is a confident figure
  # over nothing, and a client that must guess whether higher means nearer has already been failed.
  # The figure is pgvector's cosine distance (`embedding <=> probe`) subtracted from 1, rounded to
  # the two places `NearDuplicateClusters::Cluster#similarity_range` rounds to.
  SIMILARITY_BASIS = "pgvector cosine distance; similarity = 1 − distance, higher is nearer"

  # The floor a hit had to clear to be ranked — the census's own redundancy floor, read. A
  # method rather than a copied number: one constant stays one constant.
  def self.similarity_floor = NearDuplicateClusters::SIMILARITY

  STATUS_OK = "ok"
  STATUS_PROVIDER_UNCONFIGURED = "provider_unconfigured"
  STATUS_EMBEDDING_FAILED = "embedding_failed"

  class << self
    # @param repository [Repository] the tenant; identities are read only through its own relation.
    # @param probe [String] the behavior phrase, as the `?near=` guard admitted it.
    # @param run [TestRun, nil] the run the weights are measured in — the caller's anchor, not
    #   this class's choice. See the weights section above.
    def for(repository, probe, run: nil)
      new(repository, probe, run).answer
    end
  end

  def initialize(repository, probe, run)
    @repository = repository
    @probe = probe
    @run = run
  end

  def answer
    return status_answer(STATUS_PROVIDER_UNCONFIGURED) unless EmbeddingGenerator.configured?

    fingerprint = cache_fingerprint
    vector = cached_vector(fingerprint)

    if vector
      ranked_answer(fingerprint, true, vector)
    else
      vector = embed
      return embedding_failed_answer(fingerprint) if vector.nil?

      EmbeddingCacheEntry.store(fingerprint, @probe => vector) if fingerprint
      ranked_answer(fingerprint, false, vector)
    end
  end

  private

  attr_reader :repository, :probe, :run

  # The one live failure this read can produce, disclosed rather than swallowed into an empty
  # list. The class is always `EmbeddingGenerator::Error` — the interface wraps every provider
  # failure — so the message is the disclosure, and it carries the provider's own reason (an HTTP
  # status, a quota, a retired model) the operator has to read.
  def embedding_failed_answer(fingerprint)
    status_answer(STATUS_EMBEDDING_FAILED, fingerprint).merge(error: @embed_error.message)
  end

  def status_answer(status, fingerprint = EmbeddingGenerator.fingerprint)
    {
      status: status,
      provider_fingerprint: fingerprint,
      provider_model: provider_model,
      cache_served: nil,
      similarity_floor: self.class.similarity_floor,
      similarity_basis: SIMILARITY_BASIS,
      ranked: nil
    }
  end

  def ranked_answer(fingerprint, cache_served, vector)
    hits = ranked_hits(vector)
    served = hits.select { |hit| hit.neighbor_distance <= NearDuplicateClusters::DISTANCE }
    weights = weights_for(served)

    answer = {
      status: STATUS_OK,
      provider_fingerprint: fingerprint,
      provider_model: provider_model,
      cache_served: cache_served,
      similarity_floor: self.class.similarity_floor,
      similarity_basis: SIMILARITY_BASIS,
      weighed_run_id: run&.id,
      identity_count: repository.spec_identities.count,
      signal_sources: signal_sources_of(served),
      ranked: served.map { |hit| hit_payload(hit, weights) }
    }
    # Hits exist but none cleared the floor: state the nearest one's figure, from the same
    # in-memory objects, so "nothing near" is verifiable rather than a bare empty list.
    answer[:best_below_floor_similarity] = similarity_of(hits.first) if served.empty? && hits.any?
    answer
  end

  # Composition of the SERVED page by signal source, over `SpecIdentity::SOURCES` — measured
  # zeros over a page fully in hand, never absent keys.
  def signal_sources_of(served)
    SpecIdentity::SOURCES.index_with { |source| served.count { |hit| hit.signal_source == source } }
  end

  def similarity_of(hit) = (1 - hit.neighbor_distance).round(2)

  # The probe's own embed, mirroring `Ingest::IdentityResolver#embed_page`'s per-row fallback
  # register: the failure is caught HERE (not allowed to 500 an authenticated GET) and disclosed
  # by the answer shape. A nil is "no answer", never a zero vector — the nil is what makes the
  # failure branch above reachable and nothing else.
  def embed
    EmbeddingGenerator.call(probe)
  rescue EmbeddingGenerator::Error => e
    @embed_error = e
    nil
  end

  # The deployment's cache key, read per answer and never memoized — `EmbeddingGenerator.fingerprint`
  # is required to be recomputed on every call (a memoized one would keep authorising cache hits
  # from the model the process started with), and rescued to nil on the resolver's own rule: a
  # provider that cannot say what it is costs this read only the caching it declines to authorise.
  def cache_fingerprint
    EmbeddingGenerator.fingerprint
  rescue StandardError
    nil
  end

  def cached_vector(fingerprint)
    return nil if fingerprint.blank?

    EmbeddingCacheEntry.vectors_for(fingerprint, [probe])[probe]
  end

  # The model the provider is running, disclosed beside the fingerprint so a client reads the
  # embeddings-are-paid cost without parsing a fingerprint's gateway prefix. Read through a
  # capability probe rather than a constant, on `EmbeddingGenerator.configured?`'s own precedent:
  # a provider that publishes no `.model` — every spec stand-in — answers nil, which is the
  # disclosure rather than a fabricated name.
  def provider_model
    provider = EmbeddingGenerator.provider
    provider.respond_to?(:model) ? provider.model : nil
  end

  # THE RANKED READ — the one ANN statement this class issues, through the seam, at the price
  # answer the class comment owns. The statement's shape is `Ingest::IdentityResolver#nearest`'s
  # one-probe shape widened to a page and to the disclosure columns; see the class comment for
  # why the threshold is absent, why `.order(:id)` stays and why the cap is the census's.
  def ranked_hits(vector)
    SpecIdentity.with_hnsw_planner_setup(correct_operator_price: false) do
      repository.spec_identities
                .select(:id, :text, :text_digest, :signal_source, :file_path, :line_number)
                .nearest_neighbors(:embedding, vector, distance: "cosine")
                .order(:id)
                .limit(NearDuplicateClusters::NEIGHBOURS)
                .to_a
    end
  end

  # ONE grouped statement for the whole page, or none — a run that does not exist weighs nothing
  # and issues nothing. Hits the run did not observe fall back to the census's unobserved
  # semantics rather than being dropped, so every hit carries all three weight keys.
  def weights_for(hits)
    return EMPTY_WEIGHTS if run.nil? || hits.empty?

    if run.repository_id != repository.id
      raise ArgumentError,
            "run #{run.id} belongs to repository #{run.repository_id}, not #{repository.id} — " \
            "the weighed run must be the probed repository's own"
    end

    SpecObservation.where(test_run_id: run.id, spec_identity_id: hits.map(&:id))
                   .group(:spec_identity_id)
                   .pluck(:spec_identity_id,
                          Arel.sql("COUNT(*)"),
                          Arel.sql("SUM(duration_seconds)"),
                          Arel.sql("COUNT(duration_seconds)"))
                   .to_h do |identity_id, example_count, total_seconds, timed_count|
      [identity_id, { example_count: example_count, total_seconds: total_seconds,
                      timed_count: timed_count }]
    end
  end

  # ONE hit — the disclosed fields the ticket names, in the order they qualify the figure:
  # identity, where it was last seen, which evidence supplied its text, the similarity with the
  # block's basis already stated above it, and the weight the weighed run measured.
  def hit_payload(hit, weights)
    weight = weights[hit.id] || EMPTY_WEIGHTS

    {
      id: hit.id,
      text: hit.text,
      text_digest: hit.text_digest,
      signal_source: hit.signal_source,
      file_path: hit.file_path,
      line_number: hit.line_number,
      similarity: similarity_of(hit),
      example_count: weight[:example_count],
      total_seconds: weight[:total_seconds],
      timed_count: weight[:timed_count]
    }
  end

  # The census's unobserved-member semantics, as a shared empty: a hit the weighed run never
  # observed (deleted, renamed, not selected — or no run at all) weighs 0 examples, 0 timed and
  # no wall clock, rather than vanishing from the ranking.
  EMPTY_WEIGHTS = { example_count: 0, total_seconds: nil, timed_count: 0 }.freeze
end
