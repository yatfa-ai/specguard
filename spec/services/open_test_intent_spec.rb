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
