# frozen_string_literal: true

# ANN recall audit for `Ingest::IdentityResolver#nearest` at the 20,000-per-tenant design point,
# and threshold calibration for `SpecIdentity::MATCH_SIMILARITY` under the shipped provider.
# Raised by SPGD-375; its numbers are recorded on that ticket and in the comment blocks it rewrote
# (`spec_identity.rb`'s MATCH_SIMILARITY rationale and `identity_resolver.rb`'s #nearest comment).
#
# == The question
#
# `#nearest` is an HNSW `nearest_neighbors` scan over the WHOLE `spec_identities` table with
# `repository_id` applied only to the candidates that come back. HNSW produces `hnsw.ef_search`
# candidates (default 40) globally, so once the table is large across all tenants, a small
# tenant's true nearest neighbour can fall outside them: a second identity for a test that
# already had one, and a history split in two. Does that happen at the design point, what does
# each candidate mitigation cost on a MISS (a repository's first ingest is 20,000 consecutive
# misses), and — separately — where does `MATCH_SIMILARITY` sit for the provider actually
# installed (`EmbeddingGenerator::VoyageProvider`), which the current 0.95 was never measured on?
#
# == How to run
#
#   bin/rails runner script/ann_recall_audit.rb recall      # the recall grid + miss costs
#   bin/rails runner script/ann_recall_audit.rb calibrate   # MATCH_SIMILARITY bands (needs a key)
#
# `recall` talks only to the database it is pointed at — set `DATABASE_URL` to a THROWAWAY
# database; it TRUNCATES `spec_identities` and inserts ~80k rows. The corpus is synthetic (see
# below), so it costs no embedding requests and needs no API key. `calibrate` embeds ~30 REAL
# texts through the shipped provider and therefore bills; it refuses to run without
# OPENROUTER_API_KEY rather than quietly measuring a stand-in.
#
# == Ground truth, and what is deliberately NOT used as ground truth
#
# Truth is the SAME query with index scans disabled (`SET LOCAL enable_indexscan = off; SET LOCAL
# enable_bitmapscan = off` inside the surrounding transaction): a sequential scan computes exact
# distances for every row, orders them, and applies the same `threshold:` — so both sides of every
# comparison are the shipped query, differing only in the access path. What is NOT truth: a
# hand-written kNN reimplementation in Ruby (floats round differently through halfvec), and
# recall asserted in the RSpec suite (at test-suite table sizes the planner scans outright and a
# seq scan is exact, so the assertion is vacuous — it passes before and after any change here).
# The spec that shipped beside this script asserts the MECHANISM (the chosen GUCs are issued on
# the connection for this query); the recall numbers live here and on the ticket.
#
# == The synthetic corpus, and what it assumes
#
# HNSW recall is a property of the GEOMETRY around the query — how many rows crowd the
# neighbourhood the candidate set is drawn from — not of where the vectors came from. The corpus
# therefore reproduces the geometry the exposure needs, not the texts:
#
#   * ~800 cluster centres (random unit vectors): unrelated tests are near-orthogonal under a
#     semantic model, which is what cross-cluster looks like (cosine ~0).
#   * Each cluster holds ~100 members at cosine ~0.60–0.95 from its centre, spread across the
#     LARGE tenants. A semantic model scores same-domain tests like this — shared vocabulary,
#     different tests. This is the crowding that fills an `ef_search`-sized candidate list.
#   * The SMALL tenant's rows are members of the same clusters — a small codebase tests the same
#     things everyone else tests, which is the realistic tenant distribution and the one a
#     uniform distribution cannot express.
#   * Each probe is a small tenant row nudged to cosine ~0.96–0.995 of that row: inside the
#     match band, byte-different (so neither `#identical_text` nor the digest key can catch it),
#     and with dozens of large-tenant rows at comparable distance competing for the candidates.
#
# Assumption stated plainly: real `voyage-4-lite` vectors are not Gaussian clusters. What the
# recall result claims, and all it claims, is the behaviour of HNSW candidate selection under
# neighbour densities of this shape and width — the axis `ef_search` and `iterative_scan` act
# on. Run with VOYAGE_SEED=1 and a key to seed cluster centres from real Voyage embeddings of
# generated test descriptions (one `embed_many` call, ~800 requests' worth in ONE batch) if a
# second opinion on the geometry is wanted.
#
# == Where the numbers are recorded
#
# Printed to STDOUT (reproducibly: this script, the pgvector/PG versions it prints, and the seed),
# on ticket SPGD-375, and in the comment blocks this ticket rewrote. Recorded 2026-08-28 on
# PostgreSQL 17.9 / pgvector 0.8.6 (read from `pg_extension`, not assumed).

SEED = Integer(ENV.fetch("ANN_AUDIT_SEED", "375"))

LARGE_TENANTS = 4
LARGE_ROWS    = 20_000   # the design point
SMALL_ROWS    = 100
CLUSTERS      = 800

# `hnsw.ef_search` grid and the iterative-scan settings tried, per the ticket: raising ef_search,
# iterative scan (needs pgvector >= 0.8.0, checked below from pg_extension), and stock.
EF_GRID       = [40, 80, 200, 400].freeze
SCAN_SETTINGS = %w[off relaxed_order].freeze

Audit = Struct.new(:extversion, :pg_version, :plans, :rows) do
  def header
    <<~HEAD
      # ANN recall audit — #nearest at the #{LARGE_TENANTS}x#{LARGE_ROWS}+#{SMALL_ROWS} design point
      #   PostgreSQL #{pg_version}, pgvector #{extversion} (read from pg_extension)
      #   seed #{SEED} — rerun with ANN_AUDIT_SEED=#{SEED} to reproduce
    HEAD
  end
end

# ---------------------------------------------------------------------------
# Vector helpers. Plain Ruby: the corpus is built once and written once, and every
# distance the RESULT depends on comes from Postgres itself, never from these.
# ---------------------------------------------------------------------------
module V
  module_function

  def rng = @rng ||= Random.new(SEED)

  def unit(vector)
    m = Math.sqrt(vector.sum { |v| v * v })
    vector.map { |v| v / m }
  end

  def random_unit(dim)
    v = Array.new(dim) { rng.rand(-1.0..1.0) }
    unit(v)
  end

  # `base` scaled toward/away from `target_cos` along the line to `noise`:
  # returns a unit vector whose cosine with `base` is ~`target_cos`.
  def nudge(base, target_cos, dim)
    loop do
      n = noise_v(dim)
      candidate = unit(base.each_index.map { |i| base[i] * target_cos + n[i] * Math.sqrt(1 - target_cos**2) })
      c = cos(base, candidate)
      return candidate if (c - target_cos).abs < 0.01
      @noise_v = nil
    end
  end

  def noise_v(dim) = (@noise_v ||= random_unit(dim))

  def cos(a, b)
    s = a.each_index.sum { |i| a[i] * b[i] }
    s.clamp(-1.0, 1.0)
  end
end

# ---------------------------------------------------------------------------
# Corpus construction
# ---------------------------------------------------------------------------
def build_corpus(dim)
  clusters = Array.new(CLUSTERS) { V.random_unit(dim) }

  # Spread each cluster's membership across the LARGE tenants; the small tenant shares the
  # same clusters (see the header's corpus section).
  identities = []
  next_member = ->(cluster_idx, tenant_idx, row_idx) do
    centre = clusters[cluster_idx]
    target = 0.60 + V.rng.rand * 0.35 # cosine from centre
    vec = V.nudge(centre, target, dim)
    identities << [tenant_idx, vec, "cluster #{cluster_idx} member #{row_idx}"]
  end

  # Large tenants: LARGE_TENANTS x LARGE_ROWS spread round-robin over clusters.
  (LARGE_TENANTS * LARGE_ROWS).times do |i|
    next_member.call(i % CLUSTERS, i % LARGE_TENANTS, i / LARGE_TENANTS)
  end
  # Small tenant: SMALL_ROWS, one per chosen cluster.
  probes = []
  SMALL_ROWS.times do |i|
    cluster_idx = V.rng.rand(CLUSTERS)
    next_member.call(cluster_idx, LARGE_TENANTS, i) # tenant index LARGE_TENANTS == the small one
    # The probe for this row: cosine ~0.96–0.995 with it — inside the band, bytes different.
    probes << V.nudge(identities.last[1], 0.96 + V.rng.rand * 0.035, dim)
  end

  [identities, probes]
end

def insert_identities!(identities)
  ActiveRecord::Base.connection.execute("TRUNCATE spec_identities, repositories, users RESTART IDENTITY CASCADE")
  user = User.create!(github_uid: "audit-#{SEED}", github_handle: "audit")
  tenants = (LARGE_TENANTS + 1).times.map do |i|
    user.repositories.create!(
      github_full_name: "audit/tenant-#{i}", name: "tenant-#{i}"
    )
  end

  now = Time.current
  identities.each_slice(1000) do |slice|
    rows = slice.map do |tenant_idx, vec, text|
      digest = Digest::SHA256.hexdigest(text)
      tenant = tenants[tenant_idx]
      "(#{tenant.id}, '#{text.gsub(%r{'}, "''")}', '#{digest}', 'name', 1, 'a.rb', " \
        "'[#{vec.map { |v| format('%.6f', v) }.join(',')}]', '#{now.strftime('%F %T')}', '#{now.strftime('%F %T')}')"
    end
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO spec_identities
        (repository_id, text, text_digest, signal_source, line_number, file_path, embedding, created_at, updated_at)
      VALUES #{rows.join(', ')}
    SQL
    print "\r  inserted #{slice.size}..."
  end
  puts "\n"
  tenants
end

# ---------------------------------------------------------------------------
# The shipped query, verbatim in shape: `#nearest`'s chain, scoped to one repository.
# Both sides of every comparison go through THIS method, differing only in GUCs —
# ground truth is not a reimplementation, it is this query with index scans off.
# ---------------------------------------------------------------------------
def nearest_for(repository, embedding, gucs = {})
  result = nil
  SpecIdentity.transaction do
    gucs.each { |name, value| SpecIdentity.connection.execute("SET LOCAL #{name} = #{value}") }
    result = repository.spec_identities
                      .select(:id, :text, :text_digest, :signal_source)
                      .nearest_neighbors(:embedding, embedding, distance: "cosine",
                                         threshold: SpecIdentity::MATCH_DISTANCE)
                      .order(:id)
                      .first
    raise ActiveRecord::Rollback
  end
  result
end

def plan_for(repository, embedding, gucs = {})
  sql = nil
  SpecIdentity.transaction(requires_new: true) do
    gucs.each { |name, value| SpecIdentity.connection.execute("SET LOCAL #{name} = #{value}") }
    rel = repository.spec_identities
                    .select(:id, :text, :text_digest, :signal_source)
                    .nearest_neighbors(:embedding, embedding, distance: "cosine",
                                       threshold: SpecIdentity::MATCH_DISTANCE)
                    .order(:id).limit(1)
    sql = SpecIdentity.connection.unprepared_statement { rel.to_sql }
    raise ActiveRecord::Rollback
  end
  ActiveRecord::Base.connection.select_rows("EXPLAIN #{sql}").map(&:first).join("\n")
end

def timed(label)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  [result, ms]
end

# ---------------------------------------------------------------------------
# recall mode
# ---------------------------------------------------------------------------
def run_recall
  conn = ActiveRecord::Base.connection
  extversion = conn.select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
  pg_version = conn.select_value("SHOW server_version")
  raise "pgvector #{extversion} < 0.8.0 — iterative_scan unavailable; that is a finding, not a blocker" if Gem::Version.new(extversion.to_s) < Gem::Version.new("0.8.0")

  dim = EmbeddingGenerator::DIMENSIONS
  puts "Building synthetic corpus (#{LARGE_TENANTS}x#{LARGE_ROWS} + #{SMALL_ROWS} rows, #{CLUSTERS} clusters)…"
  identities, probes = build_corpus(dim)
  tenants = insert_identities!(identities)
  small = tenants.last

  # ANALYZE so the planner sees real statistics, then report which plan it CHOOSES at stock
  # costs — the ticket's precondition is a size where the planner genuinely uses the HNSW index.
  conn.execute("ANALYZE spec_identities")
  puts Audit.new(extversion, pg_version, nil, nil).header

  probe0 = probes.first
  puts "== Planner's own choice for the SMALL tenant (stock costs, no GUCs forced):"
  puts plan_for(small, probe0, {})
  puts "== Planner's own choice for a LARGE tenant (stock costs, no GUCs forced):"
  puts plan_for(tenants.first, probe0, {})

  # The mitigation grid, run per tenant shape. Both sides of every comparison are the shipped
  # query; truth is it with index scans off, and `hnsw.ef_search`/`hnsw.iterative_scan` are the
  # only knobs varied. Miss probes are vectors unrelated to the corpus — the first-ingest case.
  miss_probes = Array.new(30) { V.random_unit(dim) }
  tenant_grid = lambda do |tenant, probes_for, label|
    puts "\n== #{label} — recall@1 vs exact truth, hit ms, MISS ms"
    puts format("%-36s %10s %11s %13s", "config", "recall@1", "hit ms", "MISS ms")
    truth_ids = probes_for.map do |p|
      nearest_for(tenant, p, { "enable_indexscan" => "off", "enable_bitmapscan" => "off" })&.id
    end
    truth_hits = truth_ids.count(&:itself)
    puts "   probes: #{probes_for.size}, exact-truth matches: #{truth_hits}"

    ([["planner default", {}]] + SCAN_SETTINGS.product(EF_GRID).map do |scan, ef|
      gucs = { "hnsw.ef_search" => ef.to_s }
      gucs["hnsw.iterative_scan"] = scan unless scan == "off"
      ["ef_search=#{ef} scan=#{scan}", gucs]
    end).each do |label2, gucs|
      got = probes_for.map { |p| nearest_for(tenant, p, gucs)&.id }
      hits = got.zip(truth_ids).count { |g, t| !t.nil? && g == t }
      recall = truth_hits.zero? ? Float::NAN : hits.to_f / truth_hits
      hit_ms = probes_for.first(30).map { |p| timed(nil) { nearest_for(tenant, p, gucs) }.last }.sum / [probes_for.size, 30].min
      miss_ms = miss_probes.map { |p| timed(nil) { nearest_for(tenant, p, gucs) }.last }.sum / miss_probes.size
      puts format("%-36s %10.3f %11.1f %13.1f", label2, recall, hit_ms, miss_ms)
    end
  end

  # Small-tenant probes are the nudged near-duplicates built with the corpus; the large tenant's
  # are built the same way from ITS OWN first rows, so both grids ask the same question of the
  # shape the planner actually gives each of them.
  large = tenants.first
  large_members = identities.each_index.select { |i| identities[i][0].zero? }.first(100)
  large_probes = large_members.map do |i|
    V.nudge(identities[i][1], 0.96 + V.rng.rand * 0.035, dim)
  end
  tenant_grid.call(small, probes, "SMALL tenant (#{SMALL_ROWS} rows) grid")
  tenant_grid.call(large, large_probes, "LARGE tenant (#{LARGE_ROWS} rows) grid")

  puts "\nDone. Record these on SPGD-375 with the versions above."
end

# ---------------------------------------------------------------------------
# calibrate mode — MATCH_SIMILARITY bands under the SHIPPED provider.
# ---------------------------------------------------------------------------
PAIRS = [
  # [band, text_a, text_b] — both sides embedded for real; cosine computed from the vectors.
  %w[whitespace/punct Order#checkout rejects an expired card Order  checkout   rejects an expired card!],
  %w[whitespace/punct user login with a valid password user login with a valid  password],
  %w[typo recalculates the invoice total recalculates the invoice totall],
  %w[typo retruns a 404 for a missing page returns a 404 for a missing page],
  %w[singular/plural creates a new project creates new projects],
  %w[singular/plural assigns the ticket to the agent assigns the tickets to the agents],
  %w[word-appended exports the report as CSV exports the report as CSV with headers],
  %w[lexically-similar-different rejects a card that has expired rejects a card that was stolen],
  %w[lexically-similar-different user login with a valid password user login with an invalid password],
  %w[reworded-behaviour the checkout refuses cards past their expiry the card is declined once it has lapsed],
  %w[reworded-behaviour sends an email when the build fails notifies the committer on a broken build],
  %w[sibling-example retries the request twice retries the request three times],
  %w[unrelated-rename handles pagination of results sorts the warehouse by capacity],
  %w[identical exports the report as CSV exports the report as CSV]
].freeze

def run_calibrate
  unless EmbeddingGenerator.configured?
    abort <<~MSG
      embedding provider is not configured — set OPENROUTER_API_KEY.
      Calibration embeds ~28 REAL texts through VoyageProvider (~1 billed batch) and is the only
      half of this audit that needs a key; the recall half does not. Refusing rather than
      quietly measuring a stand-in: a stub's scores say nothing about MATCH_SIMILARITY.
  MSG
  end

  texts = PAIRS.flat_map { |_, a, b| [a, b] }.uniq
  vectors = EmbeddingGenerator.embed_many(texts)
  by_text = texts.zip(vectors).to_h

  puts "# MATCH_SIMILARITY calibration — #{EmbeddingGenerator.provider.name rescue 'provider'}"
  puts format("%-28s %8s  %s", "band", "cosine", "a vs b")
  PAIRS.each do |band, a, b|
    va = by_text.fetch(a)
    vb = by_text.fetch(b)
    cosine = va.each_index.sum { |i| va[i] * vb[i] }
    puts format("%-28s %8.4f  %s | %s", band, cosine, a, b)
  end
  puts "\nCurrent MATCH_SIMILARITY = #{SpecIdentity::MATCH_SIMILARITY}. Record on SPGD-375."
end

case ARGV.first
when "recall"    then run_recall
when "calibrate" then run_calibrate
else
  abort "usage: bin/rails runner script/ann_recall_audit.rb [recall|calibrate] — read the header of this file first"
end
