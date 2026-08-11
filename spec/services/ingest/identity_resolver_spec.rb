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
    # Reproduced the way `spec/support/uniqueness_race.rb` describes the shape — the loser's lookup
    # cannot see a winner that has not committed, so it returns nothing and goes to insert while the
    # row is already there. That is stubbed at `#nearest`, the one call whose answer the race
    # changes, rather than by racing threads a transactional example cannot run; everything after it
    # — the upsert, the conflict, the link — is the real code path. Without the `ON CONFLICT` clause
    # this example raises `ActiveRecord::RecordNotUnique` rather than merely counting wrong.
    def resolve_as_the_loser(run)
      resolver = described_class.new(run)
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

      # Recorded and not resolved: the state the endpoint answers `202` from.
      unattempted = record([unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                             name: "User#save rejects a duplicate email")],
                           ci_run_id: "run-3")

      expect(repository.spec_observations.unresolved.pluck(:test_run_id))
        .to contain_exactly(signalless.id, failed.id, unattempted.id)
      # One predicate, and it picks the recoverable one out of the three.
      expect(repository.spec_observations.embed_failed.pluck(:test_run_id)).to eq([failed.id])
      expect(repository.spec_observations.embed_retryable.pluck(:test_run_id)).to eq([failed.id])
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

      # The falsifier for the sweep's ORDER. Resolve the backlog after this run's own rows and the
      # identity reports line 5 — a "last known path" that moved backwards in time.
      identity = repository.spec_identities.sole
      expect(identity.location).to eq("spec/models/cart_spec.rb:90")
      expect(identity.last_seen_test_run_id).to eq(second.id)
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
