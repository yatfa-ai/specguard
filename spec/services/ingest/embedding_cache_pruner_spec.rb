# frozen_string_literal: true

require "rails_helper"

# The retention rule for `embedding_cache_entries`, which before this class bounded only what was
# SERVED: `live` kept an expired vector from ever being returned, and nothing on any path deleted a
# row, so the table grew forever at ~6KB per distinct text per fingerprint. `expired` had been
# written as the queryable half of the rule and had zero callers.
#
# Two directions are graded here and they are not the same claim. "The table stops growing" is
# trivially satisfiable by deleting everything, so every example that asserts a row went is paired
# with one asserting a row STAYED — and, for the live half, that the cache still SERVES it
# afterwards, which is the property a caller can actually observe and the one a cache-destroying
# implementation would fail.
RSpec.describe Ingest::EmbeddingCachePruner do
  # One deterministic vector, at the column's real width. `vector(1536)` is float4 per element, so a
  # round trip rounds — irrelevant to every assertion here, which are about WHICH ROWS exist, but
  # the width matters: it is what makes a row ~6KB and therefore what the batch size is chosen
  # against.
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
    it "bounds one invocation by a stated ceiling rather than by the size of the backlog" do
      expect(described_class::DELETE_BATCH_SIZE).to be_positive
      expect(described_class::MAX_BATCHES_PER_RESOLVE).to be_positive
    end

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
    it "deletes an entry that is past the window" do
      entries(3, age: expired_age)

      expect(described_class.prune).to eq(3)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

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
    it "leaves an entry that is inside the window, while taking the expired ones around it" do
      kept = entries(2, age: live_age, prefix: "live")
      entries(3, age: expired_age, prefix: "dead")

      expect(described_class.prune).to eq(3)

      expect(digests).to match_array(kept.map { |text| SpecIdentity.digest_for(text) })
    end

    it "still SERVES the surviving entry after a prune, which is what a caller can observe" do
      kept = entries(2, age: live_age, prefix: "live")
      entries(3, age: expired_age, prefix: "dead")

      described_class.prune

      found = EmbeddingCacheEntry.vectors_for(fingerprint, kept)
      expect(found.keys).to match_array(kept)
      # And the vector still round-trips, so what survived is an entry rather than a husk of one.
      drift = vector.zip(found.fetch(kept.first)).map { |mine, stored| (mine - stored).abs }.max
      expect(drift).to be < 1e-6
    end

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
    # many 1536-dimension vectors would be ~60MB of spec — the constants are the mechanism and the
    # numbers are not.
    before do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 2)
      stub_const("#{described_class}::MAX_BATCHES_PER_RESOLVE", 2)
    end

    it "reclaims exactly its ceiling when the backlog is larger, and the rest on the next pass" do
      entries(6, age: expired_age)

      expect(described_class.prune).to eq(4)
      expect(EmbeddingCacheEntry.count).to eq(2)

      expect(described_class.prune).to eq(2)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

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

    it "issues ONE statement for a batch that does not fill" do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 10)

      statements = deletes { described_class.prune }

      expect(statements.size).to eq(1)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

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

    it "issues one statement per batch as the batch narrows, never one per row" do
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 2)

      statements = deletes { described_class.prune }

      # Two full batches and a short third. A per-row implementation issues five here and five at
      # every other width above, which is what makes these three numbers a width falsifier rather
      # than three restatements of one fixture.
      expect(statements.size).to eq(3)
      expect(EmbeddingCacheEntry.count).to eq(0)
    end

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

    it "costs nothing at all when there is nothing past the window" do
      EmbeddingCacheEntry.update_all(updated_at: live_age)

      # One statement, not zero: the sweep cannot know the backlog is empty without asking. What is
      # pinned is that an empty backlog costs ONE round trip and never the ceiling's five.
      expect(deletes { described_class.prune }.size).to eq(1)
      expect(EmbeddingCacheEntry.count).to eq(5)
    end
  end
end
