# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpecIdentity do
  let(:repository) { create_repository }

  describe "the two thresholds, which must not become one" do
    # The matching threshold and the duplicate-detection threshold read the same embedding and ask
    # opposite questions: "are these two observations the same test" versus "are these two tests
    # redundant with each other". A pair the duplicate engine is meant to REPORT has to RESOLVE as
    # two identities, so matching must sit strictly above duplication. Pinned as an inequality
    # rather than as a literal, because what matters is the ordering, not the number.
    it "matches more strictly than the duplicate engine reports" do
      expect(described_class::MATCH_SIMILARITY).to be > 0.88
    end

    it "expresses the distance the neighbor scope wants, derived rather than restated" do
      expect(described_class::MATCH_DISTANCE).to eq(1 - described_class::MATCH_SIMILARITY)
    end
  end

  describe "the identity key" do
    it "is the text, so the same test on a different line is not a second row" do
      create_spec_identity(repository: repository, text: "Cart adds an item", line_number: 3)

      duplicate = repository.spec_identities.new(
        text: "Cart adds an item", text_digest: described_class.digest_for("Cart adds an item"),
        signal_source: "name", embedding: EmbeddingGenerator.call("Cart adds an item"),
        file_path: "spec/models/cart_spec.rb", line_number: 900
      )

      expect(duplicate).not_to be_valid
    end

    it "is scoped to the repository — two tenants may hold the same test text" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other")
      create_spec_identity(repository: repository, text: "Cart adds an item")

      expect { create_spec_identity(repository: other, text: "Cart adds an item") }
        .to change(described_class, :count).by(1)
    end

    it "is enforced by the database, not only by the validation in front of it" do
      # The read-then-write validation cannot see an uncommitted competitor, so the index is what
      # actually answers the race `Ingest::IdentityResolver` handles — see spec/support/
      # uniqueness_race.rb for why silencing the validator is what puts the database in the frame.
      allow(uniqueness_validator(described_class)).to receive(:validate_each)
      create_spec_identity(repository: repository, text: "Cart adds an item")

      expect { create_spec_identity(repository: repository, text: "Cart adds an item") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "derives the digest from the text and nowhere else" do
      identity = create_spec_identity(repository: repository, text: "Cart adds an item")

      expect(identity.text_digest).to eq(Digest::SHA256.hexdigest("Cart adds an item"))
    end
  end

  describe "the embedding" do
    # `neighbor`'s scope appends `.where.not(embedding: nil)`, so a NULL-embedding row is not
    # ranked last — it is excluded from resolution entirely and its test re-inserts as a new
    # identity on every subsequent run, silently and forever. The column refuses that state rather
    # than the codebase remembering not to reach it.
    it "cannot be null, so no row can exist that resolution is blind to" do
      identity = repository.spec_identities.new(
        text: "Cart adds an item", text_digest: described_class.digest_for("Cart adds an item"),
        signal_source: "name", file_path: "spec/models/cart_spec.rb", line_number: 3
      )

      expect(identity).not_to be_valid
      expect { identity.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "is searchable by cosine distance through the HNSW index" do
      create_spec_identity(repository: repository, text: "Cart adds an item")

      nearest = repository.spec_identities.nearest_neighbors(
        :embedding, EmbeddingGenerator.call("Cart adds an item"), distance: "cosine"
      ).first

      expect(nearest.neighbor_distance).to be_within(1e-6).of(0)
    end

    # The index itself, not merely a query that would also answer without it. At the 20,000-test
    # design point a sequential scan per example is the difference between a job and an outage, and
    # nothing above would fail if the index were dropped.
    it "has an HNSW cosine index behind that search" do
      index = ActiveRecord::Base.connection.indexes("spec_identities")
                                .find { |candidate| candidate.columns == ["embedding"] }

      expect(index.using).to eq(:hnsw)
      expect(index.opclasses).to eq(:vector_cosine_ops)
    end
  end

  describe "which text supplied the identity" do
    it "refuses a source that is neither of Ingest::SpecSignal's two answers" do
      identity = repository.spec_identities.new(signal_source: "none")

      identity.valid?

      expect(identity.errors[:signal_source]).to be_present
    end

    it "answers the declared-versus-inferred question a consumer will ask" do
      declared = create_spec_identity(repository: repository, text: "Invoice finalize locks lines",
                                      signal_source: "intent")
      inferred = create_spec_identity(repository: repository, text: "Cart adds an item",
                                      signal_source: "name")

      expect(declared).to be_from_intent
      expect(inferred).to be_from_name
    end
  end

  describe "what outlives what" do
    # The whole point of the table: `spec_observations` is pruned to
    # `SpecObservation::BRANCH_RETENTION_RUNS` runs per branch, and identity is not pruned at all.
    it "survives the run that last observed it" do
      run = create_test_run(repository: repository)
      identity = create_spec_identity(repository: repository, last_seen_test_run: run)

      run.destroy!

      expect(identity.reload.last_seen_test_run_id).to be_nil
    end

    it "leaves an observation's measurement behind when the identity itself goes" do
      run = create_test_run(repository: repository)
      identity = create_spec_identity(repository: repository)
      observation = SpecObservation.create!(
        test_run: run, repository: repository, spec_identity: identity,
        file_path: "spec/models/cart_spec.rb", line_number: 3, status: "unannotated"
      )

      identity.destroy!

      expect(observation.reload.spec_identity_id).to be_nil
    end

    it "goes when its repository does" do
      create_spec_identity(repository: repository)

      expect { repository.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
