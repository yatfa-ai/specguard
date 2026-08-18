# frozen_string_literal: true

# Serves the OpenTestIntent v1 schema for download over plain, unauthenticated HTTP.
#
# This is a CONVENIENCE MIRROR, not a second source of truth. The canonical document — and the
# address the schema's own `$id` names — lives in the vendor-neutral `open-test-intent` repository,
# pinned to its immutable `schema-v1` tag. What this endpoint adds is that a reader of SpecGuard's
# own documentation can fetch the contract from the domain they are already on.
#
# It serves `OpenTestIntent.raw_document`, the vendored file's bytes verbatim, so "byte-identical to
# the canonical document" is a property of the response and not merely of the file on disk.
# `spec/services/open_test_intent_spec.rb` pins those bytes to the upstream blob hash, so a copy
# that drifted from its publisher fails the suite before it could ever be served from here.
#
# `ActionController::API`, not `ApplicationController`, on purpose. There is nothing to
# authenticate, no session to touch, no CSRF token to check and no browser to gate: this answers a
# `curl` from someone with no account, which is the entire point of it existing.
class SchemasController < ActionController::API
  def open_test_intent_v1
    # `application/schema+json` is the media type draft-07 registers for a JSON Schema document
    # (§11), and it carries the `+json` structured-syntax suffix, so a client dispatching on "is
    # this JSON" still sees JSON. `render plain:` with an explicit content type sends the string
    # through untouched — `render json:` would re-encode the parsed document and lose the byte
    # equality this mirror promises.
    render plain: OpenTestIntent.raw_document, content_type: "application/schema+json"
  end
end
