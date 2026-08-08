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

    it "represents the test by the intent triple" do
      expect(signal.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
    end

    it "reports the intent as the source, so a consumer knows it holds a declared claim" do
      expect(signal).to have_attributes(source: :intent, present?: true,
                                        from_intent?: true, from_name?: false)
    end

    # `layer` classifies the test and `preconditions` qualify it; neither says what the test is
    # about, and folding "unit" in would put the same token in every unit test's text.
    it "leaves layer and preconditions out of the text" do
      annotated = spec("status" => "annotated",
                       "intent" => intent("layer" => "integration",
                                          "preconditions" => ["the invoice is open"]))

      expect(described_class.for(annotated).text)
        .to eq("Invoice finalize locks the line items once the invoice is finalized")
    end
  end

  describe "an unannotated spec carrying a name" do
    subject(:signal) { described_class.for(spec("name" => "User is valid with a handle")) }

    it "represents the test by the name the client sent" do
      expect(signal.text).to eq("User is valid with a handle")
    end

    it "reports the name as the source, so a consumer knows it holds an inference" do
      expect(signal).to have_attributes(source: :name, present?: true,
                                        from_intent?: false, from_name?: true)
    end
  end

  describe "a spec carrying neither an intent nor a name" do
    subject(:signal) { described_class.for(spec) }

    it "answers an explicit nothing rather than an empty string" do
      expect(signal).to have_attributes(text: nil, source: :none, present?: false,
                                        from_intent?: false, from_name?: false)
    end

    it "answers the same for a blank name as for an absent one" do
      expect(described_class.for(spec("name" => "   "))).to have_attributes(text: nil, source: :none)
    end

    # Not a second opinion on validity — the schema already requires all three parts. This is what
    # keeps a half-built triple from becoming the text `"Invoice finalize "` on any path that
    # reaches this class without the envelope's validation, e.g. a row read back out of storage.
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

    it "resolves to the intent, because a declaration outranks prose written for a human reader" do
      expect(signal.text).to eq("Invoice finalize locks the line items once the invoice is finalized")
      expect(signal.text).not_to eq("Invoice#finalize locks the line items")
    end

    it "reports the source it actually used" do
      expect(signal.source).to eq(:intent)
    end

    # The fallback is on the *text*, not on the annotation status: a spec whose intent supplies no
    # usable triple still has a name, and answering `:none` there would discard it.
    it "falls back to the name when the intent supplies no triple" do
      annotated = spec("status" => "annotated", "intent" => { "layer" => "unit" },
                       "name" => "Invoice#finalize locks the line items")

      expect(described_class.for(annotated))
        .to have_attributes(text: "Invoice#finalize locks the line items", source: :name)
    end
  end

  describe "an input this class was not given a spec for" do
    it "answers the nothing case rather than raising" do
      [nil, "a string", 42, []].each do |input|
        expect(described_class.for(input)).to have_attributes(text: nil, source: :none),
                                              "expected #{input.inspect} to answer :none"
      end
    end
  end

  it "trims the text it returns from either source" do
    expect(described_class.for(spec("name" => "  padded name  ")).text).to eq("padded name")
    expect(described_class.for(spec("status" => "annotated", "intent" => intent("entity" => " Invoice "))).text)
      .to eq("Invoice finalize locks the line items once the invoice is finalized")
  end

  it "names every source it can report, so a consumer can exhaust the cases" do
    expect(described_class::SOURCES).to eq(%i[intent name none])
  end
end
