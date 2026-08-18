# frozen_string_literal: true

require "rails_helper"

# THE CORPUS IS THE SUBJECT OF THIS FILE, and it is shared with `spec_observation_spec.rb`'s
# agreement example rather than written twice.
#
# {DerivedIntent} exists in two engines — this class, and the Postgres regex
# `SpecObservation::READING_EXPRESSION` interpolates — because the same rule has to answer for ONE
# row a surface is rendering and for TENS OF THOUSANDS a panel is counting. Two engines is a
# drift risk, and the drift would be silent: a panel counting a row as derived that this class
# returns nothing for renders an empty cell under a caption that says SpecGuard read it.
#
# So the corpus lives in {DerivedIntentCorpus}, this file runs the Ruby matcher over it, and
# `spec/models/spec_observation_spec.rb` runs the SQL predicate over the SAME strings and asserts
# the two verdicts are equal string for string. Adding a case here extends both.
RSpec.describe DerivedIntent do
  # Descriptions that YIELD a reading, with what they must yield.
  #
  # Every one of these is a real RSpec `full_description` shape: `RSpec.describe SomeClass do
  # describe "#method" do it "…" end end` produces `SomeClass#method …`, with no separator before
  # the sigil and one space after the method name.
  describe ".from — the descriptions that yield a reading" do
    DerivedIntentCorpus::DERIVABLE.each do |name, expected|
      it "reads #{name.inspect}" do
        derived = described_class.from(name, spec_file_path: "spec/models/thing_spec.rb")

        expect(derived).not_to be_nil
        expect([derived.entity, derived.action, derived.behavior])
          .to eq([expected[:entity], expected[:action], expected[:behavior]])
      end
    end

    # ⭐ THE CONTRACT THE TICKET STATES AS A RULE: a derived reading that would not satisfy the
    # open-test-intent schema is not a derived reading, it is absence. {DerivedIntent::PATTERN} is
    # built to guarantee this — the entity and action minimums and the behavior's 15 characters are
    # encoded in the regex — and the guarantee is worth exactly as much as the last edit to those
    # constants, so it is asserted rather than argued.
    it "returns nothing that the OpenTestIntent schema would reject" do
      readings = DerivedIntentCorpus::DERIVABLE.keys.filter_map do |name|
        described_class.from(name, spec_file_path: "spec/models/thing_spec.rb")
      end

      expect(readings.length).to eq(DerivedIntentCorpus::DERIVABLE.size)
      readings.each { |reading| expect(OpenTestIntent.validation_errors(reading.to_intent)).to be_empty }
    end

    # The sigil is CONSUMED, not carried into the action, and the two spellings collapse onto one
    # value. An author writing this annotation by hand writes `action: call`, and a derived action of
    # `#call` would be incomparable with it on the one field the two most obviously line up on.
    it "spells an instance method's action the way an author would, and identically to a class one" do
      instance = described_class.from("Invoice#finalize locks the line items")
      singleton = described_class.from("Invoice.finalize locks the line items")

      expect(instance.action).to eq("finalize")
      expect(singleton.action).to eq("finalize")
    end
  end

  describe ".from — the descriptions that yield nothing" do
    DerivedIntentCorpus::UNREADABLE.each do |name, why|
      it "reads nothing from #{name.inspect} — #{why}" do
        expect(described_class.from(name, spec_file_path: "spec/models/thing_spec.rb")).to be_nil
      end
    end

    # A nil `name` is an ordinary row rather than an error: the column is nullable, because
    # `Ingest::ObservationRecorder#attributes` writes it through `presence_of` and a producer that
    # sent nothing stores a NULL.
    it "reads nothing from a row that carries no description at all" do
      expect(described_class.from(nil)).to be_nil
      expect(described_class.from("")).to be_nil
      expect(described_class.from("   ")).to be_nil
    end

    # ⭐ THE REFUSAL THE CLASS ARGUES FOR AT LENGTH, pinned so it cannot be "fixed" into a guess.
    # `Checkout rejects an expired card` has an entity and a behavior and no action between them, and
    # the tempting repair — take the behavior's first word — reads `when` as an action on the very
    # common `Checkout when the card is expired returns 402`. A wrong action is worse than no
    # reading: it is a claim, made by the platform, in a field an author is supposed to own.
    it "refuses an entity-and-behavior description rather than inventing an action for it" do
      expect(described_class.from("Checkout rejects an expired card")).to be_nil
      expect(described_class.from("Checkout when the card is expired returns 402 payment required"))
        .to be_nil
    end
  end

  # `layer` is the one field of a derived reading that comes from somewhere other than the
  # description, and it is a CONVENTION GUESS. It is derived at all so the reading satisfies the
  # schema, which requires it — and it is named in the class comment as part of what an authored
  # `@intent` still buys, precisely because a request spec parked under `spec/models/` reads `unit`
  # here and would read `request` from its author.
  describe "#layer" do
    {
      "spec/models/invoice_spec.rb" => "unit",
      "spec/services/pricing_spec.rb" => "unit",
      "spec/requests/api/v1/ingest_spec.rb" => "request",
      "spec/integration/checkout_spec.rb" => "integration",
      "spec/system/dashboard_spec.rb" => "system",
      # RSpec renamed feature specs to system specs; a suite predating the rename is the same layer
      # under an older word, and the schema has no word for `feature`.
      "spec/features/signup_spec.rb" => "system",
      # No path at all — the row's `spec_file_path` is nullable by schema. The default, not a nil.
      nil => "unit"
    }.each do |path, layer|
      it "reads #{layer.inspect} from #{path.inspect}" do
        expect(described_class.from("Invoice#finalize locks the line items", spec_file_path: path).layer)
          .to eq(layer)
      end
    end

    # The FIRST recognised segment wins, scanned from the root, because the outer directory is the
    # one a suite organises by.
    it "takes the outermost recognised segment when a path carries two" do
      derived = described_class.from("Invoice#finalize locks the line items",
                                     spec_file_path: "spec/system/admin/requests/billing_spec.rb")

      expect(derived.layer).to eq("system")
    end
  end

  describe "#to_intent" do
    # No `preconditions` key. A derived reading has none, and an empty array would claim the test
    # declares no preconditions — a different statement from "nobody said".
    it "is the four fields an author would have written, and never an empty preconditions array" do
      derived = described_class.from("Invoice#finalize locks the line items",
                                     spec_file_path: "spec/models/invoice_spec.rb")

      expect(derived.to_intent).to eq("entity" => "Invoice", "action" => "finalize",
                                      "behavior" => "locks the line items", "layer" => "unit")
      expect(derived.to_intent).not_to have_key("preconditions")
    end
  end
end
