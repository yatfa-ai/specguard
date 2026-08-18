# frozen_string_literal: true

# ONE corpus of test descriptions, and the verdict each must get — shared by the two files that run
# the two engines of `DerivedIntent`'s rule.
#
# `spec/services/derived_intent_spec.rb` runs the Ruby matcher over these strings.
# `spec/models/spec_observation_spec.rb` stores them as rows and runs
# `SpecObservation::READING_EXPRESSION` — the Postgres regex — over the same strings, and asserts the
# two verdicts agree row for row.
#
# HERE RATHER THAN IN EITHER FILE, on the reasoning `ObservationGrainReads` gives for the same shape:
# RSpec scopes a constant defined inside an example group to that group, so a sibling's corpus is
# invisible and the only way to reuse it is to copy it. Two copies of a corpus are two lists free to
# drift on which descriptions they cover, and the whole point of the agreement example is that the
# two engines are asked THE SAME QUESTION. A corpus that had drifted would still report a pass.
#
# So: adding a case here extends both files at once, and that is the property to preserve. A case
# that belongs to only one engine belongs in that engine's file, not here.
module DerivedIntentCorpus
  # Descriptions that MUST yield a reading, and what they must yield.
  #
  # Every key is a real RSpec `full_description`: `RSpec.describe SomeClass do describe "#method" do
  # it "…" end end` renders as `SomeClass#method …`, no separator before the sigil, one space after.
  DERIVABLE = {
    # The ticket's own example, verbatim — the test SpecGuard was reporting as one it could not see
    # while holding its entity, its action and its behavior.
    "McpHandlers::AcceptFeatureCheckDebtHandler#call clearing revokes an existing acceptance" => {
      entity: "McpHandlers::AcceptFeatureCheckDebtHandler", action: "call",
      behavior: "clearing revokes an existing acceptance"
    },
    "Invoice#finalize locks the line items once the invoice is finalized" => {
      entity: "Invoice", action: "finalize",
      behavior: "locks the line items once the invoice is finalized"
    },
    # A singleton method, and the sigil is consumed rather than carried into the action.
    "User.find_by_handle returns nil when no user matches" => {
      entity: "User", action: "find_by_handle", behavior: "returns nil when no user matches"
    },
    # A predicate method — the trailing `?` belongs to the method name.
    "Repository#public? is false for a private repository" => {
      entity: "Repository", action: "public?", behavior: "is false for a private repository"
    },
    # A writer — the trailing `=` likewise.
    "Account#balance= rejects a negative amount outright" => {
      entity: "Account", action: "balance=", behavior: "rejects a negative amount outright"
    },
    # A bang method.
    "Order#settle! raises when the balance is already settled" => {
      entity: "Order", action: "settle!", behavior: "raises when the balance is already settled"
    },
    # Nested `describe`/`context` strings concatenate into the behavior, which is the ordinary shape
    # of any suite that uses `context`. The whole remainder is the behavior; nothing is dropped.
    "Payment#capture when the gateway times out retries once and then gives up" => {
      entity: "Payment", action: "capture",
      behavior: "when the gateway times out retries once and then gives up"
    },
    # A deeply namespaced constant — the `::` segments are part of the entity.
    "Ingest::RunRecorder::Shard#upsert replaces a redelivered shard in place" => {
      entity: "Ingest::RunRecorder::Shard", action: "upsert",
      behavior: "replaces a redelivered shard in place"
    },
    # A behavior of EXACTLY fifteen characters, the schema's `minLength`. The boundary is in the
    # corpus rather than in a comment, because it is the boundary both engines have to agree on.
    "Cart#total totals the cart" => {
      entity: "Cart", action: "total", behavior: "totals the cart"
    }
  }.freeze

  # Descriptions that MUST yield nothing, each with the reason it is here. These are the population
  # any "SpecGuard cannot see this test" language may describe.
  UNREADABLE = {
    # No action between the entity and the behavior. The refusal `DerivedIntent` argues for at
    # length: guessing one would read `when` as an action on half a suite.
    "Checkout rejects an expired card" => "an entity and a behavior with no action between them",
    "Checkout when the card is expired returns 402" => "the same shape with a context clause",
    # No entity token at all — the ordinary request-spec description.
    "POST /api/v1/ingest rejects a malformed body" => "no entity token",
    "the widget behaves itself under load" => "no entity and no action",
    # An entity and an action, and a behavior below the schema's fifteen characters. Absence, by the
    # ticket's own rule: a reading the schema would reject is not a reading.
    "Cart#total sums it" => "the behavior is shorter than the schema allows",
    # An entity and an action and NO behavior.
    "Invoice#finalize" => "no behavior at all",
    # Lowercase leading token — not a constant, so not an entity.
    "invoice#finalize locks the line items once finalized" => "the entity is not a constant",
    # A single-character method name, which the pattern requires two of. Stated as a case rather
    # than left to be discovered: it is a deliberate narrowing, not an oversight.
    "Matrix#t transposes the matrix in place" => "the method name is one character",
    # An operator method. Deliberately not matched — a pattern permissive enough for `[]` and `<=>`
    # costs the whole rule its precision.
    "Matrix#<=> orders two matrices by determinant" => "an operator method is not matched",
    # A second sigil before any whitespace. Rare, and refused rather than guessed at.
    "Invoice#line#total sums one line of the invoice" => "two sigils and no whitespace between them"
  }.freeze
end
