# frozen_string_literal: true

require "rails_helper"

# The server's identity read (SPGD-1197, extended by SPGD-1316). Its contract is narrow: anyone,
# with no credentials, can ask the server which build it is AND which OpenTestIntent contract it
# enforces, and the answers it gives are the VERSION file's own content and the vendored schema's
# own bytes — derived from those files at pin time, never hardcoded literals (a hardcoded literal
# would pass today and fail the day the release bot bumps, or the day the schema is re-vendored;
# SPGD-1188's found defect was exactly a claimed-but-false identity surviving healthy docs). Each
# example below pins one property of that.
RSpec.describe "GET /version", type: :request do
  let(:version_path) { Rails.root.join("VERSION") }
  let(:schema_path) { Rails.root.join("vendor/schemas/open-test-intent.v1.json") }

  # The expected value is DERIVED from the file the release bot bumps — the pin-that-would-have-
  # caught-the-drift pattern: when the bot bumps, this pin fails against a server still serving
  # the old answer, rather than two hardcoded strings agreeing with each other and with nothing.
  let(:file_version) { version_path.binread.strip }

  # The same pattern on the contract leg: the digest is folded HERE from the vendored file, so
  # re-vendoring a new schema revision without re-serving it turns this red — which a literal
  # pinned to today's value could never do, since it would be re-typed alongside the change.
  let(:file_schema_sha256) { Digest::SHA256.hexdigest(schema_path.binread) }

  # The whole body this route serves, derived the same way, so every whole-body pin below states
  # the shape once.
  let(:expected_body) do
    { "version" => file_version, "schema_sha256" => file_schema_sha256,
      "schema_origin" => "vendor/schemas/open-test-intent.v1.json" }
  end

  # The digest the REST OF THE FAMILY pins, introduced once, as a literal, on purpose. This is the
  # cross-repo drift signal: `open-test-intent/schema_test.go`'s `CanonicalV1SHA256`,
  # `specguard-rspec`'s `CANONICAL_V1_SHA256` and `specguard-ts`'s `SCHEMA_CONTRACT_DIGEST` all
  # hold this same string, and two of those pins disagreeing is how a drifted copy is found. The
  # DERIVED pin above stays the primary guard — this one answers the different question of whether
  # what we serve is still the contract the siblings target, which a file-derived value cannot ask
  # of itself.
  FAMILY_CANONICAL_V1_SHA256 = "3760d8f7c6694aa19ca53cd39c323d7c096ae1140be08c435cd433e77db618ee"

  # Clears the class-level memos so an example starts from a cold read. Every example that stubs or
  # counts the READ PATH (rather than the accessor) must clear first: a stubbed read poisons the
  # class memo with its answer — including a nil — and that memo would otherwise leak into later
  # examples riding `get "/version"`. Clearing first keeps every example order-independent.
  #
  # FOUR memos, not one, because the contract leg memoizes on both sides of the seam: the
  # controller remembers the answer it rendered, and `OpenTestIntent` remembers the bytes and the
  # fold. A `Pathname#binread` stub that did not clear the service memos would be ridden straight
  # past by a warm `raw_document` some earlier example had already read — the failing read would
  # never happen and the example would pass for the wrong reason, or fail depending on suite order.
  # Clearing them costs one re-read in a later example; the file cannot change under us.
  def clear_memo!
    VersionsController.remove_instance_variable(:@server_version) if
      VersionsController.instance_variable_defined?(:@server_version)
    VersionsController.remove_instance_variable(:@schema_sha256) if
      VersionsController.instance_variable_defined?(:@schema_sha256)
    OpenTestIntent.remove_instance_variable(:@schema_sha256) if
      OpenTestIntent.instance_variable_defined?(:@schema_sha256)
    OpenTestIntent.remove_instance_variable(:@raw_document) if
      OpenTestIntent.instance_variable_defined?(:@raw_document)
  end

  # Clearing on the way OUT as well as on the way in, because a poisoned memo outlives the stub
  # that produced it: RSpec removes the stub at the end of the example, but the nil (or the fake
  # digest) the stubbed read already wrote into a CLASS-level memo survives into every later
  # example in the process — including examples in OTHER FILES, since `Ingest::RejectionRecorder`
  # reads `VersionsController.server_version` too. This was a live order-dependency before the
  # contract leg existed: on `main`, seeds 222/3333/44444/7/99 all failed the VERSION body pin
  # here because the nil-memoization example ran before it (seed 11 passed — which is exactly how
  # a leak like this hides). A before-only `clear_memo!` cannot fix it, since the poisoning
  # happens DURING the example that clears. Placed as an `after` on the whole group rather than
  # on the stubbing examples alone: any example added later that stubs a read is covered without
  # anyone remembering to.
  after { clear_memo! }

  # @intent: {"entity": "GET /version", "action": "serve without credentials", "behavior": "a GET with no credentials returns HTTP 200 ok from the platform's own domain", "layer": "request"}
  it "answers an unauthenticated request" do
    get "/version"

    expect(response).to have_http_status(:ok)
  end

  # @intent: {"entity": "GET /version", "action": "mirror VERSION file content", "behavior": "the response body's version equals the VERSION file's own content, derived from the file rather than a hardcoded literal", "layer": "request"}
  it "reports the VERSION file's own content" do
    get "/version"

    expect(response.parsed_body).to eq(expected_body)
  end

  # The contract leg's primary pin, and the reason it is DERIVED rather than a literal: the digest
  # is folded from the vendored file at pin time, so re-vendoring the schema without re-serving it
  # (or serving a stale memo, or folding over anything other than the bytes the validator loads)
  # turns this red. A hardcoded expectation would be re-typed alongside such a change and agree
  # with itself forever.
  # @intent: {"entity": "GET /version", "action": "serve the enforced schema digest", "behavior": "the response body's schema_sha256 equals the SHA-256 of the vendored open-test-intent.v1.json as read at pin time, derived from the file rather than a hardcoded literal", "layer": "request"}
  it "reports the SHA-256 of the schema it validates against" do
    get "/version"

    expect(response.parsed_body.fetch("schema_sha256")).to eq(file_schema_sha256)
  end

  # The cross-repo drift signal, and a different question from the derived pin above: that one asks
  # "does the server serve what it enforces", this one asks "is what it enforces still the contract
  # the rest of the family targets". A file-derived value cannot ask the second of itself, which is
  # why this single literal earns its place — it is the same string three sibling repos pin, and
  # the pins disagreeing is the mechanism by which a drifted copy is found.
  # @intent: {"entity": "GET /version", "action": "agree with the family's schema pin", "behavior": "the served schema_sha256 equals the canonical v1 SHA-256 that open-test-intent, specguard-rspec and specguard-ts each pin independently", "layer": "request"}
  it "serves the same schema digest the sibling repos pin" do
    get "/version"

    expect(response.parsed_body.fetch("schema_sha256")).to eq(FAMILY_CANONICAL_V1_SHA256)
  end

  # A digest without its origin states a disagreement while withholding the one fact that says
  # which half to move — the `--schema-source` lesson. Pinned as the repo-relative path rather
  # than an absolute one: an absolute path differs in every container, which would make a stable
  # identity read look like it changed on redeploy.
  # @intent: {"entity": "GET /version", "action": "name the enforced schema's origin", "behavior": "the response body's schema_origin is the repo-relative path of the vendored schema this process validates against", "layer": "request"}
  it "names where the enforced schema came from" do
    get "/version"

    expect(response.parsed_body.fetch("schema_origin"))
      .to eq("vendor/schemas/open-test-intent.v1.json")
  end

  # @intent: {"entity": "GET /version", "action": "declare media type", "behavior": "the response is served with media type application/json", "layer": "request"}
  it "serves JSON" do
    get "/version"

    expect(response.media_type).to eq("application/json")
  end

  # An identity read never gains a failure mode: a missing or unreadable VERSION file is an honest
  # `null`, still 200 — the SPGD-1190 doctrine server-side. Simulated by stubbing the controller's
  # read accessor rather than mutating (or removing) the working tree's real file, which other
  # examples and processes are reading. Key-scoped — `have_key` plus a nil VALUE, not an
  # `eq(...)` on the whole body: an `include`-style assertion of the key's ABSENCE would also pass
  # some of those, and this endpoint's promise is that the key is present and null.
  # @intent: {"entity": "GET /version", "action": "answer null on unreadable file", "behavior": "with the VERSION read returning nil the route still answers 200 with a version key that is present and null", "layer": "request"}
  it "answers 200 with a null version when the file cannot be read" do
    allow(VersionsController).to receive(:server_version).and_return(nil)

    get "/version"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to have_key("version")
    expect(response.parsed_body.fetch("version")).to be_nil
  end

  # The contract leg inherits that doctrine rather than weakening it. Key-scoped for the same
  # reason the example above is: the promise is that the digest key is PRESENT and null, which an
  # `include`-style assertion of absence would also satisfy. A sentinel hex string here would be
  # worse than nil — a client comparing it against its own pin would read a real disagreement
  # where the truth is "this server could not say".
  # @intent: {"entity": "GET /version", "action": "answer null on unreadable schema", "behavior": "with the vendored schema read raising the route still answers 200 with a schema_sha256 key that is present and null", "layer": "request"}
  it "answers 200 with a null schema digest when the schema cannot be read" do
    clear_memo!
    allow(OpenTestIntent).to receive(:schema_sha256).and_raise(Errno::ENOENT)

    get "/version"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to have_key("schema_sha256")
    expect(response.parsed_body.fetch("schema_sha256")).to be_nil
  end

  # The origin survives a failed digest read, because it is a property of this BUILD (which path
  # this process would validate from) rather than a product of the read. "I enforce the copy at
  # this path and cannot currently read it" is strictly more actionable than two nulls — it still
  # names which half a client should ask about.
  # @intent: {"entity": "GET /version", "action": "keep the origin on a failed read", "behavior": "with the vendored schema read raising the response still names the schema_origin rather than nulling it alongside the digest", "layer": "request"}
  it "still names the schema origin when the digest cannot be read" do
    clear_memo!
    allow(OpenTestIntent).to receive(:schema_sha256).and_raise(Errno::ENOENT)

    get "/version"

    expect(response.parsed_body.fetch("schema_origin"))
      .to eq("vendor/schemas/open-test-intent.v1.json")
  end

  # The two examples below are the discriminating pins for the two mechanisms this endpoint's
  # identity reads rest on (both mutation-verified: with the VERSION rescue arm deleted BOTH go
  # red; with the `defined?` guard reverted to `||=` only the memoization one goes red — so each
  # pins a property the other does not). The examples above stub the ACCESSOR or the SERVICE CALL,
  # which pins the render contract for a nil memo but never exercises the mechanisms that PRODUCE
  # nil; these stub the READ PATH itself (`Pathname#binread`) rather than mutating the working
  # tree's real files, which other examples and processes read.

  # The rescue arm: a read that RAISES (missing file → Errno::ENOENT, a SystemCallError) must
  # surface as an honest null at 200 — an identity read never gains a failure mode, and a 500 from
  # the one endpoint whose whole job is to be askable is the defect this arm exists to prevent. The
  # memos are cleared first because a poisoned nil memo would let the request skip the read
  # entirely and pass for the wrong reason. Stubbing `Pathname#binread` fails BOTH reads at once —
  # the VERSION file and the vendored schema are read the same way — so this one example pins both
  # rescue arms and the whole body they produce: two honest nulls beside the origin, which is a
  # build property rather than a product of either read.
  # @intent: {"entity": "GET /version", "action": "answer null when the read raises", "behavior": "with both file reads raising ENOENT the route still answers 200 with a body of exactly version null, schema_sha256 null and the schema origin, via the rescue arms on the read paths", "layer": "request"}
  it "answers 200 with null identities when the READS raise (the rescue arms)" do
    clear_memo!
    allow_any_instance_of(Pathname).to receive(:binread).and_raise(Errno::ENOENT)

    get "/version"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "version" => nil, "schema_sha256" => nil,
      "schema_origin" => "vendor/schemas/open-test-intent.v1.json"
    )
  end

  # The `defined?` memoization guard: the nil answer must be memoized TOO — `||=` would treat nil
  # as unset and silently retry the failing read on EVERY request, the exact defect the guard's
  # departure from the `OpenTestIntent.raw_document` pattern exists to prevent. Counted at the read
  # path: one raising read across two `server_version` calls, never two.
  # @intent: {"entity": "GET /version", "action": "memoize the nil answer", "behavior": "with the read raising on every call, two server_version calls perform exactly one binread — the nil answer is memoized rather than re-derived per call", "layer": "request"}
  it "memoizes the nil answer — the read happens once" do
    clear_memo!
    calls = 0
    allow_any_instance_of(Pathname).to receive(:binread) { calls += 1; raise Errno::ENOENT }

    VersionsController.server_version
    VersionsController.server_version

    expect(calls).to eq(1)
  end

  # One read per process, not per request (the `OpenTestIntent.raw_document` property). The memo is
  # reset first so the example cannot ride a read some earlier example already performed, then the
  # pin is three-way: the first call answers the file's own content (a real read happened), the
  # second answers the FIRST call's very object — `strip` returns a fresh string every time it
  # runs, so identity is direct evidence no second read happened — and the memo itself is that
  # same object, so what the method returns is what it remembered.
  # @intent: {"entity": "GET /version", "action": "memoize the read", "behavior": "after the memo is cleared, the first server_version read answers the VERSION file's content, the second answers the same object rather than re-reading, and the class memo holds that object", "layer": "request"}
  it "reads the VERSION file once per process, not per request" do
    clear_memo!

    first = VersionsController.server_version
    second = VersionsController.server_version

    expect(first).to eq(file_version)
    expect(second).to equal(first)
    expect(VersionsController.instance_variable_get(:@server_version)).to equal(first)
    expect(first).to be_frozen
  end

  # The same property on the contract leg, and the reason it is worth pinning separately: the
  # digest is a FOLD over bytes, so a reader that re-read the file (or re-folded per request) would
  # serve an identical string and look perfectly healthy while paying a disk read and a hash on
  # every ask. Counted at the read path — scoped to the SCHEMA path's own `binread` rather than
  # `any_instance`, so the VERSION file's read cannot be miscounted as this one — and the real
  # bytes are wrapped through, so the digest under test is the digest of the real schema.
  # @intent: {"entity": "GET /version", "action": "read the schema once", "behavior": "after the memos are cleared, two schema_sha256 calls perform exactly one binread of the vendored schema rather than one per call", "layer": "request"}
  it "reads the vendored schema once per process, not per digest" do
    clear_memo!
    reads = 0
    allow(OpenTestIntent::SCHEMA_PATH).to receive(:binread).and_wrap_original do |original|
      reads += 1
      original.call
    end

    OpenTestIntent.schema_sha256
    OpenTestIntent.schema_sha256

    expect(reads).to eq(1)
  end

  # And the fold itself happens at most once: `Digest::SHA256.hexdigest` returns a FRESH string
  # every time it runs, so object identity across two calls is direct evidence no second fold
  # happened — the same identity argument the VERSION pin above makes about `strip`. The three-way
  # shape matches it too: the value is the real digest, the second call is the first call's very
  # object, and the module's memo holds that same object.
  # @intent: {"entity": "GET /version", "action": "memoize the schema digest", "behavior": "after the memos are cleared, the first schema_sha256 call answers the vendored file's SHA-256, the second answers the same object rather than re-folding, and the module memo holds that object", "layer": "request"}
  it "computes the schema digest once per process, not per request" do
    clear_memo!

    first = OpenTestIntent.schema_sha256
    second = OpenTestIntent.schema_sha256

    expect(first).to eq(file_schema_sha256)
    expect(second).to equal(first)
    expect(OpenTestIntent.instance_variable_get(:@schema_sha256)).to equal(first)
    expect(first).to be_frozen
  end

  # The controller memoizes its own answer too, and the `defined?` guard is what makes the NIL one
  # stick: `||=` would treat nil as unset and re-attempt the failing read on every request — the
  # same defect the VERSION leg's guard exists to prevent, pinned here on the leg that was added
  # beside it. Counted at the service call the controller rescues around, with it raising every
  # time: one attempt across two accessor calls, never two.
  # @intent: {"entity": "GET /version", "action": "memoize the null schema digest", "behavior": "with the schema digest raising on every call, two controller schema_sha256 calls attempt the read exactly once — the nil answer is memoized rather than re-derived per call", "layer": "request"}
  it "memoizes the null schema digest — the read is attempted once" do
    clear_memo!
    attempts = 0
    allow(OpenTestIntent).to receive(:schema_sha256) { attempts += 1; raise Errno::ENOENT }

    expect(VersionsController.schema_sha256).to be_nil
    expect(VersionsController.schema_sha256).to be_nil
    expect(attempts).to eq(1)
  end
end
