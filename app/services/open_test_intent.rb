# frozen_string_literal: true

# The OpenTestIntent v1 contract — the protocol every `intent` on an ingested spec must satisfy.
#
# `SCHEMA_PATH` is a byte-identical vendored copy of the `open-test-intent` repo's
# `schemas/open-test-intent.v1.json` at commit c216ea2 (git blob
# 16996f20d23e6099b11472d48579ba640f090c23). It is pinned here rather than read across repos so
# ingestion is deterministic and deployable on its own; `spec/services/open_test_intent_spec.rb`
# re-derives the blob hash, so editing the copy fails the suite instead of silently forking the
# protocol from its publisher.
module OpenTestIntent
  SCHEMA_PATH = Rails.root.join("vendor/schemas/open-test-intent.v1.json")

  # `git hash-object vendor/schemas/open-test-intent.v1.json` at the pinned upstream commit.
  SCHEMA_BLOB_SHA = "16996f20d23e6099b11472d48579ba640f090c23"

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

    def schema
      @schema ||= JSONSchemer.schema(SCHEMA_PATH)
    end
  end
end
