# frozen_string_literal: true

require "rails_helper"

# The server's identity read (SPGD-1197). Its contract is narrow: anyone, with no credentials, can
# ask the server which build it is, and the answer it gives is the VERSION file's own content —
# derived from the file at pin time, never a hardcoded literal (a hardcoded literal would pass
# today and fail the day the release bot bumps; SPGD-1188's found defect was exactly a claimed-but-
# false identity surviving healthy docs). Each example below pins one half of that.
RSpec.describe "GET /version", type: :request do
  let(:version_path) { Rails.root.join("VERSION") }

  # The expected value is DERIVED from the file the release bot bumps — the pin-that-would-have-
  # caught-the-drift pattern: when the bot bumps, this pin fails against a server still serving
  # the old answer, rather than two hardcoded strings agreeing with each other and with nothing.
  let(:file_version) { version_path.binread.strip }

  # @intent: {"entity": "GET /version", "action": "serve without credentials", "behavior": "a GET with no credentials returns HTTP 200 ok from the platform's own domain", "layer": "request"}
  it "answers an unauthenticated request" do
    get "/version"

    expect(response).to have_http_status(:ok)
  end

  # @intent: {"entity": "GET /version", "action": "mirror VERSION file content", "behavior": "the response body's version equals the VERSION file's own content, derived from the file rather than a hardcoded literal", "layer": "request"}
  it "reports the VERSION file's own content" do
    get "/version"

    expect(response.parsed_body).to eq("version" => file_version)
  end

  # @intent: {"entity": "GET /version", "action": "declare media type", "behavior": "the response is served with media type application/json", "layer": "request"}
  it "serves JSON" do
    get "/version"

    expect(response.media_type).to eq("application/json")
  end

  # An identity read never gains a failure mode: a missing or unreadable VERSION file is an honest
  # `null`, still 200 — the SPGD-1190 doctrine server-side. Simulated by stubbing the controller's
  # read accessor rather than mutating (or removing) the working tree's real file, which other
  # examples and processes are reading. `equal(nil)` on a parsed body member, not
  # `eq("version" => nil)` on the whole body: `include`-style absence of the key would also pass
  # some of those, and this endpoint's promise is that the key is present and null.
  # @intent: {"entity": "GET /version", "action": "answer null on unreadable file", "behavior": "with the VERSION read returning nil the route still answers 200 with a version key that is present and null", "layer": "request"}
  it "answers 200 with a null version when the file cannot be read" do
    allow(VersionsController).to receive(:server_version).and_return(nil)

    get "/version"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to have_key("version")
    expect(response.parsed_body.fetch("version")).to be_nil
  end

  # One read per process, not per request (the `OpenTestIntent.raw_document` property). The memo is
  # reset first so the example cannot ride a read some earlier example already performed, then the
  # pin is three-way: the first call answers the file's own content (a real read happened), the
  # second answers the FIRST call's very object — `strip` returns a fresh string every time it
  # runs, so identity is direct evidence no second read happened — and the memo itself is that
  # same object, so what the method returns is what it remembered.
  # @intent: {"entity": "GET /version", "action": "memoize the read", "behavior": "after the memo is cleared, the first server_version read answers the VERSION file's content, the second answers the same object rather than re-reading, and the class memo holds that object", "layer": "request"}
  it "reads the VERSION file once per process, not per request" do
    VersionsController.remove_instance_variable(:@server_version) if
      VersionsController.instance_variable_defined?(:@server_version)

    first = VersionsController.server_version
    second = VersionsController.server_version

    expect(first).to eq(file_version)
    expect(second).to equal(first)
    expect(VersionsController.instance_variable_get(:@server_version)).to equal(first)
    expect(first).to be_frozen
  end
end
