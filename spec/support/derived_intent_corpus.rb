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
#
# == ⭐ WHAT THIS CORPUS CERTIFIES, AND WHAT IT DOES NOT — stated, because the last version did not
#
# It certifies that the two engines give the SAME verdict on every string below, and that the
# verdict is the one named below. It does NOT certify anything about a shape absent from this list,
# and the gap is not hypothetical: every string in the first version of this corpus was ASCII with
# clean bookends, so it exercised `DerivedIntent::PATTERN`'s body thoroughly and never once asked
# what the two engines did with WHITESPACE. They did different things. `String#strip` and Postgres
# `btrim/2` disagree about a tab and a newline, and Ruby's `[[:space:]]` and Postgres's disagree
# about U+00A0 — so a description ending in a newline was `derived` in Ruby and `unreadable` in SQL,
# in exactly the shape this file's agreement example was written to catch, while the example passed.
#
# The whitespace cases at the foot of each list below are that hole closed. They look pedantic and
# they are the only reason the guarantee in `DerivedIntent`'s class comment is a tested claim rather
# than a hopeful one — so a padded case is never redundant with the tidy case it resembles, and none
# of them may be dropped for looking like one.
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
    },
    # == THE WHITESPACE CASES — the ones the first corpus lacked, and the drift they let through
    #
    # Verdicts under the OLD engines (`.strip` + `btrim` + `[[:space:]]`), measured rather than
    # reasoned about, because the two are not the same exercise:
    #
    # | description                | old Ruby   | old SQL    |            |
    # |----------------------------|------------|------------|------------|
    # | trailing SPACE             | derived    | derived    | agreed     |
    # | trailing TAB               | derived    | unreadable | DIVERGED   |
    # | leading NEWLINE            | derived    | unreadable | DIVERGED   |
    # | VERTICAL TAB both ends     | derived    | unreadable | DIVERGED   |
    # | trailing U+00A0            | unreadable | derived    | DIVERGED   |
    #
    # Four of the five split the two engines, in BOTH directions, and the fifth is here for the
    # opposite reason — see its own note. They are here so that a future edit reintroducing a
    # normalisation step in one engine, or reaching for the POSIX class again, goes red rather than
    # shipping.
    #
    # A trailing SPACE, which is the one padding character the two old engines DID agree about —
    # `btrim` takes a space and so does `.strip`. It is kept precisely because it never diverged: it
    # is the regression pin that removing both trims did not change the answer on the case that was
    # already right, which is the half of a repair that is easy to leave untested.
    "Invoice#finalize locks the line items once finalized " => {
      entity: "Invoice", action: "finalize", behavior: "locks the line items once finalized"
    },
    # A trailing TAB and a leading NEWLINE — `.strip` takes both and `btrim/2` takes neither, so
    # Ruby read them and SQL did not. The behavior comes out identical to the space-padded case
    # above, which is the whole point: padding may not change what is read.
    "Invoice#finalize locks the line items once finalized\t" => {
      entity: "Invoice", action: "finalize", behavior: "locks the line items once finalized"
    },
    "\nInvoice#finalize locks the line items once finalized" => {
      entity: "Invoice", action: "finalize", behavior: "locks the line items once finalized"
    },
    # A VERTICAL TAB, the member of `DerivedIntent::WHITESPACE` most easily got wrong: Postgres's
    # `E''` STRING escapes do not define `\v` — a `btrim(…, E'\v')` written to repair this would trim
    # the LETTER v — while its REGEX escapes do. Pinned so the set is exercised rather than trusted.
    "\vCart#total totals the cart\v" => {
      entity: "Cart", action: "total", behavior: "totals the cart"
    },
    # A NON-BREAKING SPACE at the end of the behavior, and the divergence that ran the other way:
    # Ruby's `[[:space:]]` calls U+00A0 space, so `BEHAVIOR`'s closing bookend refused it and the
    # row read as unreadable — while Postgres's `[[:space:]]` does not, so it read as derived. Under
    # the spelled ASCII class it is an ordinary character to both, and it stays IN the behavior
    # rather than being trimmed off the end of it.
    "Invoice#finalize locks the line items once finalized\u00A0" => {
      entity: "Invoice", action: "finalize", behavior: "locks the line items once finalized\u00A0"
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
    "Invoice#line#total sums one line of the invoice" => "two sigils and no whitespace between them",
    # == The whitespace cases that must yield NOTHING — the same hole, the other verdict
    #
    # A NON-BREAKING SPACE where the separator belongs. The call `DerivedIntent::WHITESPACE` makes
    # is that U+00A0 is an ordinary character, so it does not separate an action from a behavior —
    # and the point is that it is the SAME call in both engines, not that it is the only defensible
    # one. Under Ruby's Unicode `[[:space:]]` this derived; under Postgres's it did not.
    "Invoice#finalize\u00A0locks the line items once finalized" =>
      "a non-breaking space does not separate the action from the behavior",
    # Padding cannot RESCUE a description either: a behavior below the schema's fifteen characters
    # stays absence however much whitespace surrounds it. The padding is not part of the behavior's
    # length in either engine, which is the property `BEHAVIOR`'s bookends buy. Both old engines
    # agreed here too, and it is kept for the reason the space-padded case above is.
    "  Cart#total sums it   " => "padding does not lengthen a behavior below the schema's minimum",
    # Whitespace and nothing else — the degenerate padded row.
    "\t\n  " => "a description of nothing but whitespace"
  }.freeze
end
