# frozen_string_literal: true

# The OpenTestIntent v1 contract — the protocol every `intent` on an ingested spec must satisfy.
#
# `SCHEMA_PATH` is a byte-identical vendored copy of the `open-test-intent` repo's
# `schemas/open-test-intent.v1.json` at the `schema-v1.0` tag (git blob
# e8224eccc773bb8a3eb1e277d99fd339fac85168) — the same bytes the schema's own `$id` resolves to.
# That tag is scoped to a document REVISION, not to the major version: PROTOCOL.md §5 lets v1 gain
# an optional field, and §3 explains why a `schema-v1` tag would then have had to either move or
# stop matching the file naming it. Re-vendoring after such a change means taking the next tag.
# It is pinned here rather than read across repos so ingestion is deterministic and deployable on
# its own; `spec/services/open_test_intent_spec.rb` re-derives the blob hash, so editing the copy
# fails the suite instead of silently forking the protocol from its publisher.
module OpenTestIntent
  SCHEMA_PATH = Rails.root.join("vendor/schemas/open-test-intent.v1.json")

  # `git hash-object vendor/schemas/open-test-intent.v1.json` at the pinned upstream commit.
  SCHEMA_BLOB_SHA = "e8224eccc773bb8a3eb1e277d99fd339fac85168"

  class << self
    # Every way `intent` fails the contract, as messages fit to hand back to a client. Empty means
    # valid. All failures are collected: a client fixing an annotation should see the whole list,
    # not the first problem only.
    def validation_errors(intent)
      return ["must be a JSON object"] unless intent.is_a?(Hash)

      # json_schemer's own `error` string already names the offending member by JSON pointer
      # (e.g. "string length at `/behavior` is less than: 15"), which is what a client needs.
      schema.validate(intent).map { |error| error["error"].to_s }
    end

    def valid?(intent) = validation_errors(intent).empty?

    # The vendored bytes, verbatim and unparsed — what `SchemasController` serves as the
    # downloadable mirror. Deliberately NOT `schema.to_json` or a re-serialization of the parsed
    # document: a round trip through a JSON encoder would reorder keys and drop the file's
    # whitespace, and the mirror's whole claim is that it is byte-identical to the canonical
    # document. Read once and frozen, since the file cannot change without a deploy.
    def raw_document = @raw_document ||= SCHEMA_PATH.binread.freeze

    def schema
      @schema ||= JSONSchemer.schema(SCHEMA_PATH)
    end
  end
end
