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
    it "is byte-identical to open-test-intent's published blob" do
      bytes = described_class::SCHEMA_PATH.binread
      blob_sha = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)

      expect(blob_sha).to eq(described_class::SCHEMA_BLOB_SHA)
    end

    it "is draft-07 and closed to additional properties" do
      document = JSON.parse(described_class::SCHEMA_PATH.read)

      expect(document["$schema"]).to eq("http://json-schema.org/draft-07/schema#")
      expect(document["additionalProperties"]).to be(false)
    end
  end

  describe ".validation_errors" do
    it "is empty for an intent that satisfies the contract" do
      expect(described_class.validation_errors(intent)).to be_empty
      expect(described_class).to be_valid(intent)
    end

    it "accepts the optional preconditions array" do
      expect(described_class.validation_errors(intent(preconditions: ["the invoice has line items"])))
        .to be_empty
    end

    it "names every missing required field at once" do
      errors = described_class.validation_errors({})

      expect(errors.join(" ")).to include("entity", "action", "behavior", "layer")
    end

    it "rejects a behavior below the 15-character floor" do
      errors = described_class.validation_errors(intent(behavior: "works"))

      expect(errors.join(" ")).to include("/behavior")
    end

    it "rejects an entity below the 2-character floor" do
      errors = described_class.validation_errors(intent(entity: "I"))

      expect(errors.join(" ")).to include("/entity")
    end

    it "rejects a layer outside the enum" do
      errors = described_class.validation_errors(intent(layer: "acceptance"))

      expect(errors.join(" ")).to include("/layer")
    end

    it "rejects an unknown property" do
      errors = described_class.validation_errors(intent(severity: "high"))

      expect(errors.join(" ")).to include("/severity")
    end

    it "reports every failure rather than stopping at the first" do
      errors = described_class.validation_errors(intent(entity: "I", behavior: "works"))

      expect(errors.size).to eq(2)
    end

    it "rejects a non-object intent without blowing up" do
      expect(described_class.validation_errors("Invoice finalize")).to eq(["must be a JSON object"])
      expect(described_class.validation_errors(nil)).to eq(["must be a JSON object"])
    end
  end
end
