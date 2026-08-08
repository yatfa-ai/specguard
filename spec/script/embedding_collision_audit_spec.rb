# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../../script/embedding_collision_audit"

# The audit script produces a number that docs/embedding-collision-audit.md records as fact and that
# roadmap SPGD-72 is expected to pick a similarity threshold from. These specs are what make that
# number trustworthy: they pin the two places the measurement could be quietly wrong — a corpus of
# names RSpec would never produce, and a "hashed" vector that is not the one production stores.
RSpec.describe EmbeddingCollisionAudit do
  # The audit runs against the real provider, not the suite-wide deterministic stub.
  before { EmbeddingGenerator.provider = EmbeddingGenerator::LocalProvider }

  describe EmbeddingCollisionAudit::Corpus do
    def extract(source)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "thing_spec.rb"), source)
        described_class.new([ dir ]).extract
      end
    end

    it "joins the describe/context/it chain the way RSpec builds a full description" do
      names = extract(<<~RUBY).names
        RSpec.describe Post do
          describe "#save" do
            context "when the author is anonymous" do
              it "raises" do
              end
            end
          end
        end
      RUBY

      # "Post#save", not "Post #save" — the glue rule for #, . and :: is RSpec's, and getting it
      # wrong would insert a space that no real example name contains.
      expect(names).to eq([ "Post#save when the author is anonymous raises" ])
    end

    it "keeps sibling examples apart and carries the whole trail into each" do
      names = extract(<<~RUBY).names
        describe "Checkout" do
          it "charges the card" do; end
          it "emails a receipt" do; end
        end
      RUBY

      expect(names).to contain_exactly("Checkout charges the card", "Checkout emails a receipt")
    end

    it "reads a namespaced constant subject through to its full path" do
      names = extract(<<~RUBY).names
        RSpec.describe Api::V1::RepositoriesController do
          it "indexes" do; end
        end
      RUBY

      expect(names).to eq([ "Api::V1::RepositoriesController indexes" ])
    end

    # Inventing corpus text is the one thing this measurement must not do — a name that no example
    # actually has would make the collision rate a measurement of the script's imagination.
    describe "names it refuses to invent" do
      let(:corpus) do
        extract(<<~'RUBY')
          describe "Modes" do
            it "handles #{mode} correctly" do; end
            it { is_expected.to be_valid }
            it "stays" do; end
          end
        RUBY
      end

      it "drops an interpolated description and counts it" do
        expect(corpus.names).to eq([ "Modes stays" ])
        expect(corpus.skipped_dynamic).to eq(1)
      end

      it "drops an example with no description at all and counts it separately" do
        expect(corpus.skipped_anonymous).to eq(1)
      end
    end

    it "does not mistake `example.metadata` inside an example for an example" do
      # `example` is both an RSpec example alias and the name of the object every example can call.
      corpus = extract(<<~RUBY)
        describe "Metadata" do
          it "reads its own metadata" do
            expect(example.metadata[:type]).to eq(:model)
          end
        end
      RUBY

      expect(corpus.names).to eq([ "Metadata reads its own metadata" ])
      expect(corpus.skipped_anonymous).to be_zero
    end

    it "counts the files it scanned and keeps going past a file it cannot parse" do
      # A 3,000-file corpus will contain something this walker chokes on; one bad file must not
      # abandon the other 2,999 and silently shrink the corpus.
      corpus = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "good_spec.rb"), 'describe("A") { it("b") {} }')
        File.write(File.join(dir, "broken_spec.rb"), "describe 'A' do |||")
        described_class.new([ dir ]).extract
      end

      expect(corpus.files).to eq(2)
      expect(corpus.names).to include("A b")
    end
  end

  describe EmbeddingCollisionAudit::Vectoriser do
    let(:vectoriser) { described_class.new }
    let(:name) { "Post#save when the author is anonymous raises" }

    # If this ever fails, the audit is measuring something other than what SpecGuard stores, and its
    # recorded false-match rate says nothing about this product.
    it "produces exactly the vector EmbeddingGenerator.call would store" do
      document = vectoriser.call(name)

      dense = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
      document.hashed_ids.each_with_index { |dimension, k| dense[dimension] = document.hashed_weights[k] }

      EmbeddingGenerator.call(name).each_with_index do |value, dimension|
        expect(dense[dimension]).to be_within(1e-12).of(value)
      end
    end

    it "gives the exact space one dimension per distinct feature, so it cannot collide" do
      document = vectoriser.call(name)
      features = EmbeddingGenerator::LocalProvider.new(name).features

      expect(document.exact_ids.size).to eq(features.uniq.size)
      expect(document.exact_ids.uniq.size).to eq(document.exact_ids.size)
    end

    it "shows the hashed space losing dimensions the exact space keeps — the effect under test" do
      # A long name has more features than 1536 has room for near-uniformly, so hashed nnz < exact.
      document = vectoriser.call(File.read(Rails.root.join("README.md"))[0, 20_000])

      expect(document.hashed_ids.size).to be < document.exact_ids.size
      expect(document.hashed_ids.size).to be <= EmbeddingGenerator::DIMENSIONS
    end

    it "unit-normalises both representations, so their cosines are directly comparable" do
      document = vectoriser.call(name)

      expect(document.hashed_weights.sum { |w| w * w }).to be_within(1e-12).of(1.0)
      expect(document.exact_weights.sum { |w| w * w }).to be_within(1e-12).of(1.0)
    end

    it "counts every distinct feature it has seen across the whole corpus" do
      vectoriser.call("alpha")
      vectoriser.call("alpha")

      expect(vectoriser.feature_count).to eq(EmbeddingGenerator::LocalProvider.new("alpha").features.uniq.size)
    end
  end

  describe EmbeddingCollisionAudit::Sweep do
    let(:names) do
      [
        "Checkout rejects an expired card",
        "Checkout rejects an expired card",  # an exact repeat: cosine 1.0 in both spaces
        "Audit log paginates by cursor"
      ]
    end
    let(:documents) { names.map { |name| EmbeddingCollisionAudit::Vectoriser.new.call(name) } }

    def sweep(thresholds, workers: 2)
      described_class.new(documents, thresholds).run(workers: workers)
    end

    it "compares every unordered pair exactly once" do
      expect(sweep([ 0.9 ])[:pairs]).to eq(3) # 3 choose 2
    end

    it "sees an identical pair as a match in both spaces, so it is not a false match" do
      bucket = sweep([ 0.9 ])[:thresholds][:"0.9"]

      expect(bucket[:hashed]).to eq(1)
      expect(bucket[:exact]).to eq(1)
      expect(bucket[:false_match]).to be_zero
      expect(bucket[:missed]).to be_zero
    end

    it "reaches the same totals however many workers it is split across" do
      # The census is forked across processes and merged; a merge bug would silently change the
      # published rate rather than fail.
      expect(sweep([ 0.9 ], workers: 1)).to eq(sweep([ 0.9 ], workers: 3))
    end

    it "records no overstatement for a corpus this small" do
      expect(sweep([ 0.9 ])[:worst]).to be_empty
    end
  end
end
