# frozen_string_literal: true

module Ingest
  # What text represents one test, and where that text came from.
  #
  # Every consumer that wants to *say something about* a test rather than merely count it —
  # duplicate detection, the embedding seam, any future search — needs one string standing for the
  # test. Two fields on the wire can supply it, and they are not equally good, so the decision is
  # made once here rather than re-made at each consumer with a slightly different rule.
  #
  # == The three cases
  #
  # * **Annotated** — the intent triple, `"{entity} {action} {behavior}"`. Source `:intent`.
  # * **Unannotated, named** — the example's `name`, which is RSpec's `full_description`. Source
  #   `:name`.
  # * **Neither** — no text at all. Source `:none`, {#text} is nil, {#present?} is false.
  #
  # The intent wins when a spec carries both, which is every annotated example the shipped
  # formatter produces (it sends `name` for all nine-field payloads). An intent is a *declared*
  # statement of what the test is for; a name is prose someone wrote for a human reading test
  # output. When the declaration exists it is the better answer, and preferring the name would make
  # annotating a test change nothing.
  #
  # == Why the source travels with the text
  #
  # Because they are not the same evidence. `"User is valid with a handle"` inferred from a test's
  # name is a guess about intent; `"User validate rejects a blank handle"` assembled from a
  # declared intent is the author's own claim. A consumer that treats both alike would report a
  # name-derived match with the same confidence as an intent-derived one, and nothing downstream
  # could tell the two apart afterwards. So {#source} is returned *with* {#text}, always, and a
  # consumer can say which it is holding.
  #
  # == The `:none` case, and why it survives envelope validation rejecting it
  #
  # `Ingest::Payload#validate_name` refuses a spec carrying neither an intent nor a name, so no
  # accepted payload reaches this class in the `:none` state today. It is still modelled, for two
  # reasons: this class also answers for specs read back out of storage, where `name` is nullable
  # (`spec_observations.name`) and rows predating that validator exist; and an "I have nothing"
  # answer is what keeps a consumer from having to guess whether an empty string means "no text"
  # or "the text is empty".
  #
  # == Shape
  #
  #   signal = Ingest::SpecSignal.for(spec)
  #   signal.text       # => "Invoice finalize locks the line items once the invoice is finalized"
  #   signal.source     # => :intent
  #   signal.present?   # => true
  #
  # `spec` is a spec hash as `Ingest::Payload` holds it — **string keys**, straight off the JSON
  # wire, not symbolized and not validated by this class. A non-Hash, a nil, or a hash missing
  # every field all answer the `:none` case rather than raising: this object reports what it can
  # find, and rejecting a malformed spec is the envelope's job (`Ingest::Payload`).
  class SpecSignal
    # The order is the precedence: the first source that yields text wins.
    SOURCES = %i[intent name none].freeze

    # The intent fields joined into the sentence a triple makes, in this order. `layer` and
    # `preconditions` are deliberately absent — they classify and qualify the test rather than say
    # what it is about, and folding "unit" into the text would have every unit test share a token.
    INTENT_PARTS = %w[entity action behavior].freeze

    def self.for(spec) = new(spec)

    def initialize(spec)
      @spec = spec.is_a?(Hash) ? spec : {}
    end

    # @return [String, nil] the text representing this test, or nil when there is none.
    def text = signal.first

    # @return [Symbol] one of {SOURCES} — `:intent`, `:name`, or `:none`.
    def source = signal.last

    def present? = source != :none

    def from_intent? = source == :intent

    def from_name? = source == :name

    private

    # Resolved once and memoized as the pair, so {#text} and {#source} can never disagree about
    # which case this spec fell into.
    def signal = @signal ||= from_intent || from_name || [nil, :none]

    # An intent is used only when it supplies all three parts. A partial intent is a spec the
    # envelope rejects against the OpenTestIntent schema (all three are `required`), so this is not
    # a second opinion on validity — it is what keeps a half-built triple from becoming text like
    # `"Invoice finalize "` on any path that reaches this class without that validation.
    def from_intent
      intent = @spec["intent"]
      return nil unless intent.is_a?(Hash)

      parts = INTENT_PARTS.map { |part| intent[part] }
      return nil unless parts.all? { |part| part.is_a?(String) && part.strip.present? }

      [parts.map(&:strip).join(" "), :intent]
    end

    def from_name
      name = @spec["name"]
      return nil unless name.is_a?(String) && name.strip.present?

      [name.strip, :name]
    end
  end
end
