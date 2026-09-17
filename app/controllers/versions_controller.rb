# frozen_string_literal: true

# Answers the one question every other member of the SpecGuard family can already be asked and
# the server itself could not: WHICH BUILD IS THIS? The release bot bumps the platform's `VERSION`
# file on every release and touches nothing else, and every client that talks to this server
# carries an askable identity of its own — the Go validator's `--version` with its schema digest,
# both Ruby CLIs pinned three ways, both TS CLIs, the `specguard-ts/<version>` User-Agent, the
# bridge's manifest-derived `serverInfo` in the initialize handshake. The server they all talk TO
# was the one member of the family that could not answer. This route is that answer: an
# unauthenticated `GET /version` returning `{"version": "0.1.45"}`-shaped JSON read from the
# VERSION file itself.
#
# Who needs it over the network rather than from the repo: a client author verifying an upgrade
# took effect, an agent pinning server message TEXT in a contract suite (which build's sentences
# is it pinning against?), a bug reporter stating which build produced the behavior. None of the
# three has deploy access — that is the entire consumer class.
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

    private

    # Missing or unreadable file → nil, never an exception and never a sentinel string: an
    # identity read never gains a failure mode. nil is the honest absence, and the route still
    # answers 200 with `{"version": null}` — an unverifiable identity is a better answer than a
    # 500 from the one endpoint whose whole job is to be askable.
    def read_version
      VERSION_PATH.binread.strip.freeze
    rescue SystemCallError, IOError
      nil
    end
  end

  def show
    render json: { version: self.class.server_version }
  end
end
