# frozen_string_literal: true

# THE ONE `@intent` FIELD THE PLATFORM REQUIRED, VALIDATED, AND THEN THREW AWAY.
#
# `layer` is not an optional extra the client may or may not send. `vendor/schemas/open-test-intent.v1.json`
# lists it in `required` alongside `entity`/`action`/`behavior` and constrains it to a four-token
# enum, and `Ingest::Payload#validate_intent` runs every annotated spec through that schema and
# **rejects the whole run with a 400** when the layer is missing or outside the enum. So the field
# was mandatory at the door and absent from storage: the platform spent a validation pass proving
# each annotated example declared its layer, wrote the other three fields, and dropped this one.
#
# That is the inversion this column closes. Every value that lands here has already been checked
# against the enum by the envelope, which is why the column needs no check constraint of its own —
# the validation is not being relaxed, it is being made to leave a trace.
#
# ## Why this reverses `create_spec_identities`' deliberate exclusion, and why that is not a
# ## contradiction
#
# `db/migrate/20260811120000_create_spec_identities.rb` added the triple and said of this field:
#
#   > `layer` and `preconditions` are deliberately absent: `SpecSignal::INTENT_PARTS` is
#   > entity/action/behavior, because those say what the test is *about* while `layer` classifies it
#   > — and a column nothing reads is a column that will be read wrongly later.
#
# BOTH HALVES OF THAT OBJECTION STILL STAND, and this migration satisfies them rather than
# overruling them.
#
# The first half is about the IDENTITY TEXT, and it is untouched here. `Ingest::SpecSignal::INTENT_PARTS`
# remains `entity/action/behavior` and `SpecObservation#signal` still rebuilds only those three.
# Folding "unit" into the embedded sentence would have every unit test in the suite share a token
# and would corrupt semantic identity for every annotated example — the exact failure that comment
# names. This column is read by a surface, never by the signal.
#
# The second half — *"a column nothing reads is a column that will be read wrongly later"* — is a
# CONDITION, and it is why a reader ships in the same change: `RepositoryOverview#serialized_slowest_examples`
# serves `intent_layer` per example in `latest_run`, so the column has a caller from its first day
# rather than acquiring one later from someone guessing at its meaning.
#
# ## Nullable, for exactly the reason the other three are
#
# A spec is annotated or it is not, and an unannotated example — the majority of every suite
# mid-adoption, and all of one at zero annotations — declares no layer. `Ingest::Payload#validate_intent`
# goes further and *requires* `intent` to be absent when `status == "unannotated"`, so a null here
# is a faithful record of a test that made no claim, not a gap.
#
# NULL ALSO MEANS "INGESTED BEFORE THIS SHIPPED", and there is deliberately no backfill. Historical
# rows have no layer and cannot be given one: the payloads that carried it are gone, and the only
# thing available to invent from is the file's directory — a GUESS. Writing a guess into this
# column would destroy the single distinction that makes it worth storing (see below), so every
# surface must read a null as "not declared, or not recorded" and never as a layer.
#
# ## `intent_layer`, not `layer`
#
# Named for the `intent_*` prefix its three siblings carry, and to keep it visibly distinct from any
# *derived* reading. This column holds the value the annotation **declared** — the author's own
# statement of what the test is — and its whole point is that it survives disagreeing with where the
# file sits. A `layer: "request"` example living under `spec/models/` stores `"request"`. A column
# that mixed a declaration and a directory guess could answer neither question, so anything derived
# belongs in its own column under its own name.
class AddIntentLayerToSpecObservations < ActiveRecord::Migration[8.1]
  def change
    add_column :spec_observations, :intent_layer, :string
  end
end
