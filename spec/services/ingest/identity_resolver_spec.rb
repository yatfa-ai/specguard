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

    it "sits above the duplicate-detection band, so a duplicate pair stays two tests" do
      # The two questions share an embedding and must never share a threshold: a pair the duplicate
      # engine is meant to REPORT as redundant has to RESOLVE as two identities.
      expect(SpecIdentity::MATCH_SIMILARITY).to be > 0.88
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

    it "resolves it on the next run once the provider is back — nothing is permanently lost" do
      allow(EmbeddingGenerator).to receive(:call).and_raise(EmbeddingGenerator::Error, "provider down")
      first = ingest([unannotated_spec(name: "Cart adds an item to the cart")], ci_run_id: "run-1")

      RSpec::Mocks.space.proxy_for(EmbeddingGenerator).reset
      described_class.resolve(first.reload)

      expect(first.spec_observations.sole.reload.spec_identity_id).to eq(repository.spec_identities.sole.id)
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
  end
end
