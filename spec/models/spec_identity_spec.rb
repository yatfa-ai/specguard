# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpecIdentity do
  let(:repository) { create_repository }

  describe "the small-tenant exact re-answer (SPGD-983)" do
    # CI reddened three times on this family (SPGD-879, SPGD-969, SPGD-983 — run 34097827587)
    # with `cluster_count: 0` served for a fixture whose pair sits at cosine 0.89: the HNSW
    # descent had walked itself into graph structure it could never return (invisible vertices —
    # rolled-back ingests, foreign tenants — are fully traversable; pgvector 0.8.6's
    # `HnswLoadElementImpl` performs no visibility or qualification check during the walk) and
    # came back empty, and the read printed that silence as a finding. On a tenant this small
    # the read now re-answers exactly instead. The provider is LEXICAL here, on the model
    # spec's own calibrated pair, so the exact pass has a real pair to find — under the
    # suite-wide deterministic stub two different strings are near-orthogonal and these
    # examples would pass for the wrong reason.
    include_context "with lexical embeddings"

    let(:expired) { "Checkout rejects an expired card" }
    let(:outright) { "Checkout rejects an expired card outright" }

    # The stub is the one honest way to hand the guard an empty approximate answer at spec
    # scale: inducing it through the real scan needs a graph polluted at CI-suite scale
    # (hundreds of thousands of dead vertices — see the constant's comment). What is pinned
    # here is the guard's contract — "an empty approximate answer on a small tenant is
    # re-answered, exactly, through the same statement" — with the exact pass running FOR REAL.
    # Without the guard these examples go red exactly the way CI did. Returns the number of
    # exact passes issued, so each example can assert the boundary it names.
    def with_empty_approximate_pass
      exact_calls = 0
      original = described_class.method(:run_pair_read)
      allow(described_class).to receive(:run_pair_read) do |repo, **kwargs|
        if kwargs[:exact]
          exact_calls += 1
          original.call(repo, **kwargs)
        else
          []
        end
      end
      yield
      exact_calls
    end

    def read(identity_count: nil)
      described_class.near_duplicate_pairs_in(repository, similarity: NearDuplicateClusters::SIMILARITY,
                                                           neighbours: NearDuplicateClusters::NEIGHBOURS,
                                                           run_id: nil,
                                                           identity_count: identity_count ||
                                                             described_class.clusterable_population_in(repository)[:identity_count])
    end

    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "when the approximate pass answers empty on a small tenant the read re-runs the same statement on the exact plan and serves the pair the graph missed", layer: "unit" }
    it "re-answers exactly when the approximate pass answers empty on a small tenant" do
      create_spec_identity(repository: repository, text: expired, line_number: 3)
      create_spec_identity(repository: repository, text: outright, line_number: 9)
      create_spec_identity(repository: repository, text: "Shipping calculates a delivery estimate", line_number: 12)

      rows = nil
      exact_calls = with_empty_approximate_pass { rows = read }

      expect(exact_calls).to eq(1)
      # One PAIR, returned from both ends — cosine is symmetric, so each identity's lateral
      # finds the other; the shape the request spec's member_count of 2 is built from. The row
      # carries the neighbour as an id (index 8), so the "each end found the other" claim reads
      # it back through the table.
      expect(rows.size).to eq(2)
      expect(rows.map { |row| row[1] }).to contain_exactly(expired, outright)
      neighbour_texts = rows.map { |row| described_class.find(row[8]).text }
      expect(neighbour_texts).to contain_exactly(outright, expired)
    end
    # The re-read is bounded work, not a blanket retry: a repository that cannot hold a pair
    # (0 or 1 identities) gets its empty answer straight through, because no graph state can
    # hide a pair that has no second identity to be near.
    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "a repository with fewer than two identities has its empty answer served untouched, with no exact pass issued", layer: "unit" }
    it "serves the empty answer untouched when the repository cannot hold a pair" do
      create_spec_identity(repository: repository, text: expired, line_number: 3)

      rows = nil
      exact_calls = with_empty_approximate_pass { rows = read }

      expect(rows).to be_empty
      expect(exact_calls).to eq(0)
    end

    # Above the cap the empty answer passes through: the exact shape is the 69.06-second
    # all-pairs sort at 3,000 identities, and a legitimately duplicate-free large tenant must
    # not pay it on every census render. The remaining large-tenant recall exposure is
    # SPGD-72's decision, not this read's.
    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "a repository above the exact-reanswer population cap has its empty answer served untouched, with no exact pass issued", layer: "unit" }
    # Above the cap the empty answer passes through: the exact shape is the 69.06-second
    # all-pairs sort at 3,000 identities, and a legitimately duplicate-free large tenant must
    # not pay it on every census render. The remaining large-tenant recall exposure is
    # SPGD-72's decision, not this read's. The boundary is pinned at the read's own argument —
    # the census object feeds it from `clusterable_population_in`, whose counting is pinned by
    # the coverage examples next door — so this needs no large tenant seeded to be exact.
    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "a repository above the exact-reanswer population cap has its empty answer served untouched, with no exact pass issued", layer: "unit" }
    it "serves the empty answer untouched above the population cap" do
      rows = nil
      exact_calls = with_empty_approximate_pass { rows = read(identity_count: described_class::EXACT_REANSWER_POPULATION_CAP + 1) }

      expect(rows).to be_empty
      expect(exact_calls).to eq(0)
    end

    # The cap itself is INSIDE the re-answer: an off-by-one here silently moves whole
    # populations between the exact and approximate regimes, so the boundary is pinned on
    # both sides of it rather than assumed from the comparison operator.
    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "a repository at exactly the population cap still gets the exact re-answer", layer: "unit" }
    it "re-answers at the cap itself, which is inclusive" do
      exact_calls = with_empty_approximate_pass do
        read(identity_count: described_class::EXACT_REANSWER_POPULATION_CAP)
      end

      expect(exact_calls).to eq(1)
    end

    # And the guard is silent while the approximate path is healthy: a non-empty answer never
    # pays a second read, so the plan-asserting and cost-pinning examples next door are
    # measuring one execution, as they always were.
    # @intent: { entity: "SpecIdentity", action: "re-answer an empty census exactly", behavior: "a non-empty approximate answer is served as-is with no exact pass issued", layer: "unit" }
    it "does not pay a second read when the approximate pass answers" do
      create_spec_identity(repository: repository, text: expired, line_number: 3)
      create_spec_identity(repository: repository, text: outright, line_number: 9)

      exact_calls = 0
      original = described_class.method(:run_pair_read)
      allow(described_class).to receive(:run_pair_read) do |repo, **kwargs|
        if kwargs[:exact]
          exact_calls += 1
          original.call(repo, **kwargs)
        else
          original.call(repo, **kwargs)
        end
      end

      read

      expect(exact_calls).to eq(0)
    end
  end

  describe "the two thresholds, which must not become one" do
    # The matching threshold and the duplicate-detection threshold read the same embedding and ask
    # opposite questions: "are these two observations the same test" versus "are these two tests
    # redundant with each other". A pair the duplicate engine is meant to REPORT has to RESOLVE as
    # two identities, so matching must sit strictly above duplication. Pinned as an inequality
    # rather than as a literal, because what matters is the ordering, not the number — and read off
    # the other constant rather than off a copy of it, so that moving EITHER one past the other goes
    # red here. It previously asserted `> 0.88`, which is neither constant (the duplicate engine
    # ships 0.85) and so pinned the ordering to a number no code held; that literal is the exact
    # failure this example's own comment says it exists to avoid.
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "the matching similarity constant sits strictly above the duplicate engine's reporting threshold, so a pair the duplicate engine reports still resolves as two distinct identities", layer: "unit" }
    it "matches more strictly than the duplicate engine reports" do
      expect(described_class::MATCH_SIMILARITY).to be > NearDuplicateClusters::SIMILARITY
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "the neighbour distance constant is computed from the similarity constant rather than independently declared, keeping the two representations from drifting apart", layer: "unit" }
    it "expresses the distance the neighbor scope wants, derived rather than restated" do
      expect(described_class::MATCH_DISTANCE).to eq(1 - described_class::MATCH_SIMILARITY)
    end
  end

  describe "the identity key" do
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "saving the same test text at a different line number in one repository is rejected, because identity is keyed on text and not on location", layer: "unit" }
    it "is the text, so the same test on a different line is not a second row" do
      create_spec_identity(repository: repository, text: "Cart adds an item", line_number: 3)

      duplicate = repository.spec_identities.new(
        text: "Cart adds an item", text_digest: described_class.digest_for("Cart adds an item"),
        signal_source: "name", embedding: EmbeddingGenerator.call("Cart adds an item"),
        file_path: "spec/models/cart_spec.rb", line_number: 900
      )

      expect(duplicate).not_to be_valid
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "inserting identical test text under two different repositories creates two rows, so tenant isolation permits the same wording across tenants", layer: "unit" }
    it "is scoped to the repository — two tenants may hold the same test text" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other")
      create_spec_identity(repository: repository, text: "Cart adds an item")

      expect { create_spec_identity(repository: other, text: "Cart adds an item") }
        .to change(described_class, :count).by(1)
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "silencing the uniqueness validator and racing a second insert still raises RecordNotUnique, proving the database index enforces the key the validation only guards", layer: "unit" }
    it "is enforced by the database, not only by the validation in front of it" do
      # The read-then-write validation cannot see an uncommitted competitor, so the index is what
      # actually answers the race `Ingest::IdentityResolver` handles — see spec/support/
      # uniqueness_race.rb for why silencing the validator is what puts the database in the frame.
      allow(uniqueness_validator(described_class)).to receive(:validate_each)
      create_spec_identity(repository: repository, text: "Cart adds an item")

      expect { create_spec_identity(repository: repository, text: "Cart adds an item") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "the stored digest equals the SHA256 hex digest of the text alone, showing no other input feeds the digest", layer: "unit" }
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
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "an identity without an embedding fails validation and even a validation-skipping save hits a NotNullViolation, so no row can exist that neighbour search would silently skip", layer: "unit" }
    it "cannot be null, so no row can exist that resolution is blind to" do
      identity = repository.spec_identities.new(
        text: "Cart adds an item", text_digest: described_class.digest_for("Cart adds an item"),
        signal_source: "name", file_path: "spec/models/cart_spec.rb", line_number: 3
      )

      expect(identity).not_to be_valid
      expect { identity.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "a nearest-neighbour cosine query for the exact embedding returns the row at essentially zero distance, confirming the distance metric works end to end", layer: "unit" }
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
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "the embedding column carries an HNSW index using halfvec cosine operators, so neighbour search scales rather than degrading to a sequential scan", layer: "unit" }
    it "has an HNSW cosine index behind that search" do
      index = ActiveRecord::Base.connection.indexes("spec_identities")
                                .find { |candidate| candidate.columns == ["embedding"] }

      expect(index.using).to eq(:hnsw)
      expect(index.opclasses).to eq(:halfvec_cosine_ops)
    end
  end

  describe "which text supplied the identity" do
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "a signal source outside the two values Ingest::SpecSignal produces is rejected with an error on that attribute", layer: "unit" }
    it "refuses a source that is neither of Ingest::SpecSignal's two answers" do
      identity = repository.spec_identities.new(signal_source: "none")

      identity.valid?

      expect(identity.errors[:signal_source]).to be_present
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "the from_intent and from_name predicates return true for their respective rows, letting consumers distinguish declared intents from inferred names", layer: "unit" }
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
    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "destroying the last observing run nullifies the reference but leaves the identity row, so identity outlives run retention", layer: "unit" }
    it "survives the run that last observed it" do
      run = create_test_run(repository: repository)
      identity = create_spec_identity(repository: repository, last_seen_test_run: run)

      run.destroy!

      expect(identity.reload.last_seen_test_run_id).to be_nil
    end

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "destroying an identity nullifies the observation's foreign key but keeps the measurement row, so histories survive identity loss", layer: "unit" }
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

    # @intent: { entity: "SpecIdentity", action: "constrain the identity table's keys and embedding search", behavior: "destroying the repository removes its identities, tying the table's lifetime to the tenant", layer: "unit" }
    it "goes when its repository does" do
      create_spec_identity(repository: repository)

      expect { repository.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
