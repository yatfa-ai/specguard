# frozen_string_literal: true

require "rails_helper"

# The retention rule for `embedding_cache_entries`, which before this class bounded only what was
# SERVED: `live` kept an expired vector from ever being returned, and nothing on any path deleted a
# row, so the table grew forever at ~8.5KB of disk per distinct text per fingerprint. `expired` had
# been written as the queryable half of the rule and had zero callers.
#
# Two directions are graded here and they are not the same claim. "The table stops growing" is
# trivially satisfiable by deleting everything, so every example that asserts a row went is paired
# with one asserting a row STAYED — and, for the live half, that the cache still SERVES it
# afterwards, which is the property a caller can actually observe and the one a cache-destroying
# implementation would fail.
RSpec.describe Ingest::EmbeddingCachePruner do
  # One deterministic vector, at the column's real width. `vector(1024)` is float4 per element, so a
  # round trip rounds — irrelevant to every assertion here, which are about WHICH ROWS exist, but
  # the width matters INDIRECTLY, and not the way this comment used to say. It does not make the
  # ROW ~6KB: the column is stored out of line, so the heap tuple is a 168-byte stub. What the width
  # drives is 6,148 logical bytes into four TOAST chunks — ~8.5KB of disk per row once the chunk
  # overhead is counted — and THAT is what the batch size is chosen against. See
  # `Ingest::EmbeddingCachePruner::DELETE_BATCH_SIZE` for the measurement.
  let(:vector) { Array.new(EmbeddingGenerator::DIMENSIONS) { |i| (i % 7) / 7.0 } }
  let(:fingerprint) { "test-provider:v1" }

  # `count` cache entries, aged by moving BOTH timestamps — the shape a genuinely old row has, and
  # the reason it is both is that this fixture has to be able to discriminate them. A row written 91
  # days ago has an old `created_at` AND an old `updated_at`; only a REVIVAL separates the two, by
  # moving `updated_at` and leaving `created_at` at the first insert. Aging only `updated_at` here
  # would make every row look like a revived one, and the "not deleted after revival" example below
  # would then pass against a sweeper reading either column.
  #
  # Written through the real `EmbeddingCacheEntry.store` rather than by `insert_all` so the rows
  # carry exactly what the one production writer puts on them (SPGD-91: a fixture that can build
  # what the producer cannot).
  #
  # @return [Array<String>] the texts, so an example can name the digests it expects to survive.
  def entries(count, age:, prefix: "text")
    texts = Array.new(count) { |index| "#{prefix} #{index}" }
    EmbeddingCacheEntry.store(fingerprint, texts.to_h { |text| [text, vector] })
    EmbeddingCacheEntry.where(text_digest: texts.map { |text| SpecIdentity.digest_for(text) })
                       .update_all(created_at: age, updated_at: age)

    texts
  end

  def expired_age = (EmbeddingCacheEntry::RETENTION_WINDOW + 1.day).ago
  def live_age = (EmbeddingCacheEntry::RETENTION_WINDOW - 1.day).ago
  def digests = EmbeddingCacheEntry.pluck(:text_digest)

  describe "the ceiling it works under" do
    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune under a stated ceiling", behavior: "the batch-size and batches-per-resolve constants are declared positive, so each invocation is bounded by declaration rather than by backlog size", layer: "unit" }
    it "bounds one invocation by a stated ceiling rather than by the size of the backlog" do
      expect(described_class::DELETE_BATCH_SIZE).to be_positive
      expect(described_class::MAX_BATCHES_PER_RESOLVE).to be_positive
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune expired cache entries", behavior: "candidates come from the same expired scope the read path uses, so one window definition governs both serving and deletion", layer: "integration" }
    it "reads the same set the read filter does, rather than a second spelling of the window" do
      # The disk rule and the read rule are ONE definition. A sweeper that re-derived the window —
      # `created_at`, say, which is the plausible mistake because it is the column that does not
      # move — would delete rows the `upsert_all` had just revived and that `.vectors_for` was
      # serving. Asserted as the scope being the thing that names the candidates.
      entries(1, age: expired_age)

      expect(EmbeddingCacheEntry.expired.count).to eq(1)
      expect { described_class.prune }.to change(EmbeddingCacheEntry, :count).from(1).to(0)
    end
  end

  describe "what it reclaims" do
    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune past-window entries", behavior: "every entry older than the retention window is deleted and the reclaim count returned equals the rows removed", layer: "integration" }
    it "deletes an entry that is past the window" do
      entries(3, age: expired_age)

      expect(described_class.prune).to eq(3)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune with no expired rows", behavior: "the sweep is a no-op: zero deletions and the table unchanged when every entry sits inside the window", layer: "integration" }
    it "does nothing at all when every entry is inside the window" do
      entries(3, age: live_age)

      expect(described_class.prune).to eq(0)
      expect(EmbeddingCacheEntry.count).to eq(3)
    end

    # ⭐ **The counterweight, and without it this file grades a cache-destroying implementation as a
    # pass.** Every example above is satisfied by `delete_all`. These two are the other direction:
    # the live row survives, and — the half that is actually observable to a caller — the cache
    # still ANSWERS for it afterwards. A sweep that left the row but broke the read would pass a
    # count assertion and have destroyed the thing this table exists for.
    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune a mixed table", behavior: "only the expired digests disappear; the live entries remain the entire surviving table, defeating a delete-all implementation", layer: "integration" }
    it "leaves an entry that is inside the window, while taking the expired ones around it" do
      kept = entries(2, age: live_age, prefix: "live")
      entries(3, age: expired_age, prefix: "dead")

      expect(described_class.prune).to eq(3)

      expect(digests).to match_array(kept.map { |text| SpecIdentity.digest_for(text) })
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "serve survivors after pruning", behavior: "vectors_for still returns round-trippable vectors for surviving rows, with a tolerance that sits between half-precision noise and a zeroed husk", layer: "integration" }
    it "still SERVES the surviving entry after a prune, which is what a caller can observe" do
      kept = entries(2, age: live_age, prefix: "live")
      entries(3, age: expired_age, prefix: "dead")

      described_class.prune

      found = EmbeddingCacheEntry.vectors_for(fingerprint, kept)
      expect(found.keys).to match_array(kept)
      # And the vector still round-trips, so what survived is an entry rather than a husk of one.
      # Within the TWO-byte float the `halfvec(1024)` column stores — IEEE half, an 11-bit
      # significand — against Ruby's float8: a round trip moves a component of magnitude at most 1
      # by at most 2**-11 ≈ 4.9e-4, and this fixture's largest is 6/7. The same `1e-3` for the same
      # reason as `spec/models/embedding_cache_entry_spec.rb` and the two identity-resolver
      # examples. Until 2026-08-17 the column was `vector(1536)` and this bound was `1e-6`; the
      # migration to `halfvec` made the substrate four orders of magnitude coarser.
      #
      # Bound to one name, asserted in one comparison, for the reason the identity-resolver
      # examples set out: this number moved three orders of magnitude in that migration, and a
      # separate "and a husk fails it" assertion alongside would not have stopped the next such
      # move, because loosening the one that had gone red leaves the other green.
      round_trip_tolerance = 1e-3

      round_trip = vector.zip(found.fetch(kept.first)).map { |mine, stored| (mine - stored).abs }.max
      # A husk — a row that survived the sweep with its vector zeroed — is what the round trip is
      # being distinguished FROM, so it is the far side of the same bound. Compared in Ruby rather
      # than built in the database: the point is the DISCRIMINATING POWER of the tolerance, not
      # that the pruner can produce a husk, and 6/7 is this fixture's largest component.
      husk_drift = vector.map(&:abs).max

      # ⭐ The tolerance lives strictly between what a real round trip costs and what a husk would,
      # and says so once. Measured: the round trip is ~2.1e-4 and the husk is 0.857, so `1e-3`
      # clears the noise by ~5x and sits ~860x under the signal.
      expect(round_trip_tolerance).to be_between(round_trip, husk_drift).exclusive
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune around revived entries", behavior: "an expired entry whose updated_at was refreshed by a re-embed survives and is still served, so the window keys on updated_at not created_at", layer: "integration" }
    it "does not delete an expired entry that has since been REVIVED by a re-embed" do
      # The `upsert_all` `on_duplicate` path, and the one case in which the two timestamp columns
      # disagree: a text that expired and was then embedded again moves `updated_at` to now and
      # leaves `created_at` at the first insert. So the row is `live` and `.vectors_for` serves it,
      # while `created_at` still reads 91 days old.
      #
      # ⭐ That disagreement is the whole discriminator. A sweep reading `created_at` — the
      # plausible mistake, because it is the column that does not move — deletes the row of a text
      # this deployment is actively using, and the symptom is a permanent re-embed of exactly the
      # texts used most, with no error anywhere. The migration says `updated_at` and not
      # `created_at` for this reason; this is that sentence made falsifiable.
      texts = entries(1, age: expired_age, prefix: "hot")
      EmbeddingCacheEntry.store(fingerprint, { texts.first => vector })

      row = EmbeddingCacheEntry.sole
      expect(row.created_at).to be < EmbeddingCacheEntry::RETENTION_WINDOW.ago # the trap is armed
      expect(row.updated_at).to be > EmbeddingCacheEntry::RETENTION_WINDOW.ago

      expect(described_class.prune).to eq(0)
      expect(EmbeddingCacheEntry.vectors_for(fingerprint, texts).keys).to eq(texts)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune across fingerprints", behavior: "expired rows are swept under every provider fingerprint, including retired ones, because the table key carries no tenant column", layer: "integration" }
    it "reaches every fingerprint's expired rows, because the key carries no tenant" do
      # ⭐ The asymmetry against `Ingest::ObservationPruner`, asserted rather than argued. That class
      # is handed a run and reaches only its branch's rows, so a population nothing is writing to is
      # frozen out of its reach by construction. This table is keyed `(provider_fingerprint,
      # text_digest)` with no `repository_id` and no `branch`, so there is no bucket an invocation
      # cannot see — including rows written under a fingerprint this deployment has since retired
      # and can no longer read at all.
      entries(2, age: expired_age, prefix: "current")
      EmbeddingCacheEntry.store("retired-provider:v0", { "written under the old model" => vector })
      EmbeddingCacheEntry.where(provider_fingerprint: "retired-provider:v0")
                         .update_all(updated_at: expired_age)

      expect(described_class.prune).to eq(3)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end
  end

  describe "convergence across invocations" do
    # The ceiling is a bound on ONE invocation, so what it buys is convergence rather than
    # completeness. Stubbed small because the shipped ceiling is 10,000 rows and a fixture of that
    # many 1024-dimension vectors would be ~81MB of spec — the constants are the mechanism and the
    # numbers are not.
    before do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 2)
      stub_const("#{described_class}::MAX_BATCHES_PER_RESOLVE", 2)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune with a stubbed ceiling", behavior: "one pass reclaims exactly batch size times batches allowed and the remainder drains on the following pass", layer: "integration" }
    it "reclaims exactly its ceiling when the backlog is larger, and the rest on the next pass" do
      entries(6, age: expired_age)

      expect(described_class.prune).to eq(4)
      expect(EmbeddingCacheEntry.count).to eq(2)

      expect(described_class.prune).to eq(2)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune repeatedly", behavior: "successive passes walk any backlog to zero without naming rows: every candidate is past the window, so whichever batch the planner picks is progress", layer: "integration" }
    it "converges whichever rows a batch happened to reach" do
      # The non-stall argument, pinned as a property rather than as an ordering. `delete_batch`
      # issues no `ORDER BY` and WHICH expired rows a batch reaches is the planner's business — the
      # loop cannot stall because every candidate is already past the window, so any batch is
      # progress and the work left is strictly smaller by exactly what was deleted. Asserted by
      # walking a backlog down to zero without ever naming a row.
      entries(5, age: expired_age)

      reclaimed = 3.times.sum { described_class.prune }

      expect(reclaimed).to eq(5)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end
  end

  describe "what one invocation costs" do
    # ⭐ The claim is that the delete is issued PER BATCH and not per row, and it is graded by the
    # statements actually issued — `spec/support/query_capture.rb`'s `executed_sql`, which drops
    # cached repeats and `SCHEMA`/`TRANSACTION` so what is counted is round trips paid for.
    #
    # An absolute constant at each width, and the widths are chosen so a per-row implementation
    # cannot pass any of them: five expired rows cost five statements per-row, and one, two and
    # three here. Pinning a single width would leave the claim satisfiable by a batch size that
    # happened to equal the fixture.
    #
    # Nothing below asserts a PLAN. Whether the candidate scan uses
    # `index_embedding_cache_entries_on_updated_at` is the planner's choice on cost, not a strategy
    # this query forces, and on a five-row table it will correctly decline the index — an EXPLAIN
    # assertion here would be a statement about Postgres's discretion rather than about this class
    # (SPGD-273 P7a/P7d). The index claim is graded out of band and stated where it is made.
    def deletes(&) = executed_sql(&).grep(/\ADELETE\b/)

    before { entries(5, age: expired_age) }

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune a short batch", behavior: "an under-full batch costs exactly one DELETE statement, proving deletes are issued per batch rather than per row", layer: "integration" }
    it "issues ONE statement for a batch that does not fill" do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 10)

      statements = deletes { described_class.prune }

      expect(statements.size).to eq(1)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune an exactly full batch", behavior: "a full batch is followed by one extra probing DELETE that returns nothing, exposing the batch-boundary loop shape", layer: "integration" }
    it "issues one probing statement more when the batch is EXACTLY full" do
      # The batch boundary, which an under-full fixture is structurally unable to exhibit: the loop
      # stops on a SHORT batch, so a full one is always followed by a statement that returns
      # nothing. Measured at the width the claim is about rather than at the convenient one
      # (SPGD-273 P8a) — two statements for five rows is still the batched shape, and five would be
      # the per-row one.
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 5)

      statements = deletes { described_class.prune }

      expect(statements.size).to eq(2)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune at a narrow batch width", behavior: "statement count scales with batches (three at width two for five rows) rather than with rows, falsifying a per-row delete at multiple widths", layer: "integration" }
    it "issues one statement per batch as the batch narrows, never one per row" do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 2)

      statements = deletes { described_class.prune }

      # Two full batches and a short third. A per-row implementation issues five here and five at
      # every other width above, which is what makes these three numbers a width falsifier rather
      # than three restatements of one fixture.
      expect(statements.size).to eq(3)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune with a SQL-bound batch", behavior: "the delete is one statement carrying its own IN (SELECT ... LIMIT) bound, never a Ruby-side candidate load costing two round trips per batch", layer: "integration" }
    it "bounds the statement in SQL rather than loading the candidates into Ruby" do
      # `DELETE ... WHERE id IN (SELECT id ... LIMIT n)` — one statement per batch, with the bound
      # inside it. An implementation that selected the ids and then deleted them would issue two
      # round trips per batch and would be reading the candidate set into the process, which is the
      # shape this table's size makes expensive.
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 10)

      statements = executed_sql { described_class.prune }

      expect(statements.size).to eq(1)
      expect(statements.sole).to match(/\ADELETE\b.*\bIN \(SELECT\b.*\bLIMIT\b/mi)
    end

    # @intent: { entity: "Ingest::EmbeddingCachePruner", action: "prune an empty backlog", behavior: "when nothing is past the window the sweep pays one probing DELETE and deletes nothing, never the ceiling worth of statements", layer: "integration" }
    it "costs nothing at all when there is nothing past the window" do
      EmbeddingCacheEntry.update_all(updated_at: live_age)

      # One statement, not zero: the sweep cannot know the backlog is empty without asking. What is
      # pinned is that an empty backlog costs ONE round trip and never the ceiling's five.
      expect(deletes { described_class.prune }.size).to eq(1)
      expect(EmbeddingCacheEntry.count).to eq(5)
    end
  end
end
