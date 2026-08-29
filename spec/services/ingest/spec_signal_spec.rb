# frozen_string_literal: true

require "rails_helper"

# Built as raw string-keyed hashes rather than through the `annotated_spec` / `unannotated_spec`
# builders on purpose: those describe the *wire* body a request spec POSTs, and go through JSON on
# the way in. This class is handed a spec hash after that parse, so the keys it reads are strings,
# and a spec built with symbols here would pass while production returned `:none` for everything.
RSpec.describe Ingest::SpecSignal do
  def spec(attrs = {})
    { "file_path" => "spec/models/invoice_spec.rb", "line_number" => 12,
      "status" => "unannotated", "intent" => nil, "name" => nil }.merge(attrs)
  end

  def intent(attrs = {})
    { "entity" => "Invoice", "action" => "finalize",
      "behavior" => "locks the line items once the invoice is finalized",
      "layer" => "unit" }.merge(attrs)
  end

  describe "an annotated spec" do
    subject(:signal) { described_class.for(spec("status" => "annotated", "intent" => intent)) }

    # @intent: { entity: "Ingest::SpecSignal", action: "build text from a declared intent", behavior: "the representation is the entity, action and behavior joined, not the human-readable it string", layer: "unit" }
    it "represents the test by the intent triple" do
      expect(signal.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
    end

    # @intent: { entity: "Ingest::SpecSignal", action: "report the source of the text", behavior: "an intent-derived signal is flagged as a declared claim with present true and from_name false", layer: "unit" }
    it "reports the intent as the source, so a consumer knows it holds a declared claim" do
      expect(signal).to have_attributes(source: :intent, present?: true,
                                        from_intent?: true, from_name?: false)
    end

    # `layer` classifies the test and `preconditions` qualify it; neither says what the test is
    # about, and folding "unit" in would put the same token in every unit test's text.
    # @intent: { entity: "Ingest::SpecSignal", action: "build text from qualifying parts only", behavior: "layer and preconditions are excluded from the text so classifying tokens never corrupt semantic identity", layer: "unit" }
    it "leaves layer and preconditions out of the text" do
      annotated = spec("status" => "annotated",
                       "intent" => intent("layer" => "integration",
                                          "preconditions" => ["the invoice is open"]))

      expect(described_class.for(annotated).text)
        .to eq("Invoice finalize locks the line items once the invoice is finalized")
    end

    # THE CONSTANT ITSELF, pinned as its own subject rather than left to the behaviour above.
    #
    # This became worth guarding the day `spec_observations.intent_layer` shipped (SPGD-851). Before
    # that the layer was nowhere in storage, so folding it into the identity text was not a change
    # anyone could make casually; now the column exists, sits beside the three fields this list
    # names, and reads like the obvious fourth member of an incomplete set. It is not one.
    #
    # Adding `"layer"` here would put the SAME TOKEN in the text of every unit test in the suite —
    # silently re-pointing the embeddings that back duplicate detection at a field that classifies
    # tests instead of describing them, and corrupting semantic identity for every annotated example
    # already stored. The text assertion above would catch it, but only while someone reads it as
    # being about the constant; this says so directly.
    # @intent: { entity: "Ingest::SpecSignal", action: "declare the intent parts constant", behavior: "INTENT_PARTS is exactly entity, action and behavior, guarding against a fourth identifying field being added beside the storage column", layer: "unit" }
    it "represents a test by entity, action and behavior — and by nothing else" do
      expect(Ingest::SpecSignal::INTENT_PARTS).to eq(%w[entity action behavior])
    end
  end

  describe "an unannotated spec carrying a name" do
    subject(:signal) { described_class.for(spec("name" => "User is valid with a handle")) }

    # @intent: { entity: "Ingest::SpecSignal", action: "build text from a client name", behavior: "an unannotated spec is represented by the name string the client sent, unchanged", layer: "unit" }
    it "represents the test by the name the client sent" do
      expect(signal.text).to eq("User is valid with a handle")
    end

    # @intent: { entity: "Ingest::SpecSignal", action: "report name as the source", behavior: "a name-derived signal is flagged as an inference with source :name and from_intent false", layer: "unit" }
    it "reports the name as the source, so a consumer knows it holds an inference" do
      expect(signal).to have_attributes(source: :name, present?: true,
                                        from_intent?: false, from_name?: true)
    end
  end

  describe "a spec carrying neither an intent nor a name" do
    subject(:signal) { described_class.for(spec) }

    # @intent: { entity: "Ingest::SpecSignal", action: "answer absent signals", behavior: "a spec with neither intent nor name yields nil text and source :none rather than an empty string", layer: "unit" }
    it "answers an explicit nothing rather than an empty string" do
      expect(signal).to have_attributes(text: nil, source: :none, present?: false,
                                        from_intent?: false, from_name?: false)
    end

    # @intent: { entity: "Ingest::SpecSignal", action: "treat blank names as absent", behavior: "a whitespace-only name answers exactly like a missing one, nil text and source :none", layer: "unit" }
    it "answers the same for a blank name as for an absent one" do
      expect(described_class.for(spec("name" => "   "))).to have_attributes(text: nil, source: :none)
    end

    # Not a second opinion on validity — the schema already requires all three parts. This is what
    # keeps a half-built triple from becoming the text `"Invoice finalize "` on any path that
    # reaches this class without the envelope's validation, e.g. a row read back out of storage.
    # @intent: { entity: "Ingest::SpecSignal", action: "reject a partial intent", behavior: "an intent missing any of the three parts degrades to :none instead of assembling a truncated triple on paths that skip envelope validation", layer: "unit" }
    it "does not assemble a triple out of a partial intent" do
      partial = spec("status" => "annotated", "intent" => { "entity" => "Invoice", "layer" => "unit" })

      expect(described_class.for(partial)).to have_attributes(text: nil, source: :none)
    end
  end

  # The precedence, asserted rather than left to fall out of the order of two `||`s: an annotated
  # example off the shipped formatter carries BOTH fields, so this is the ordinary case, not an
  # exotic one. Preferring the name would make annotating a test change nothing about how it is
  # represented — which would make the whole annotation protocol a no-op for this consumer.
  describe "a spec carrying both an intent and a name" do
    subject(:signal) do
      described_class.for(spec("status" => "annotated", "intent" => intent,
                               "name" => "Invoice#finalize locks the line items"))
    end

    # @intent: { entity: "Ingest::SpecSignal", action: "prefer intent over name", behavior: "when both fields are present the text comes from the intent, so annotating a test changes how it is represented", layer: "unit" }
    it "resolves to the intent, because a declaration outranks prose written for a human reader" do
      expect(signal.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
      expect(signal.text).not_to eq("Invoice#finalize locks the line items")
    end

    # @intent: { entity: "Ingest::SpecSignal", action: "report the winning source", behavior: "the source of a dual-field spec is :intent, naming which representation the consumer holds", layer: "unit" }
    it "reports the source it actually used" do
      expect(signal.source).to eq(:intent)
    end

    # The fallback is on the *text*, not on the annotation status: a spec whose intent supplies no
    # usable triple still has a name, and answering `:none` there would discard it.
    # @intent: { entity: "Ingest::SpecSignal", action: "fall back to the name", behavior: "an unusable intent does not discard the name: the text falls back to it with source :name", layer: "unit" }
    it "falls back to the name when the intent supplies no triple" do
      annotated = spec("status" => "annotated", "intent" => { "layer" => "unit" },
                       "name" => "Invoice#finalize locks the line items")

      expect(described_class.for(annotated))
        .to have_attributes(text: "Invoice#finalize locks the line items", source: :name)
    end
  end

  describe "an input this class was not given a spec for" do
    # @intent: { entity: "Ingest::SpecSignal", action: "answer non-spec inputs", behavior: "nil, strings, integers and arrays all answer nil text and :none rather than raising", layer: "unit" }
    it "answers the nothing case rather than raising" do
      [nil, "a string", 42, []].each do |input|
        expect(described_class.for(input)).to have_attributes(text: nil, source: :none),
                                              "expected #{input.inspect} to answer :none"
      end
    end
  end

  # @intent: { entity: "Ingest::SpecSignal", action: "trim text from either source", behavior: "surrounding whitespace on a name or an intent part is stripped before the text is assembled", layer: "unit" }
  it "trims the text it returns from either source" do
    expect(described_class.for(spec("name" => "  padded name  ")).text).to eq("padded name")
    expect(described_class.for(spec("status" => "annotated", "intent" => intent("entity" => " Invoice "))).text)
      .to eq("Invoice finalize locks the line items once the invoice is finalized")
  end

  # @intent: { entity: "Ingest::SpecSignal", action: "enumerate the sources", behavior: "SOURCES is exactly intent, name and none, letting consumers exhaust the representation cases", layer: "unit" }
  it "names every source it can report, so a consumer can exhaust the cases" do
    expect(described_class::SOURCES).to eq(%i[intent name none])
  end
end
