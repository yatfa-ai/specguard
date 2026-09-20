# frozen_string_literal: true

require "digest"

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

    # The SHA-256 of the bytes this process actually validates against, hex-encoded and lowercase
    # — the digest the rest of the family compares with, pinned independently in three sibling
    # repos (`open-test-intent`'s `CanonicalV1SHA256`, `specguard-rspec`'s `CANONICAL_V1_SHA256`,
    # `specguard-ts`'s `SCHEMA_CONTRACT_DIGEST`). It is deliberately a DIFFERENT algorithm from
    # `SCHEMA_BLOB_SHA` above, and both are kept: the blob SHA-1 is the in-repo guard against the
    # file's *git* identity drifting from its publisher, while this one is the cross-repo one —
    # a git blob hash is comparable with none of those three constants, so serving it would state
    # an identity nobody else can check. Mirrors what `open-test-intent`'s `SHA256Hex` documents
    # about having ONE fold: those digests are COMPARED, so a difference must mean the schemas
    # differ and never that the arithmetic does.
    #
    # Folded over `raw_document` rather than re-reading the file, for that same reason and for the
    # `--schema-source` one: a function that re-read the path could digest something other than
    # the bytes the validator loaded. It costs no new disk read (`raw_document` is already read
    # once per process and frozen) and does not mutate or re-serialize it, so `SchemasController`'s
    # byte-identical mirror is untouched. Memoized per process on the same terms as the read
    # itself: the file cannot change without a deploy, and a deploy is a process restart.
    def schema_sha256 = @schema_sha256 ||= Digest::SHA256.hexdigest(raw_document).freeze

    def schema
      @schema ||= JSONSchemer.schema(SCHEMA_PATH)
    end
  end
end
