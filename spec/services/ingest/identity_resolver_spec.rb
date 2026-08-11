# frozen_string_literal: true

require "rails_helper"

# Driven through the real ingest path — `Ingest::Payload` + `Ingest::RunRecorder` — rather than by
# hand-building `spec_observations`. The columns the resolver reads (`intent_entity`,
# `intent_action`, `intent_behavior`, `name`) are written by `Ingest::ObservationRecorder`, so a
# hand-built row could carry an intent no producer can actually deliver and the suite would go green
# on a state production never reaches (SPGD-91, *The Fixture Can Build What the Producer Cannot*).
RSpec.describe Ingest::IdentityResolver do
  include_context "with lexical embeddings"

  let(:repository) { create_repository }

  # One suite, at a line offset. Three examples: one annotated, two not, so every run exercises both
  # halves of `Ingest::SpecSignal`'s precedence at once.
  def suite(offset: 0, annotated_name: "Invoice#finalize locks the line items",
            renamed: "User#save rejects a duplicate email")
    [
      annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 10 + offset,
                     name: annotated_name),
      unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 20 + offset,
                       name: renamed),
      unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5 + offset,
                       name: "Cart adds an item to the cart")
    ]
  end

  # One CI run, ingested and then resolved, exactly as the endpoint and its job do it.
  def ingest(specs, ci_run_id:)
    record(specs, ci_run_id: ci_run_id).tap { |run| described_class.resolve(run) }
  end

  # The synchronous half alone — the state the endpoint has answered `202` from, before any
  # resolution has run.
  def record(specs, ci_run_id:)
    payload = Ingest::Payload.new(ingest_payload(specs: specs, ci_run_id: ci_run_id).deep_stringify_keys)
    raise "payload invalid: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repository, payload.test_run_attributes,
                               shard_id: payload.shard_id, specs: payload.specs)
  end

  def identity_texts = repository.spec_identities.pluck(:text).sort

  # How many embeddings a block caused, counted through `EmbeddingGenerator.provider=` — the public
  # swap seam `with lexical embeddings` itself uses — rather than by stubbing
  # `EmbeddingGenerator.call`: what is counted is then the real call the resolver makes through the
  # real interface, width validation and all. Delegating to `LocalProvider` rather than returning a
  # fixture vector keeps every fallthrough behaving exactly as it does everywhere else in this file,
  # so the counter can be installed without changing what the example under it measures.
  #
  # Top-level because TWO groups now bound the same figure from opposite ends: "re-ingesting text
  # that has not changed" asserts the embed does not happen on run 2, and "the page map is a
  # snapshot, and what that costs a FIRST run" asserts that batching those lookups did not quietly
  # add one back on run 1. One instrument, so the two cannot disagree about what an embed is.
  let(:counting_provider) do
    Class.new do
      class << self
        def calls = @calls ||= 0

        def call(text)
          @calls = calls + 1
          EmbeddingGenerator::LocalProvider.call(text)
        end
      end
    end
  end

  describe "the behaviour this slice exists for: a test that moved is the same test" do
    # A shifted test's text is byte-identical, so two independent mechanisms both land it on the row
    # it already had: similarity (its vector is unchanged, cosine 1.0) and the `(repository_id,
    # text_digest)` conflict key. That overlap is deliberate — see `IdentityResolver#claim_identity`
    # — and it means these examples do not, on their own, isolate the similarity path. The one that
    # does is "still matches text that differs only in punctuation and whitespace" below: different
    # bytes, so the key cannot help, and only the embedding can.
    it "resolves a suite shifted ten lines onto the rows it already had, without growing the table" do
      first = ingest(suite, ci_run_id: "run-1")
      identities = repository.spec_identities.order(:id).pluck(:id)

      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.order(:id).pluck(:id)).to eq(identities)
      expect(second.spec_observations.pluck(:spec_identity_id).sort).to eq(identities)
      expect(first.spec_observations.pluck(:spec_identity_id).sort).to eq(identities)
    end

    it "moves each row's last known path to where the test now is" do
      ingest(suite, ci_run_id: "run-1")
      expect(repository.spec_identities.pluck(:line_number).sort).to eq([5, 10, 20])

      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:line_number).sort).to eq([15, 20, 30])
    end

    it "records the run that last saw the test, so a row says how current it is" do
      ingest(suite, ci_run_id: "run-1")
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
    end

    it "leaves each identity holding both runs' measurements — one test's history, finally" do
      ingest(suite, ci_run_id: "run-1")
      ingest(suite(offset: 10), ci_run_id: "run-2")

      counts = repository.spec_identities.map { |identity| identity.spec_observations.count }

      expect(counts).to eq([2, 2, 2])
    end

    it "keeps the position out of the identity: the same test on a different line is not a new row" do
      # The falsifier for the whole slice. A positional key — `(repository_id, file_path,
      # line_number)`, the one `spec_intents` carries — would make this six rows rather than three.
      ingest(suite, ci_run_id: "run-1")
      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(3)
    end
  end

  describe "at zero annotations" do
    let(:unannotated) do
      [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 4,
                        name: "User#save rejects a duplicate email")]
    end

    it "gives a name-only test an identity, with no @intent anywhere in the payload" do
      ingest(unannotated, ci_run_id: "run-1")

      identity = repository.spec_identities.sole

      expect(identity.text).to eq("User#save rejects a duplicate email")
      expect(identity).to be_from_name
    end

    it "resolves it again on the next run, from its name alone" do
      ingest(unannotated, ci_run_id: "run-1")
      first = repository.spec_identities.sole.id

      moved = [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 44,
                                name: "User#save rejects a duplicate email")]
      run = ingest(moved, ci_run_id: "run-2")

      expect(repository.spec_identities.sole.id).to eq(first)
      expect(run.spec_observations.sole.spec_identity_id).to eq(first)
    end
  end

  describe "which of the two texts supplied the identity" do
    it "prefers the declared intent over the name, and says so on the row" do
      ingest([annotated_spec(name: "Invoice#finalize locks the line items")], ci_run_id: "run-1")

      identity = repository.spec_identities.sole

      # `Ingest::SpecSignal`'s intent branch: "{entity} {action} {behavior}", not `name`.
      expect(identity.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
      expect(identity).to be_from_intent
    end

    it "keeps an annotated test's identity when its full_description is reworded" do
      ingest([annotated_spec(name: "Invoice#finalize locks the line items")], ci_run_id: "run-1")
      first = repository.spec_identities.sole.id

      ingest([annotated_spec(line_number: 40, name: "Invoice#finalize freezes every line")],
             ci_run_id: "run-2")

      expect(repository.spec_identities.pluck(:id)).to eq([first])
    end

    it "does not let a name-derived match be mistaken for a declared one" do
      ingest(suite, ci_run_id: "run-1")

      expect(repository.spec_identities.group(:signal_source).count).to eq("intent" => 1, "name" => 2)
    end
  end

  describe "a renamed unannotated test is a different test" do
    it "starts a new identity rather than re-pointing the old one" do
      ingest(suite, ci_run_id: "run-1")
      original = repository.spec_identities.find_by(text: "User#save rejects a duplicate email")

      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(4)
      expect(identity_texts).to include("User#save refuses a handle that is already taken")
      expect(original.reload.text).to eq("User#save rejects a duplicate email")
    end

    it "leaves the old identity's history intact rather than moving it onto the new name" do
      ingest(suite, ci_run_id: "run-1")
      original = repository.spec_identities.find_by(text: "User#save rejects a duplicate email")

      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(original.spec_observations.count).to eq(1)
      expect(original.reload.line_number).to eq(20)
    end
  end

  describe "the threshold, against the vectors it was chosen from" do
    # Not an assertion about a constant's value — an assertion about what the constant DOES to real
    # texts. Changing 0.95 to 0.75 leaves the constant "correct" and breaks these.
    it "does not merge two different tests that merely read alike" do
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Invoice finalize locks the line items"),
              unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                               name: "Invoice finalize locks line items once finalized")],
             ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(2)
    end

    it "keeps a pair inside the duplicate-detection band as two identities" do
      # The invariant that matters between the two thresholds, as behaviour rather than as a claim
      # about a constant. These two score 0.9236 on the shipped provider: at or above the duplicate
      # engine's 0.88, so it is entitled to report them as redundant, and below MATCH_SIMILARITY, so
      # resolution still gives each its own history. Lower the constant to 0.75 and this merges them
      # — which is the failure the "strictly above" rule exists to prevent.
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order#checkout rejects an expired card"),
              unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                               name: "Order#checkout rejects an expired card token")],
             ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(2)
    end

    it "cannot separate two tests whose descriptions are identical — they collapse onto one row" do
      # Where the threshold stops mattering, demonstrated rather than asserted. The duplicates the
      # shipped surface reports are EXACT ones — `SpecObservation.repeated_descriptions_in` groups
      # on `name` — and identical text embeds to an identical vector, so no value of
      # MATCH_SIMILARITY makes these two examples two identities: `#nearest` matches at cosine 1.0,
      # and the `(repository_id, text_digest)` key would land them together even if it did not.
      # Stated on `SpecIdentity::MATCH_SIMILARITY`; asserted here so SPGD-114 slice 4 inherits it as
      # a known property of these rows rather than a surprise.
      run = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3,
                                     name: "is valid"),
                    unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7,
                                     name: "is valid")],
                   ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(1)
      # Two different tests, one history: the run's two observations point at the same row.
      expect(run.spec_observations.pluck(:spec_identity_id).uniq.size).to eq(1)
      # And its "last known path" is simply whichever of the two was resolved last — the flip-flop
      # named in the constant's comment, pinned here so it is documented rather than folklore.
      expect(repository.spec_identities.sole.location).to eq("spec/models/user_spec.rb:7")
    end

    it "still matches text that differs only in punctuation and whitespace" do
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order#checkout rejects an expired card")],
             ci_run_id: "run-1")
      ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                               name: "Order  checkout   rejects an expired card!")],
             ci_run_id: "run-2")

      expect(repository.spec_identities.count).to eq(1)
    end
  end

  describe "re-ingesting text that has not changed" do
    # The optimisation itself, asserted as work NOT DONE rather than as a duration. A byte-identical
    # re-ingest is the ordinary case and not a corner — run 2 of an unchanged suite is every row of
    # it — and each of those rows is named outright by the `(repository_id, text_digest)` equality
    # `#claim_identity` already upserts onto, so nothing has to be embedded to find it again.
    #
    # The instrument is `counting_provider`, one level up. What that equality COSTS TO ASK is the
    # group below this one.

    it "embeds nothing at all when every text is byte-identical to a row already held" do
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(0)
    end

    it "still embeds a text this repository has never seen" do
      # The counter is only worth reading if it can move: same instrument, same three-example suite,
      # one of them renamed. A rename's bytes differ, so the equality cannot answer and today's path
      # runs — which is the fallthrough the whole change depends on, observed rather than assumed.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      ingest(suite(offset: 10, renamed: "User#save refuses a handle that is already taken"),
             ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(1)
    end

    it "re-sights every row whose embed it skipped, rather than becoming a no-op" do
      # The failure mode a skip invites: returning early and never moving the row. Skipping the
      # EMBED must not skip the SIGHTING — `SpecIdentity::RESIGHTABLE` is what a re-sighting moves,
      # and none of it needs a vector.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(counting_provider.calls).to eq(0)
      expect(repository.spec_identities.pluck(:line_number).sort).to eq([15, 20, 30])
      expect(repository.spec_identities.pluck(:last_seen_test_run_id).uniq).to eq([second.id])
      expect(repository.spec_identities.count).to eq(3)
    end

    it "counts a skipped row as resolved and links it, exactly as an embedded one" do
      # What `#resolve` returns is unchanged by the shortcut: the row carries an identity, so it is
      # resolved, and it is off the work list for the next job.
      ingest(suite, ci_run_id: "run-1")

      EmbeddingGenerator.provider = counting_provider
      second = record(suite(offset: 10), ci_run_id: "run-2")

      expect(described_class.resolve(second)).to eq(3)
      expect(counting_provider.calls).to eq(0)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "resolves a known test even while the provider is down, because it never asks it" do
      # A consequence worth pinning rather than leaving to be discovered: the shortcut returns
      # before `#embed`, so an outage stops mattering for every test whose text this repository
      # already holds. Only genuinely new text still needs the provider — and only that text is
      # still left unresolved and stamped, which is the group below this one.
      ingest(suite, ci_run_id: "run-1")

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      second = ingest(suite(offset: 10), ci_run_id: "run-2")

      expect(second.spec_observations.unresolved).to be_empty
      expect(second.spec_observations.embed_failed).to be_empty
      expect(repository.spec_identities.count).to eq(3)
    end
  end

  describe "what a page of unchanged text costs in round trips" do
    # The other half of the same optimisation, and the reason it is a separate group: the group above
    # asserts the equality removes the WORK, this one asserts asking it does not cost a round trip
    # per row. Run 2 of an unchanged suite answers every row by an equality now, but a per-row
    # `find_by` still issued 20,000 sequential trips at the design point to rediscover 20,000 rows
    # the database can name a page at a time.
    #
    # **A query count and never a duration.** A duration would go green on a fast machine whatever
    # the resolver did, and red on a slow one whatever it did — the claim is about the NUMBER of
    # statements, so that is what is counted. `count_queries`/`executed_sql` (spec/support/
    # query_capture.rb) drop `payload[:cached]` as well as `SCHEMA`/`TRANSACTION`, so what is counted
    # is round trips actually paid for.
    #
    # Narrowed to the digest lookup rather than counted as a page total: the per-row UPDATEs a
    # re-sighting issues are O(N) by definition and are not what this slice changed, so a total would
    # move for reasons that have nothing to do with the claim. `\ASELECT` excludes the `INSERT … ON
    # CONFLICT` in `#claim_identity`, which names the same column and is not a lookup.
    def digest_lookups(&) = executed_sql(&).grep(/\ASELECT\b.*\btext_digest\b/m)

    # Twelve deliberately UNLIKE descriptions. The count has to be a page-multiple to say anything,
    # and near-identical filler would collapse under `MATCH_SIMILARITY` into fewer identities than
    # examples — which would leave the query count technically green while the fixture no longer
    # meant what it says. Each example below pins that premise before asserting anything.
    #
    # A method and not a constant: a constant assigned in a `describe` block takes the file's
    # lexical cref, not the example group's, so `SUBJECTS = [...]` here would define a GLOBAL
    # `::SUBJECTS` — a name generic enough to collide with the next spec that wants it, and to
    # collide load-order-dependently. Every other fixture in this file (`suite`, `wide_suite`,
    # `record`, `ingest`, `digest_lookups`) is a method for the same reason.
    def subjects
      [
        "Invoice#finalize locks the line items",
        "User#save rejects a duplicate email",
        "Cart adds an item to the cart",
        "Order#checkout rejects an expired card",
        "Payment#refund returns money to the original card",
        "Shipment#dispatch assigns a tracking number",
        "Coupon#apply reduces the total by a percentage",
        "Session#expire logs the visitor out",
        "Ledger#post balances debits against credits",
        "Report#render writes a PDF to disk",
        "Webhook#deliver retries after a server error",
        "Search#query ranks by relevance and then recency"
      ].freeze
    end

    def wide_suite(offset: 0)
      subjects.each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/models/subject_#{index}_spec.rb",
                         line_number: index + 1 + offset, name: name)
      end
    end

    it "asks one query for a whole page's digests rather than one per example" do
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      # Twelve rows, one page, one lookup. Per row this was twelve; at the 20,000-example design
      # point it was 20,000.
      expect(digest_lookups { described_class.resolve(second) }.size).to eq(1)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "grows with the number of PAGES and not with the number of examples" do
      # The falsifier for the one above, which a resolver that asked once for the whole suite would
      # also pass. `BATCH_SIZE` is what the lookup is grouped by, so shrinking it to a third of the
      # suite must cost exactly three lookups — and an implementation that kept asking per row would
      # answer twelve here whatever this constant said.
      stub_const("#{described_class}::BATCH_SIZE", subjects.size / 3)
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      second = record(wide_suite(offset: 100), ci_run_id: "run-2")

      expect(digest_lookups { described_class.resolve(second) }.size).to eq(3)
      expect(second.spec_observations.unresolved.count).to eq(0)
    end

    it "asks once for the CROSS-RUN BACKLOG's page too, and not once per rescued row" do
      # **The other list.** Both examples above walk a run's OWN rows, and `#resolve` walks two
      # lists: before them comes `#retry_backlog`, the rows of EARLIER runs nothing else will
      # revisit. That list reaches `#claim` by a different route, so a resolver that batched a run's
      # own pages and went back to asking per row for the backlog would answer both examples above
      # correctly — verified, not assumed: replacing `resolve_page(retry_backlog)` with the per-row
      # `retry_backlog.each { claim(...) }` this slice removed leaves the WHOLE suite green without
      # this example. That is the shape SPGD-78 is about, so the backlog page is pinned separately
      # from the run's own.
      #
      # It is also the newer half of the seam. `#retry_backlog` became TWO populations under one
      # budget in SPGD-379, and this is what says the page seam still sits above both of them.
      ingest(wide_suite, ci_run_id: "run-1")
      expect(repository.spec_identities.count).to eq(subjects.size)

      # A whole run stranded before its job reached any of it — unresolved, UNSTAMPED, and waiting
      # longer than the grace, which is exactly `#unattempted_embed_backlog`'s population. Aged by
      # `update_all` rather than by moving the clock, the choice `#strand` states further down.
      stranded = record(wide_suite(offset: 100), ci_run_id: "run-2")
      stranded.spec_observations.unresolved
              .update_all(created_at: (SpecObservation::EMBED_ATTEMPT_GRACE + 1.minute).ago)

      # Run 3 carries text this repository already holds, which keeps the instrument honest in a way
      # the fixture has to arrange: `digest_lookups` matches any SELECT naming `text_digest`, and
      # `#nearest` selects EVERY column. A row that fell through to similarity would therefore be
      # counted here as though it were a lookup. With nothing to embed anywhere, the only statements
      # that can match are the two this example is about.
      third = record([unannotated_spec(file_path: "spec/models/subject_0_spec.rb", line_number: 900,
                                       name: subjects.first)], ci_run_id: "run-3")

      EmbeddingGenerator.provider = counting_provider

      # TWO pages, two lookups: the backlog's twelve rows, then run 3's one. Per row it is thirteen.
      expect(digest_lookups { described_class.resolve(third) }.size).to eq(2)

      # The premise, pinned rather than trusted: nothing was embedded, so nothing reached `#nearest`
      # and neither number above is an artifact of a fallthrough.
      expect(counting_provider.calls).to eq(0)
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    it "still costs nothing when a page carries no text to look up at all" do
      # A page of rows with nothing to embed — `Ingest::SpecSignal`'s `:none` case, the rows
      # `#identity_for` returns nil for — must ask the database nothing.
      #
      # This is a falsifiable guard on `#digest_index`'s `filter_map` and not on an empty-list check:
      # `SpecIdentity.digest_for(nil)` is a perfectly good SHA-256 of the empty string, so a `map`
      # here would send a real digest no row can hold on a real round trip, and this goes red.
      # Asserted as the ABSENCE of the query rather than as the presence of a guard, so it keeps
      # meaning the same thing however `where(text_digest: [])` is answered.
      run = record([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      run.spec_observations.sole.update_columns(name: nil)

      expect(digest_lookups { described_class.resolve(run) }).to be_empty
      expect(run.spec_observations.sole.reload.spec_identity_id).to be_nil
    end
  end

  describe "the page map is a snapshot, and what that costs a FIRST run" do
    # Its own group rather than a fourth example in the round-trip group above: this one is a FIRST
    # run over text that is not unchanged, and it asserts an EMBED COUNT rather than a round trip.
    # It answers a different question from the group it used to sit in, so it is filed under the
    # question it actually answers.

    it "does not make a first run embed twice for two examples carrying the same text" do
      # **The cost of a page map being a SNAPSHOT, resolved deliberately rather than discovered.**
      # The per-row `find_by` this replaced saw identities committed by EARLIER ROWS OF THE SAME
      # PAGE; a map read once up front does not, so the second of two byte-identical descriptions
      # would miss it and fall through to an embed that today it never pays.
      #
      # The OUTCOME is the same either way — identical text embeds to an identical vector, `#nearest`
      # matches at cosine 1.0, and the conflict key would land them together regardless — which is
      # exactly why this needs its own example: "cannot separate two tests whose descriptions are
      # identical" asserts the identity COUNT and stays green under both. The embed is the expensive
      # thing the whole path exists to avoid and the provider is swappable for a billed one, so
      # `#claim_identity` puts the row it just created back into the page's map, and this is the
      # assertion that says so.
      EmbeddingGenerator.provider = counting_provider

      run = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3,
                                     name: "is valid"),
                    unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7,
                                     name: "is valid")],
                   ci_run_id: "run-1")

      expect(counting_provider.calls).to eq(1)
      expect(repository.spec_identities.count).to eq(1)
      expect(run.spec_observations.pluck(:spec_identity_id).uniq.size).to eq(1)
    end
  end

  describe "the tenant boundary" do
    it "never resolves a test onto another repository's identity" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other-service")
      create_spec_identity(repository: other, text: "Cart adds an item to the cart")

      ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(1)
      expect(other.spec_identities.count).to eq(1)
      expect(repository.spec_identities.sole.id).not_to eq(other.spec_identities.sole.id)
    end
  end

  describe "two ingests that both miss on the same test" do
    # The race the conflict key exists for, and the ordinary case rather than a corner: every shard
    # of a repository's first run resolves for the first time, so two of them reaching the same text
    # and both finding nothing is what normally happens.
    #
    # Reproduced the way `spec/support/uniqueness_race.rb` describes the shape — the loser's lookups
    # cannot see a winner that has not committed, so they return nothing and it goes to insert while
    # the row is already there. That is stubbed at the two methods whose answer the race changes —
    # `#identical_text`, the digest equality, and `#nearest`, the similarity lookup — rather than by
    # racing threads a transactional example cannot run; everything after them (the upsert, the
    # conflict, the link) is the real code path. Without the `ON CONFLICT` clause these examples
    # raise `ActiveRecord::RecordNotUnique` rather than merely counting wrong.
    #
    # BOTH stubs are load-bearing, and the second one is why: these fixtures build the winner with
    # the SAME text the observation carries, so the digest lookup would find it, `#identity_for`
    # would return at the fast path, and every example below would stay green while testing the
    # re-sighting path instead of the conflict path it names. That is also what genuinely happens to
    # a loser — an uncommitted winner is invisible to an equality exactly as it is to an index scan
    # — so stubbing both is the faithful reproduction, not a workaround for one.
    #
    # `#identical_text` is STILL the right seam for the first stub now that the digest question is
    # answered a page at a time: the query moved to `#digest_index`, the DECISION did not, and this
    # is the method that makes it for one row. Stubbing the page builder instead would be stubbing
    # further from what the loser actually experiences, and dropping the stub because the examples
    # stay green without it would silently retire the race coverage — the winner IS committed before
    # `#resolve` runs here, so the page's map finds it just as the per-row `find_by` did.
    def resolve_as_the_loser(run)
      resolver = described_class.new(run)
      allow(resolver).to receive(:identical_text).and_return(nil)
      allow(resolver).to receive(:nearest).and_return(nil)
      resolver.resolve
    end

    it "converges on one row instead of raising or duplicating" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 5)
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 40,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect { resolve_as_the_loser(run) }.not_to change(SpecIdentity, :count)

      expect(SpecIdentity.sole.id).to eq(winner.id)
    end

    it "lands the loser's sighting on the winner and hands it the same link" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 5)
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 40,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      resolve_as_the_loser(run)

      expect(winner.reload.line_number).to eq(40)
      expect(winner.last_seen_test_run_id).to eq(run.id)
      expect(run.spec_observations.sole.spec_identity_id).to eq(winner.id)
    end

    it "refuses a losing sighting from a run older than the one the winner already names" do
      # The conflict branch is a re-sighting, so it is monotonic for the reason `#resight` is. And it
      # is reachable outside a race: `#nearest` is an approximate index lookup, so an under-recalled
      # miss on text that already HAS an identity arrives here rather than there — carrying, if the
      # row came out of the cross-run backlog, a run older than the one the identity already names.
      older = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      newer = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart",
                                    file_path: "spec/models/cart_spec.rb", line_number: 90,
                                    last_seen_test_run_id: newer.id)

      resolve_as_the_loser(older)

      expect(winner.reload.location).to eq("spec/models/cart_spec.rb:90")
      expect(winner.last_seen_test_run_id).to eq(newer.id)
      # Refused the sighting, not the row: the older observation still gets its link.
      expect(older.spec_observations.sole.spec_identity_id).to eq(winner.id)
    end

    it "leaves the winner's own identity untouched — a conflict re-sights, it does not overwrite" do
      winner = create_spec_identity(repository: repository, text: "Cart adds an item to the cart")
      # Read back from the column rather than held from the insert: pgvector stores float4, so the
      # stored vector is not the float64 array that was written and comparing the two would fail on
      # rounding rather than on anything this example is about.
      before = winner.reload.slice(:created_at, :text, :text_digest, :signal_source, :embedding)
      run = record([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      resolve_as_the_loser(run)

      expect(winner.reload.slice(*before.keys)).to eq(before)
    end
  end

  describe "an example the provider cannot embed" do
    # The provider, down and back. `reset` on the proxy rather than a second `allow`, so the "back"
    # state is the real `LocalProvider` this group installed and not another stub.
    def provider_down
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
    end

    def provider_back = RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

    # A LATER ingest of this repository, carrying a test that has nothing to do with the failed one.
    # This is the production trigger under test everywhere below: nothing it contains can create the
    # failed row's identity, so if that row resolves, the cross-run sweep is what resolved it.
    def unrelated_ingest(ci_run_id:)
      ingest([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                               name: "User#save rejects a duplicate email")], ci_run_id: ci_run_id)
    end

    it "leaves the observation unresolved rather than writing an identity nothing can find again" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")

      run = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      expect(repository.spec_identities.count).to eq(0)
      expect(run.spec_observations.sole.spec_identity_id).to be_nil
    end

    it "does not abandon the rest of the run" do
      texts = ["Cart adds an item to the cart", "User#save rejects a duplicate email"]
      allow(EmbeddingGenerator).to receive(:call).and_wrap_original do |original, text|
        raise EmbeddingGenerator::Error, "provider down" if text == texts.first

        original.call(text)
      end

      run = ingest(texts.each_with_index.map do |name, index|
        unannotated_spec(file_path: "spec/a_spec.rb", line_number: index + 1, name: name)
      end, ci_run_id: "run-1")

      expect(repository.spec_identities.pluck(:text)).to eq([texts.last])
      expect(run.spec_observations.where.not(spec_identity_id: nil).count).to eq(1)
    end

    it "records that the embedding was attempted and failed, rather than leaving a bare NULL" do
      provider_down

      run = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      observation = run.spec_observations.sole
      expect(observation.embed_failed_at).to be_present
      expect(observation.embed_failure_count).to eq(1)
    end

    it "tells a failed embed apart from a row with nothing to embed and from one not yet attempted" do
      # The three populations one NULL `spec_identity_id` used to pool, built through the real path
      # in the order that keeps each in its own state. The signalless row's name is nulled by hand
      # because `Ingest::Payload#validate_name` refuses that shape today — which is exactly what
      # `IdentityResolver#identity_for` says its `:none` branch is for, a row written before the
      # validator existed — and it goes FIRST so no later sweep can be what left it alone.
      signalless = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                            name: "Order#checkout rejects an expired card")],
                          ci_run_id: "run-1")
      signalless.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(signalless)

      provider_down
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      provider_back

      # Recorded and not resolved: the state the endpoint answers `202` from, and the state every
      # row passes through. It is transient only if the job arrives — nothing guarantees that, which
      # is why it is a QUERYABLE state now rather than a NULL nobody was looking at.
      unattempted = record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                             name: "User#save rejects a duplicate email")],
                           ci_run_id: "run-3")

      expect(repository.spec_observations.unresolved.pluck(:test_run_id))
        .to contain_exactly(signalless.id, failed.id, unattempted.id)
      # One predicate, and it picks the recoverable one out of the three.
      expect(repository.spec_observations.embed_failed.pluck(:test_run_id)).to eq([failed.id])
      expect(repository.spec_observations.embed_retryable.pluck(:test_run_id)).to eq([failed.id])
      # And its complement picks the other two — which is all one predicate over `embed_failed_at`
      # can do. Which of THOSE two a row is stays `Ingest::SpecSignal`'s question, asked one row at
      # a time by `#identity_for`, because a second implementation of the intent-or-name precedence
      # in SQL is the drift `SpecObservation#signal` exists to prevent.
      expect(repository.spec_observations.unresolved.embed_unattempted.pluck(:test_run_id))
        .to contain_exactly(signalless.id, unattempted.id)
      # Neither of them is in a BACKLOG yet, and for the same reason: both were created just now, so
      # `EMBED_ATTEMPT_GRACE` still reads them as rows a live job may be on its way to. "Nothing is
      # wrong; wait" is the correct answer here — the defect was that it stayed the answer forever.
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty
    end

    it "resolves it on the next run once the provider is back — nothing is permanently lost" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      unrelated_ingest(ci_run_id: "run-2")

      # No `described_class.resolve` by hand anywhere in this example. That line used to be here and
      # was the only thing in the world that did this; the ingest above is now what does it.
      identity = first.spec_observations.sole.reload.spec_identity
      expect(identity.text).to eq("Cart adds an item to the cart")
      # And the rescued row's own run is what the identity says last saw the test, not the run whose
      # ingest happened to perform the rescue.
      expect(identity.last_seen_test_run_id).to eq(first.id)
    end

    it "does not let a rescued older run overwrite a newer run's last known path" do
      provider_down
      ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                               name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      second = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")

      # The backlog row and the newer run's own row, in one pass, resolved in that order. The
      # falsifier for `SpecIdentity::SIGHTING_NOT_OLDER` on the half of the work list where the
      # newer sighting arrives second.
      identity = repository.spec_identities.sole
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
    end

    it "keeps the newest run's path when an outage spanning two runs is rescued in one sweep" do
      # The shape the whole slice exists to recover from — a provider down across MORE than one
      # ingest — and the case iteration order alone never covered. Both rows are failed, both are in
      # the backlog, and they are walked least-tried-first: run-1's row was already swept once by
      # run-2's ingest, so it carries a HIGHER failure count than run-2's own row and is therefore
      # walked LAST. Ordering cannot fix that without giving up the fairness key; the guard makes it
      # not matter.
      provider_down
      first = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                       name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      second = ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      provider_back

      # Pin the premise rather than trusting it: this example is only about the newest-last order if
      # the older row really does sort after the newer one.
      expect(repository.spec_observations.embed_retryable.order(:embed_failure_count).pluck(:test_run_id))
        .to eq([second.id, first.id])

      unrelated_ingest(ci_run_id: "run-3")

      identity = repository.spec_identities.find_by!(text: "Cart adds an item to the cart")
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
      # Both rows are still rescued — refusing the older sighting is not refusing the older row.
      expect(first.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
      expect(second.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
    end

    it "keeps the first failure's timestamp, so re-attempting cannot push the window forward" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      stamped = first.spec_observations.sole.embed_failed_at

      # Still down: the sweep re-attempts the row and fails again.
      unrelated_ingest(ci_run_id: "run-2")

      observation = first.spec_observations.sole.reload
      expect(observation.embed_failed_at).to eq(stamped)
      expect(observation.embed_failure_count).to eq(2)
    end

    it "stops re-attempting a row once the window has closed on it" do
      provider_down
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      provider_back

      # `update_all` rather than a time-travel helper, the choice
      # spec/requests/api/v1/repository_latest_run_spec.rb states: assert the fact the fixture needs
      # — this row first failed longer ago than the window — rather than moving the clock underneath
      # everything else in the example.
      first.spec_observations.update_all(embed_failed_at: SpecObservation::EMBED_RETRY_WINDOW.ago - 1.second)

      unrelated_ingest(ci_run_id: "run-2")

      expect(first.spec_observations.sole.reload.spec_identity_id).to be_nil
      expect(repository.spec_observations.embed_retryable.count).to eq(0)
      # Given up on, and queryable as such: "we stopped trying" is not the same figure as "we are
      # still trying", which is the whole reason the bound is a scope and not a bare comparison.
      expect(repository.spec_observations.embed_abandoned.count).to eq(1)
    end

    it "caps how much of a backlog one ingest inherits, and drains the rest across later ones" do
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)
      provider_down
      first = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                       name: "Cart adds an item to the cart"),
                      unannotated_spec(file_path: "spec/a_spec.rb", line_number: 2,
                                       name: "Invoice#finalize locks the line items")],
                     ci_run_id: "run-1")
      provider_back

      unrelated_ingest(ci_run_id: "run-2")
      expect(first.spec_observations.unresolved.count).to eq(1)

      unrelated_ingest(ci_run_id: "run-3")
      expect(first.spec_observations.unresolved.count).to eq(0)
    end
  end

  describe "a resolve that died before it reached the rest of the run" do
    # The failure this whole group is about, reproduced at the place it actually happens.
    # `IdentityResolver`'s loop has exactly one rescue and it is around the embed call, scoped to
    # `EmbeddingGenerator::Error`. An `ActiveRecord::StatementInvalid` out of the ANN lookup — a
    # dropped connection, a database blip, the tail of a deploy — propagates out of `#resolve`
    # instead, and `ApplicationJob` declares no `retry_on` to catch it. Rows already claimed keep
    # their identity, because `#claim` commits per row; rows not yet reached are left unresolved and
    # UNSTAMPED, because `#record_resolve_failure` only runs where the row was actually reached.
    #
    # Stubbed at `#nearest` rather than at `EmbeddingGenerator`, so the error class is one the
    # rescue genuinely does not cover. Raising a non-`EmbeddingGenerator::Error` from the provider
    # would reach the same state through a path the provider contract says cannot happen.
    def die_after(run, rows:)
      resolver = described_class.new(run)
      reached = 0
      allow(resolver).to receive(:nearest).and_wrap_original do |original, *args|
        reached += 1
        raise ActiveRecord::StatementInvalid, "server closed the connection unexpectedly" if reached > rows

        original.call(*args)
      end

      expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # Put a row's wait far enough behind it that `EMBED_ATTEMPT_GRACE` no longer reads it as one a
    # live job may be on its way to. `update_all` rather than a time-travel helper, the choice
    # spec/requests/api/v1/repository_latest_run_spec.rb states and the window example above already
    # follows: assert the fact the fixture needs — this row has been waiting longer than the grace —
    # rather than moving the clock underneath everything else in the example.
    def strand(run, ago: SpecObservation::EMBED_ATTEMPT_GRACE + 1.minute)
      run.spec_observations.unresolved.update_all(created_at: ago.ago)
    end

    # A LATER ingest of this repository, under a DIFFERENT run. The production trigger under test:
    # the original run is never redelivered and its job is never re-enqueued, so if the stranded
    # rows resolve, the cross-run sweep is the only thing that can have resolved them.
    def later_ingest(specs = [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                               name: "User#save rejects a duplicate email")],
                     ci_run_id:)
      ingest(specs, ci_run_id: ci_run_id)
    end

    it "leaves the unreached rows unresolved with no stamp — the state nothing could describe" do
      run = record(suite, ci_run_id: "run-1")

      die_after(run, rows: 1)

      stranded = run.spec_observations.unresolved
      expect(stranded.count).to eq(2)
      # Not a failure, and nothing may read it as one: the provider was never asked about these.
      expect(stranded.pluck(:embed_failed_at).uniq).to eq([nil])
      expect(stranded.pluck(:embed_failure_count).uniq).to eq([0])
      expect(repository.spec_observations.embed_failed).to be_empty
      expect(repository.spec_observations.embed_retryable).to be_empty
    end

    it "makes them findable once no live job could still be on its way to them" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)

      # Inside the grace they are indistinguishable from the rows of an ingest that landed a second
      # ago, and are deliberately left alone: "nothing is wrong; wait" is still the right answer.
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty

      strand(run)

      expect(repository.spec_observations.embed_unattempted_retryable.pluck(:test_run_id))
        .to eq([run.id, run.id])
    end

    it "resolves them on the next ingest of a different run, without redelivering the original" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run)

      # No `described_class.resolve(run)` by hand anywhere: nothing in production would ever call it
      # again for this run, which is precisely the defect. The ingest below is what does it.
      later_ingest(ci_run_id: "run-2")

      expect(run.spec_observations.unresolved).to be_empty
      expect(identity_texts).to contain_exactly(
        "Cart adds an item to the cart",
        "Invoice finalize locks the line items once the invoice is finalized",
        "User#save rejects a duplicate email"
      )
    end

    it "lands a stranded row on the identity the test already had, rather than starting a second" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run)

      # The rescuing ingest carries the SAME test as one of the stranded rows, so the two must come
      # away holding one identity between them — the semantic-identity rule, reached through the
      # sweep instead of through a run's own list.
      second = later_ingest(ci_run_id: "run-2")

      identity = second.spec_observations.sole.reload.spec_identity
      expect(identity.text).to eq("User#save rejects a duplicate email")
      expect(run.spec_observations.find_by(file_path: "spec/models/user_spec.rb").reload.spec_identity_id)
        .to eq(identity.id)
      expect(repository.spec_identities.where(text: identity.text).count).to eq(1)
    end

    it "does not let a rescued older run overwrite a newer run's last known path" do
      # `SIGHTING_NOT_OLDER` over the never-attempted half of the backlog, which is the half where
      # the stranded row is walked FIRST and the newer sighting therefore arrives second.
      run = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                     name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      die_after(run, rows: 0)
      strand(run)

      second = later_ingest([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 90,
                                              name: "Cart adds an item to the cart")],
                            ci_run_id: "run-2")

      identity = repository.spec_identities.sole
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
      # Refused the sighting, not the row: the stranded observation still gets its link.
      expect(run.spec_observations.sole.reload.spec_identity_id).to eq(identity.id)
    end

    it "never gives an identity to a row with nothing to embed, however many ingests sweep past it" do
      # The population the sweep now reads on every ingest and must go on doing nothing with. Its
      # name is nulled by hand because `Ingest::Payload#validate_name` refuses that shape today —
      # which is exactly why it is a frozen legacy set rather than a growing cost.
      run = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                     name: "Order#checkout rejects an expired card")],
                   ci_run_id: "run-1")
      run.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(run)
      strand(run)

      # It IS in the work list now — that is the change — and it costs no embedding, because
      # `#identity_for` returns before the embed for a signal that is not present.
      expect(repository.spec_observations.embed_unattempted_retryable.count).to eq(1)

      3.times { |index| later_ingest(ci_run_id: "sweep-#{index}") }

      expect(run.spec_observations.sole.reload.spec_identity_id).to be_nil
      # And still no stamp after three sweeps: a row with nothing to embed never reaches the
      # provider, so it can never come to look like a failure that somebody should act on.
      expect(run.spec_observations.sole.embed_failed_at).to be_nil
      expect(identity_texts).to eq(["User#save rejects a duplicate email"])
    end

    it "is not starved by the rows that can never leave the backlog" do
      # The reason this list is ordered NEWEST first while the failure backlog is ordered
      # least-tried first. A signalless row is swept forever and resolves never — it returns from
      # `#identity_for` before the embed, so it takes no stamp and no attempt count, and there is no
      # counter that could demote it. Oldest-first would park that population permanently at the
      # head of the list and no genuinely stranded row would ever be reached.
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)

      signalless = record([unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                            name: "Order#checkout rejects an expired card")],
                          ci_run_id: "run-1")
      signalless.spec_observations.sole.update_columns(name: nil)
      described_class.resolve(signalless)

      stranded = record([unannotated_spec(file_path: "spec/models/cart_spec.rb", line_number: 5,
                                          name: "Cart adds an item to the cart")], ci_run_id: "run-2")
      die_after(stranded, rows: 0)

      # The signalless row is the OLDER of the two, which is the only shape it can have in
      # production: `Ingest::Payload#validate_name` has refused that payload since before any row
      # written after it, so the population that cannot resolve is by construction the oldest one.
      # That is what makes newest-first a structural answer to starvation rather than a hopeful one.
      strand(signalless, ago: 3.hours)
      strand(stranded, ago: 2.hours)

      later_ingest(ci_run_id: "run-3")

      expect(stranded.spec_observations.sole.reload.spec_identity_id).to be_present
      expect(signalless.spec_observations.sole.reload.spec_identity_id).to be_nil
    end

    it "gives up on it once the window has closed, and leaves it queryable as such" do
      run = record(suite, ci_run_id: "run-1")
      die_after(run, rows: 1)
      strand(run, ago: SpecObservation::EMBED_RETRY_WINDOW + 1.second)

      later_ingest(ci_run_id: "run-2")

      expect(run.spec_observations.unresolved.count).to eq(2)
      expect(repository.spec_observations.embed_unattempted_retryable).to be_empty
      # "We stopped trying" is not the same figure as "we are still trying", which is the whole
      # reason the bound is a scope and not a bare comparison — `embed_abandoned`'s rule, applied to
      # the population that never carried a stamp to anchor it.
      expect(repository.spec_observations.embed_unattempted_abandoned.count).to eq(2)
    end

    # `RETRY_SWEEP_LIMIT` bounds what ONE JOB inherits from the deliveries before it, and
    # `#retry_backlog` spends that one allowance across two lists. It does so in two distinct
    # behaviours, and they need an example each, because the one below cannot reach the other:
    #
    # * The failures SATURATE the budget — nothing is left, so the never-attempted list is not
    #   queried at all (the early return).
    # * The failures fill it PARTIALLY — the never-attempted list is asked for the REMAINDER (the
    #   subtraction).
    #
    # The second is the arithmetic that actually enforces one budget, and it is the ordinary
    # production shape rather than the exotic one: a saturated failure backlog is the provider
    # outage, while a handful of failed rows beside a stranded backlog is the everyday state of a
    # repository that has lost a job. An example seeded at a limit of 1 can only ever certify the
    # first — "partial" does not exist there — so a `RETRY_SWEEP_LIMIT`-for-`remaining` mutant
    # survives it while turning one budget back into two.
    it "does not query the never-attempted list at all when the failures have taken the whole budget" do
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 1)

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      stranded = record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                          name: "Invoice#finalize locks the line items")],
                        ci_run_id: "run-2")
      strand(stranded)

      # One slot, and the failures take it — a row something has already tried and failed to rescue
      # has the stronger claim on a scarce one.
      later_ingest(ci_run_id: "run-3")
      expect(failed.spec_observations.unresolved).to be_empty
      expect(stranded.spec_observations.unresolved.count).to eq(1)

      # Drained across the ingest that follows, exactly as an over-cap failure backlog is.
      later_ingest(ci_run_id: "run-4")
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    it "gives the never-attempted list only what the failures left, not a second full budget" do
      # The partial branch, and the one that pins the SUBTRACTION rather than the guard in front of
      # it. Three slots, one of them spent on a failure, three rows stranded: the sweep is entitled
      # to exactly two of them. Two independently capped lists would take all three here and the
      # example above would not notice, because at a limit of 1 the remainder is always zero.
      stub_const("#{described_class}::RETRY_SWEEP_LIMIT", 3)

      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      failed = ingest([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                        name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      # Three rows of one run, none of them reached: `die_after(rows: 0)` raises on the first ANN
      # lookup, so nothing is claimed and nothing is stamped — the whole run is stranded.
      stranded = record([
                          unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                           name: "Invoice#finalize locks the line items"),
                          unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                           name: "Order#checkout rejects an expired card"),
                          unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4,
                                           name: "Session#destroy clears the remember token")
                        ], ci_run_id: "run-2")
      die_after(stranded, rows: 0)
      strand(stranded)

      later_ingest(ci_run_id: "run-3")

      # One slot to the failure, and the OTHER TWO — not another three — to the stranding.
      expect(failed.spec_observations.unresolved).to be_empty
      expect(stranded.spec_observations.unresolved.count).to eq(1)

      # And the row the budget refused is deferred rather than dropped: with the failure backlog now
      # empty, the next ingest has the whole allowance to spend and drains it.
      later_ingest(ci_run_id: "run-4")
      expect(stranded.spec_observations.unresolved).to be_empty
    end

    # The poison row. The group above is about a pass that DIED; this one is about the row that
    # killed it still being there on the next pass, and the one after that.
    #
    # `#resolve` walks the inherited backlog BEFORE this run's own list, and until `#claim_inherited`
    # existed a row that raised there ended the delivery before `@run`'s observations were reached at
    # all. A deterministic failure — a stored vector of the wrong dimension, a row whose text trips a
    # provider bug — fails identically on every attempt, and the backlog is re-read by every later
    # ingest of that repository, so one row left every subsequent run's observations unresolved and
    # UNSTAMPED: the exact population the sweep above exists to rescue, defeated by the one row that
    # kills the sweep.
    describe "when one inherited row raises every time anything reaches it" do
      # A row of an EARLIER run, in the backlog, that nothing can resolve. Built by the group's own
      # `die_after` + `strand` rather than by hand: it is a genuinely stranded row and it reaches the
      # sweep through `embed_unattempted_retryable`, which is how one actually gets there.
      def poisoned_backlog_row
        run = record([unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 7,
                                       name: "Order#checkout rejects an expired card")],
                     ci_run_id: "run-1")
        die_after(run, rows: 0)
        strand(run)
        run.spec_observations.sole
      end

      # A later ingest whose resolver this example holds. `record` then `resolve` is exactly what
      # `ingest` does; the two halves are split only because the stub has to be attached between
      # them, and `#resolve` is called by the example so the raise — or its absence — is the
      # assertion rather than a side effect.
      #
      # Poisoned at `#nearest`, the same production site and the same error class `die_after` uses,
      # for the reason stated there: it is an error the one live rescue genuinely does not cover.
      # Keyed to ONE OBSERVATION rather than to a call count, because what is under test here is the
      # blast radius of a single row and not the death of a pass — and keyed through `#identity_for`,
      # which is the seam that still knows which row the lookup below is being made for.
      def sweeping_run(ci_run_id:, poison:, specs: nil)
        run = record(specs || [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                                name: "User#save rejects a duplicate email")],
                     ci_run_id: ci_run_id)
        resolver = described_class.new(run)
        resolving = nil
        allow(resolver).to receive(:identity_for).and_wrap_original do |original, observation|
          resolving = observation
          original.call(observation)
        end
        allow(resolver).to receive(:nearest).and_wrap_original do |original, *args|
          raise ActiveRecord::StatementInvalid, "server closed the connection" if resolving.id == poison.id

          original.call(*args)
        end

        [run, resolver]
      end

      it "does not abort the delivery: this run's own rows are still reached and resolved" do
        poisoned = poisoned_backlog_row
        run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)

        expect { resolver.resolve }.not_to raise_error

        # The backlog is walked FIRST, so this assertion is the whole ticket: the delivery got past
        # the row that used to end it.
        expect(run.spec_observations.unresolved).to be_empty
        expect(poisoned.reload.spec_identity_id).to be_nil
        # And the row that could not be resolved produced no identity standing for nothing.
        expect(identity_texts).to eq(["User#save rejects a duplicate email"])
      end

      it "leaves it findable by a scope rather than only in Solid Queue's failed executions" do
        poisoned = poisoned_backlog_row
        # The premise, pinned: before the sweep this row is the unstamped kind, so a stamp after it
        # is this containment's doing and not something the fixture arrived with.
        expect(repository.spec_observations.embed_failed).to be_empty

        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        resolver.resolve

        expect(poisoned.reload.embed_failed_at).to be_present
        expect(poisoned.embed_failure_count).to eq(1)
        expect(repository.spec_observations.embed_retryable.pluck(:id)).to eq([poisoned.id])
      end

      it "counts as nothing, because the count is what NOW carries an identity and it does not" do
        poisoned = poisoned_backlog_row
        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)

        # One row of its own, and zero for the contained one. Containment must not inflate the
        # figure `#resolve` reports — see its `@return`.
        expect(resolver.resolve).to eq(1)
      end

      it "sinks below a backlog row that has been tried less, so a scarce slot goes to that one" do
        poisoned = poisoned_backlog_row
        _second, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        resolver.resolve

        # A provider failure on a later run: a backlog row of the SAME standing — stamped, retryable
        # — carrying one fewer attempt than the contained row now does.
        allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
        failed = ingest([unannotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 9,
                                          name: "Invoice#finalize locks the line items")],
                        ci_run_id: "run-3")
        RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

        # Asserted off the relation the resolver ACTUALLY walks rather than a hand-written copy of
        # its ORDER BY, which would be a second definition of the query certifying nothing about the
        # sweep — the same choice the plan example below makes.
        backlog = described_class.new(create_test_run(repository: repository)).send(:failed_embed_backlog)

        expect(backlog.pluck(:id)).to eq([failed.spec_observations.sole.id, poisoned.id])
      end

      it "still lets the repository make progress on every ingest, for as long as it is retryable" do
        poisoned = poisoned_backlog_row

        # Three deliveries, each with the poison row sitting at the head of its backlog. Each one
        # resolves its own suite, and the row is re-attempted and re-contained rather than skipped —
        # a dropped connection is transient, and the bound on being wrong about that is the window
        # below, not a guess made here.
        3.times do |index|
          run, resolver = sweeping_run(
            ci_run_id: "sweep-#{index}", poison: poisoned,
            specs: [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3 + index,
                                     name: "User#save rejects a duplicate email")]
          )
          resolver.resolve
          expect(run.spec_observations.unresolved).to be_empty
        end

        expect(poisoned.reload.embed_failure_count).to eq(3)
        # One identity across all three, not three: the deliveries did their real work, and the
        # contained row never grew the table.
        expect(identity_texts).to eq(["User#save rejects a duplicate email"])
      end

      it "keeps the first containment's timestamp, so re-attempting cannot push the window forward" do
        poisoned = poisoned_backlog_row
        _first, first_resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        first_resolver.resolve
        stamped = poisoned.reload.embed_failed_at

        _second, second_resolver = sweeping_run(ci_run_id: "run-3", poison: poisoned)
        second_resolver.resolve

        # `COALESCE`, and it is what makes the bound below a window that CLOSES rather than one every
        # containment pushes forward — a hopeless row would otherwise stay retryable for exactly as
        # long as anything kept retrying it.
        expect(poisoned.reload.embed_failed_at).to eq(stamped)
        expect(poisoned.embed_failure_count).to eq(2)
      end

      it "gives up on it once the window has closed, and leaves it queryable as such" do
        poisoned = poisoned_backlog_row
        _second, resolver = sweeping_run(ci_run_id: "run-3", poison: poisoned)
        resolver.resolve

        # `update_all` rather than a time-travel helper, the choice this file makes throughout:
        # assert the fact the fixture needs — this row was first contained longer ago than the
        # window — rather than moving the clock underneath everything else in the example.
        SpecObservation.where(id: poisoned.id)
                       .update_all(embed_failed_at: SpecObservation::EMBED_RETRY_WINDOW.ago - 1.second)

        later_ingest(ci_run_id: "run-4")

        # No longer swept at all: the count did not move, so nothing reached it. The bound is the
        # ordinary one `EMBED_RETRY_WINDOW` already applies to a provider failure, reached by a row
        # that got its stamp from containment instead.
        expect(poisoned.reload.embed_failure_count).to eq(1)
        expect(repository.spec_observations.embed_retryable).to be_empty
        # "We stopped trying" and "we are still trying" stay two figures.
        expect(repository.spec_observations.embed_abandoned.pluck(:id)).to eq([poisoned.id])
      end

      it "contains the INHERITED half only: a failure in this run's own list still ends the pass" do
        # The asymmetry, and the reason it is one. An inherited row is work this delivery volunteered
        # for on an earlier one's behalf, so its failure is contained; this run's rows are what the
        # caller actually asked for, so their failure is still a report. `die_after(rows: 1)` lets
        # the ONE backlog row through and raises on the first row of `@run`'s own list.
        stranded = poisoned_backlog_row.test_run

        run = record(suite, ci_run_id: "run-2")
        die_after(run, rows: 1)

        # The inherited row was rescued on the way past — containment did not turn the backlog into
        # something the pass skips — and then this run's own failure escaped, exactly as it did
        # before this change.
        expect(stranded.spec_observations.sole.reload.spec_identity_id).to be_present
        expect(run.spec_observations.unresolved).not_to be_empty
      end

      it "does not manufacture a clean sweep out of a database it cannot even stamp" do
        # The documented non-promise on `#claim_inherited`. The containment is itself an UPDATE, so a
        # failure broad enough to take the connection with it raises from inside the rescue and
        # propagates as before. A database that cannot be written to must not produce a delivery that
        # reports a clean pass.
        poisoned = poisoned_backlog_row
        _run, resolver = sweeping_run(ci_run_id: "run-2", poison: poisoned)
        allow(resolver).to receive(:record_resolve_failure)
          .and_raise(ActiveRecord::StatementInvalid, "server closed the connection unexpectedly")

        expect { resolver.resolve }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    # The cost half of the slice, and the reason it came with a migration. The failure backlog's
    # index is partial on `embed_failed_at IS NOT NULL AND spec_identity_id IS NULL`; this sweep's
    # predicate is the COMPLEMENT of its leading clause, so that index cannot serve it at all. The
    # sweep runs on every ingest — the hottest path in the application — and unindexed it is a
    # repository-wide scan of a table holding `BRANCH_RETENTION_RUNS` runs of a 20,000-example suite
    # per branch, to find nothing on a healthy repository.
    describe "the plan Postgres chooses for it" do
      let(:resolved_runs) { 10 }
      let(:rows_per_run) { 500 }
      # A backlog LARGER than one sweep may take — the shape the ordering keys are in the index for,
      # and the design point `RETRY_SWEEP_LIMIT` is written against: *"a provider outage across a
      # 20,000-example run leaves 20,000 failed rows"*, and a job that died mid-resolve leaves as
      # many unattempted ones.
      let(:stranded_rows) { 4 * described_class::RETRY_SWEEP_LIMIT }

      # What the sweep asks for, and deliberately far below the backlog above. `#retry_backlog`
      # hands this list the REMAINDER of the shared budget, so a small number here is an ordinary
      # production call and not a contrivance — it is what every ingest issues while a failure
      # backlog is draining.
      #
      # It is small for a second reason, and that one is about keeping this example honest rather
      # than about fidelity. The margin between the two candidate plans narrows as the suite's own
      # rolled-back inserts bloat the table: an index scan's per-row cost rises with the heap it has
      # to fetch from, so at a cap near the backlog size the planner's choice comes down to a
      # tiebreak that RSpec's ordering decides — which is exactly the flakiness
      # spec/models/spec_observation_spec.rb records having been bitten by, and it certified nothing
      # while it lasted. The property under test is that the cap STOPS the read early, and asking
      # for a small slice of a large backlog is where that property is worth orders of magnitude
      # rather than percent.
      let(:sweep_limit) { 25 }

      # Seeded by `insert_all` rather than through the ingest path. These rows are BALLAST for the
      # planner and nothing reads their content, so the rule the file header states (SPGD-91 — a
      # fixture must not build a state the producer cannot) is not what is at stake: the columns
      # that decide this plan are `repository_id`, `created_at`, `spec_identity_id` and
      # `embed_failed_at`, all of which production writes exactly as this does.
      def seed(test_run, identity:, created_at:, rows:)
        SpecObservation.insert_all((1..rows).map do |index|
          path = "spec/f#{index % 25}_spec.rb"
          { test_run_id: test_run.id, repository_id: repository.id,
            example_id: "./#{path}[1:#{index}]", spec_file_path: path, file_path: path,
            line_number: index, name: "example #{index}", status: "unannotated",
            spec_identity_id: identity&.id, created_at: created_at, updated_at: created_at }
        end)
      end

      # A repository with history behind it and one run stranded in it. Three properties of this
      # seed are each load-bearing, and the assertion certifies nothing without all three — every
      # one of them was found by a spelling of this example that passed or failed for the wrong
      # reason:
      #
      # * **Most rows resolved**, so the partial index is a small fraction of the table. A planner
      #   handed a table where every row matches the partial predicate has no reason to prefer it.
      # * **The runs spread over TIME** rather than all written at `Time.current`. `created_at` and
      #   `spec_identity_id` are perfectly correlated in a single-instant seed — every unresolved
      #   row is also the only old row — and Postgres multiplies the two selectivities as though
      #   they were independent, underestimating the backlog by 20×. The plan it then picks is
      #   chosen against a row count production never has.
      # * **A backlog larger than `RETRY_SWEEP_LIMIT`**, which is what makes the ORDERING half of
      #   the index matter. Below the cap the sweep needs every row it can find and sorting a few
      #   hundred of them is nearly free, so the planner may reasonably narrow on
      #   `index_spec_observations_on_spec_identity_id` — a plain index on a nullable column, whose
      #   btree indexes its NULLs — and sort. Above the cap that plan has to read and sort the WHOLE
      #   backlog to hand back 500 rows, while this index yields them already ordered and stops. The
      #   cost it avoids grows with the backlog, which is precisely when it is worth avoiding.
      before do
        identity = create_spec_identity(repository: repository)
        resolved_runs.times do |index|
          seed(create_test_run(repository: repository), identity: identity,
               created_at: (index * 7).hours.ago, rows: rows_per_run)
        end
        seed(create_test_run(repository: repository), identity: nil,
             created_at: (SpecObservation::EMBED_ATTEMPT_GRACE + 1.hour).ago, rows: stranded_rows)

        # Without stats the planner works off hard-coded defaults and its choice says nothing about
        # the data. `ANALYZE` is legal inside the transaction the suite wraps each example in.
        ActiveRecord::Base.connection.execute("ANALYZE spec_observations")
      end

      it "reads the never-attempted backlog off its own partial index, in order, and stops at the cap" do
        # EXPLAINed from the relation the resolver ACTUALLY walks rather than from a hand-written
        # copy of it — a copy is a second definition of the query, and a plan assertion against the
        # copy would be asserting nothing about the sweep.
        relation = described_class.new(create_test_run(repository: repository))
                                  .send(:unattempted_embed_backlog, sweep_limit)
        plan = ActiveRecord::Base.connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")

        expect(plan).to include("index_spec_observations_on_unattempted_embed_backlog")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
        # No `Sort` node, which is the half of the criterion the index name alone does not carry:
        # the rows come back in the sweep's own order, so the `LIMIT` stops after 500 of them rather
        # than after the whole backlog has been read and ordered.
        expect(plan).not_to match(/Sort Key:/)
      end
    end
  end

  describe "running twice over the same run" do
    it "is a no-op the second time, because the work list is the unresolved rows" do
      run = ingest(suite, ci_run_id: "run-1")

      expect { described_class.resolve(run) }.not_to change(SpecIdentity, :count)
      expect(described_class.resolve(run)).to eq(0)
    end
  end

  describe "what it reports" do
    it "counts the observations it gave an identity to" do
      expect(described_class.resolve(record(suite, ci_run_id: "run-1"))).to eq(3)
    end

    it "counts a rescued row of an earlier run, because this invocation is what resolved it" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")
      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset

      second = record([unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3,
                                        name: "User#save rejects a duplicate email")],
                      ci_run_id: "run-2")

      # One row of its own and one rescued. Counting only `second`'s rows would report a sweep that
      # did real work as a no-op — see the `@return` on `IdentityResolver#resolve`.
      expect(described_class.resolve(second)).to eq(2)
    end
  end
end
