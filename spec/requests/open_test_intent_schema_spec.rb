# frozen_string_literal: true

require "rails_helper"

# The mirror's contract is narrow and entirely about the RESPONSE: anyone, with no credentials, can
# fetch the schema from the platform's own domain, and what comes back is the canonical document
# rather than a re-rendering of it. Each example below pins one half of that.
RSpec.describe "GET /schemas/open-test-intent.v1.json", type: :request do
  let(:canonical_bytes) { Rails.root.join("vendor/schemas/open-test-intent.v1.json").binread }

  # @intent: {"entity": "GET /schemas/open-test-intent.v1.json", "action": "serve without credentials", "behavior": "a GET with no credentials returns HTTP 200 ok from the platform's own domain", "layer": "request"}
  it "answers an unauthenticated request" do
    get "/schemas/open-test-intent.v1.json"

    expect(response).to have_http_status(:ok)
  end

  # Byte equality, not JSON equality. `expect(JSON.parse(body)).to eq(JSON.parse(file))` would pass
  # for a response that had been through an encoder and come out with reordered keys and different
  # whitespace — which is exactly the failure this endpoint must not have, since a consumer
  # comparing the mirror's digest against the canonical one would then see two different documents
  # carrying the same constraints.
  # @intent: {"entity": "GET /schemas/open-test-intent.v1.json", "action": "mirror vendored schema bytes", "behavior": "the response body equals the vendored open-test-intent.v1.json file exactly, with matching SHA-256 digests rather than merely equal parsed JSON", "layer": "request"}
  it "returns the vendored schema byte-for-byte" do
    get "/schemas/open-test-intent.v1.json"

    expect(response.body).to eq(canonical_bytes)
    expect(Digest::SHA256.hexdigest(response.body))
      .to eq(Digest::SHA256.hexdigest(canonical_bytes))
  end

  # @intent: {"entity": "GET /schemas/open-test-intent.v1.json", "action": "declare media type", "behavior": "the response is served with media type application/schema+json", "layer": "request"}
  it "serves it as JSON" do
    get "/schemas/open-test-intent.v1.json"

    expect(response.media_type).to eq("application/schema+json")
  end

  # The mirror exists to make the identifier fetchable, so the identifier had better be in what it
  # serves — and it had better be the one that resolves. A mirror serving a document that named the
  # old dead host would be a working endpoint publishing a broken contract. Pinned by equality
  # rather than by a `not_to include` of the dead host: equality rejects that string too, and every
  # other wrong one, which a negative assertion naming one known-bad value does not.
  # @intent: {"entity": "GET /schemas/open-test-intent.v1.json", "action": "carry canonical identifier", "behavior": "the parsed document's $id equals https://raw.githubusercontent.com/yatfa-ai/open-test-intent/schema-v1.0/schemas/open-test-intent.v1.json", "layer": "request"}
  it "carries the canonical identifier, which names the protocol repository" do
    get "/schemas/open-test-intent.v1.json"

    expect(JSON.parse(response.body)["$id"])
      .to eq("https://raw.githubusercontent.com/yatfa-ai/open-test-intent/schema-v1.0/schemas/open-test-intent.v1.json")
  end

  # `format: false` on the route. Without it Rails' optional `(.:format)` segment answers here too,
  # so the schema would be reachable at an address whose name does not say which version it
  # returns — and a v2 could not later claim that address without silently changing what a pinned
  # URL hands back. The full path is fetched first in this same example so the 404 below is read as
  # "this address is not served" rather than "the app is not serving anything".
  # @intent: {"entity": "GET /schemas/open-test-intent.v1.json", "action": "refuse extension-less path", "behavior": "the full .json path answers 200 while GET /schemas/open-test-intent.v1 returns 404, so only the versioned address is served", "layer": "request"}
  it "does not answer at the same path with the .json extension dropped" do
    get "/schemas/open-test-intent.v1.json"
    expect(response).to have_http_status(:ok)

    get "/schemas/open-test-intent.v1"

    expect(response).to have_http_status(:not_found)
  end
end
