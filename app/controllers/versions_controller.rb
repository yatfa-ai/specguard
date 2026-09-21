# frozen_string_literal: true

# Answers the one question every other member of the SpecGuard family can already be asked and
# the server itself could not: WHICH BUILD IS THIS, AND WHICH CONTRACT DOES IT ENFORCE? The release
# bot bumps the platform's `VERSION` file on every release and touches nothing else, and every
# client that talks to this server carries an askable identity of its own — the Go validator's
# `--version` with its schema digest and its `--schema-source` origin line, both Ruby CLIs pinned
# three ways, both TS CLIs, the `specguard-ts/<version>` User-Agent, the bridge's manifest-derived
# `serverInfo` in the initialize handshake. The server they all talk TO was the one member of the
# family that could not answer. This route is that answer: an unauthenticated `GET /version`
# returning `{"version": …, "schema_sha256": …, "schema_origin": …}`-shaped JSON — the build read
# from the VERSION file itself, and the enforced OpenTestIntent contract read from the vendored
# schema this process validates every ingested annotation against.
#
# Who needs it over the network rather than from the repo: a client author verifying an upgrade
# took effect, an agent pinning server message TEXT in a contract suite (which build's sentences
# is it pinning against?), a bug reporter stating which build produced the behavior, and — the
# contract leg — a CI author whose annotations lint clean locally and 400 on ingest, who until now
# had no channel to discover which half of that disagreement moved. None of the four has deploy
# access — that is the entire consumer class.
#
# `ActionController::API`, not `ApplicationController`, on the terms `SchemasController` already
# states: there is nothing to authenticate, no session to touch, no CSRF token to check and no
# browser to gate — this answers a `curl` from someone with no account, which is the entire point
# of it existing. It is a ROOT-LEVEL route, deliberately outside `/api/v1`, for the same reason
# `/up` and the schema mirror are: the credential-seam guard fails CLOSED — every controller under
# `api/` must declare an accepted credential or answer 401 to everything — so an unauthenticated
# identity read inside that namespace would be a doctrine exception, while the root level is where
# the platform already serves its no-account reads.
#
# Build identity is treated as non-secret, matching pinned family design: every client SENDS its
# own version unauthenticated on every request, the platform serves the schema unauthenticated on
# purpose, `/up` is unauthenticated, and the crafted error messages already make builds
# distinguishable to anyone who can reach the API.
class VersionsController < ActionController::API
  VERSION_PATH = Rails.root.join("VERSION")

  # WHERE the enforced contract comes from, beside WHAT it digests to. The landed `--schema-source`
  # lesson (`open-test-intent/cmd/validate-intent/schemasource.go`, which prints
  # `schema <origin> sha256:<hex>`) is that a digest alone states a DISAGREEMENT while withholding
  # the one fact that says which half to move: told only that two digests differ, a client cannot
  # tell whether the server is enforcing a stale vendored copy or the client is carrying one.
  #
  # The label is the vendored copy's REPO-RELATIVE path, derived from `OpenTestIntent::SCHEMA_PATH`
  # rather than typed out, so it cannot drift from the constant the validator actually loads. It is
  # repo-relative and not absolute on purpose: an absolute path is a different string in every
  # container and would make a stable identity read look like it changed on redeploy, while the
  # repo-relative form is the same self-describing answer everywhere and names the protocol, its
  # version, and that this server carries its own copy — so "re-vendor and redeploy" is legible as
  # the server-side move. The same bytes are fetchable, unauthenticated, from this same host at
  # `/schemas/open-test-intent.v1.json`, so a client can digest them itself and check this answer.
  SCHEMA_ORIGIN = OpenTestIntent::SCHEMA_PATH.relative_path_from(Rails.root).to_s.freeze

  class << self
    # The VERSION file's content, read once per process — the `OpenTestIntent.raw_document`
    # memoization pattern (one read per process; a deploy is a process restart, which is exactly
    # when the answer changes). The `defined?` guard rather than `||=` is the one deliberate
    # departure from that pattern: unlike `binread` on the vendored schema, our read can return
    # nil (below), and `||=` would silently retry the failing read on EVERY request — the nil
    # answer must be memoized too, not re-derived per request.
    def server_version
      @server_version = read_version unless defined?(@server_version)
      @server_version
    end

    # The SHA-256 of the schema this process ENFORCES, read once per process — the same shape as
    # `server_version` above, including its one deliberate departure from the
    # `OpenTestIntent.raw_document` pattern: the `defined?` guard rather than `||=`, because this
    # read can answer nil (below) and `||=` would silently retry the failing read on every request.
    #
    # `OpenTestIntent.schema_sha256` memoizes the digest itself, so a successful answer costs one
    # file read and one fold per process no matter how many times this route is asked; this memo
    # is what makes the FAILING answer cost one attempt rather than one per request.
    def schema_sha256
      @schema_sha256 = read_schema_sha256 unless defined?(@schema_sha256)
      @schema_sha256
    end

    private

    # Missing or unreadable file → nil, never an exception and never a sentinel string: an
    # identity read never gains a failure mode. nil is the honest absence, and the route still
    # answers 200 with a null `version` beside the other identities — an unverifiable identity is
    # a better answer than a 500 from the one endpoint whose whole job is to be askable.
    def read_version
      VERSION_PATH.binread.strip.freeze
    rescue SystemCallError, IOError
      nil
    end

    # The contract leg inherits the doctrine above rather than weakening it: a vendored schema
    # that cannot be read answers `{"schema_sha256": null}` at 200, never a 500 and never a
    # sentinel digest — a fabricated hex string would be WORSE than nil here, since a client
    # comparing it against its own pin would read a real disagreement where the truth is "this
    # server could not say". The same two error classes `read_version` rescues, for the same
    # reason: `binread` on a missing or unreadable path raises `SystemCallError` (`Errno::ENOENT`,
    # `Errno::EACCES`) or `IOError`, and nothing else on this path is a failure this route is
    # entitled to swallow.
    def read_schema_sha256
      OpenTestIntent.schema_sha256
    rescue SystemCallError, IOError
      nil
    end
  end

  # Three named facts, and the second and third are a PAIR: `schema_sha256` is what this server
  # enforces, `schema_origin` is where those bytes came from. Serving the digest alone would let a
  # client detect a disagreement without learning which half to move — the `--schema-source`
  # lesson recorded on `SCHEMA_ORIGIN` above.
  #
  # `schema_origin` is served unconditionally, including beside a null digest: the origin is a
  # compile-time property of this build (which path this process would validate from), not a
  # product of the read, so nulling it when the read fails would withhold a fact the server still
  # knows — and "I enforce the copy at this path and cannot currently read it" is a strictly more
  # actionable answer than two nulls.
  def show
    render json: {
      version: self.class.server_version,
      schema_sha256: self.class.schema_sha256,
      schema_origin: SCHEMA_ORIGIN
    }
  end
end
