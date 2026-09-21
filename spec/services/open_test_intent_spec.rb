# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe OpenTestIntent do
  def intent(**overrides)
    {
      "entity" => "Invoice",
      "action" => "finalize",
      "behavior" => "locks the line items once the invoice is finalized",
      "layer" => "unit"
    }.merge(overrides.transform_keys(&:to_s))
  end

  describe "the vendored schema file" do
    # AC5 of SPGD-80, kept as a test rather than a one-off check at review time. The copy is only
    # trustworthy while it is *identical* to what `open-test-intent` publishes; a well-meaning
    # local edit (loosening a minLength to make a spec pass, say) would fork the protocol from its
    # publisher and nothing else in this repo would notice.
    # @intent: { entity: "OpenTestIntent", action: "pin the schema blob", behavior: "the vendored schema hashes to the recorded git blob SHA, proving no local edit forked it from the publisher", layer: "unit" }
    it "is byte-identical to open-test-intent's published blob" do
      bytes = described_class::SCHEMA_PATH.binread
      blob_sha = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)

      expect(blob_sha).to eq(described_class::SCHEMA_BLOB_SHA)
    end

    # @intent: { entity: "OpenTestIntent", action: "declare the schema's shape", behavior: "the document declares draft-07 and additionalProperties false at its root", layer: "unit" }
    it "is draft-07 and closed to additional properties" do
      document = JSON.parse(described_class::SCHEMA_PATH.read)

      expect(document["$schema"]).to eq("http://json-schema.org/draft-07/schema#")
      expect(document["additionalProperties"]).to be(false)
    end
  end

  # The cross-repo half of the copy's identity, and a DIFFERENT question from the blob pin above.
  # `SCHEMA_BLOB_SHA` is a git blob SHA-1: it catches a local edit forking this file from its
  # publisher, and it is comparable with nothing outside this repository. `schema_sha256` is the
  # digest the rest of the family holds — `open-test-intent`'s `CanonicalV1SHA256`,
  # `specguard-rspec`'s `CANONICAL_V1_SHA256`, `specguard-ts`'s `SCHEMA_CONTRACT_DIGEST` — and is
  # what `GET /version` serves so a client can check which contract this server ENFORCES. Both are
  # kept: neither answers the other's question.
  describe ".schema_sha256" do
    # The stubbed-fold example below writes a fake digest into the MODULE-level memo, which
    # outlives the stub RSpec tears down at the end of that example — and `GET /version` serves
    # that memo, so a leak here fails examples in OTHER FILES depending on suite order. Cleared on
    # the way out for the same reason `server_version_spec.rb` does it: the poisoning happens
    # DURING the example, so a before-only clear cannot undo it. On the group rather than on the
    # one stubbing example, so an example added later is covered without anyone remembering to.
    after do
      described_class.remove_instance_variable(:@schema_sha256) if
        described_class.instance_variable_defined?(:@schema_sha256)
    end

    # Derived from the file, never a literal: a hardcoded expectation would be re-typed alongside
    # a re-vendoring and agree with itself forever. The literal that IS pinned lives once, in
    # `spec/requests/server_version_spec.rb`, as the family's shared constant.
    # @intent: { entity: "OpenTestIntent", action: "digest the enforced schema", behavior: "the reader answers the lowercase hex SHA-256 of the vendored schema file, derived from the file rather than a hardcoded literal", layer: "unit" }
    it "is the SHA-256 of the vendored schema's own bytes" do
      expect(described_class.schema_sha256)
        .to eq(Digest::SHA256.hexdigest(described_class::SCHEMA_PATH.binread))
      expect(described_class.schema_sha256).to match(/\A[0-9a-f]{64}\z/)
    end

    # It folds over `raw_document` — the bytes already in memory — rather than re-reading the path:
    # a reader that re-read could digest something other than what the validator loaded, which is
    # the exact failure an enforced-schema report exists to rule out. Pinned by OBJECT IDENTITY on
    # the argument, not by equality: a fresh `binread` of the same file produces an EQUAL string,
    # so `have_received(...).with(loaded)` — which matches with `==` — passes against exactly the
    # implementation this example exists to reject. `equal` is the discriminator (mutation-verified:
    # swapping the fold to `SCHEMA_PATH.binread` turns this red, and left this green when it was
    # written with `with`).
    # @intent: { entity: "OpenTestIntent", action: "digest the loaded bytes", behavior: "the digest is folded over the same raw_document object the validator and the schema mirror serve, not over an equal string from a fresh read of the path", layer: "unit" }
    it "digests the bytes already loaded rather than re-reading the file" do
      loaded = described_class.raw_document
      digested = nil
      allow(Digest::SHA256).to receive(:hexdigest) { |bytes| digested = bytes; "0" * 64 }
      described_class.remove_instance_variable(:@schema_sha256) if
        described_class.instance_variable_defined?(:@schema_sha256)

      described_class.schema_sha256

      expect(digested).to equal(loaded)
    end

    # The mirror's whole claim is byte-identity with the canonical document, so the digest reader
    # must be a pure read of those bytes: no re-serialization, no mutation, not even a thaw.
    # @intent: { entity: "OpenTestIntent", action: "leave the mirrored bytes untouched", behavior: "taking the digest leaves raw_document the same frozen object with the same bytes the schema mirror serves", layer: "unit" }
    it "leaves raw_document untouched for the byte-identical mirror" do
      before_bytes = described_class.raw_document

      described_class.schema_sha256

      expect(described_class.raw_document).to equal(before_bytes)
      expect(described_class.raw_document).to eq(described_class::SCHEMA_PATH.binread)
      expect(described_class.raw_document).to be_frozen
    end
  end

  describe ".validation_errors" do
    # @intent: { entity: "OpenTestIntent", action: "accept a valid intent", behavior: "a contract-shaped intent produces no validation errors and passes the valid? predicate", layer: "unit" }
    it "is empty for an intent that satisfies the contract" do
      expect(described_class.validation_errors(intent)).to be_empty
      expect(described_class).to be_valid(intent)
    end

    # @intent: { entity: "OpenTestIntent", action: "accept preconditions", behavior: "an intent carrying a preconditions array is accepted alongside the four required keys", layer: "unit" }
    it "accepts the optional preconditions array" do
      expect(described_class.validation_errors(intent(preconditions: ["the invoice has line items"])))
        .to be_empty
    end

    # @intent: { entity: "OpenTestIntent", action: "report every missing field", behavior: "an empty object reports entity, action, behavior and layer together rather than one at a time", layer: "unit" }
    it "names every missing required field at once" do
      errors = described_class.validation_errors({})

      expect(errors.join(" ")).to include("entity", "action", "behavior", "layer")
    end

    # @intent: { entity: "OpenTestIntent", action: "enforce the behavior floor", behavior: "a behavior under 15 characters is rejected with a pointer at /behavior", layer: "unit" }
    it "rejects a behavior below the 15-character floor" do
      errors = described_class.validation_errors(intent(behavior: "works"))

      expect(errors.join(" ")).to include("/behavior")
    end

    # @intent: { entity: "OpenTestIntent", action: "enforce the entity floor", behavior: "an entity under 2 characters is rejected with a pointer at /entity", layer: "unit" }
    it "rejects an entity below the 2-character floor" do
      errors = described_class.validation_errors(intent(entity: "I"))

      expect(errors.join(" ")).to include("/entity")
    end

    # @intent: { entity: "OpenTestIntent", action: "enforce the layer enum", behavior: "a layer outside unit, integration, request and system is rejected with a pointer at /layer", layer: "unit" }
    it "rejects a layer outside the enum" do
      errors = described_class.validation_errors(intent(layer: "acceptance"))

      expect(errors.join(" ")).to include("/layer")
    end

    # @intent: { entity: "OpenTestIntent", action: "reject unknown properties", behavior: "a key beyond the required four plus preconditions is rejected by name", layer: "unit" }
    it "rejects an unknown property" do
      errors = described_class.validation_errors(intent(severity: "high"))

      expect(errors.join(" ")).to include("/severity")
    end

    # @intent: { entity: "OpenTestIntent", action: "aggregate failures", behavior: "two constraint violations on one intent yield two errors rather than only the first", layer: "unit" }
    it "reports every failure rather than stopping at the first" do
      errors = described_class.validation_errors(intent(entity: "I", behavior: "works"))

      expect(errors.size).to eq(2)
    end

    # @intent: { entity: "OpenTestIntent", action: "reject non-object input", behavior: "a string or nil input yields a single must-be-a-JSON-object error instead of raising", layer: "unit" }
    it "rejects a non-object intent without blowing up" do
      expect(described_class.validation_errors("Invoice finalize")).to eq(["must be a JSON object"])
      expect(described_class.validation_errors(nil)).to eq(["must be a JSON object"])
    end
  end
end
