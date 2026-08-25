# frozen_string_literal: true

module Ingest
  # Records the refusals that are decided ABOVE the controller, and so can never reach
  # {Ingest::RejectionRecorder}'s call site inside `Api::V1::IngestsController#create`.
  #
  # Two Rack middlewares answer their own 400 and return without calling `@app.call`:
  # `GzipRequestBody` (a body that inflates past the cap, or is not the gzip it claims to be) and
  # `JsonParseErrorResponder` (a body that will not parse). The client gets a real 400 in the
  # endpoint's own shape and the platform stored nothing — so `RejectedIngests#refusing?` stayed
  # false and the panel rendered "No rejected deliveries", a positive claim that was false. This is
  # the design-point failure rather than an exotic one: `CreateIngestRejections` names the scenario
  # the table was built for as a VERSION FLOOR, a gem sending `Content-Encoding: gzip` at an
  # installation deployed before `GzipRequestBody` — which 400s here, above the controller, on
  # every run.
  #
  # This class fixes the ORDERING ACCIDENT and deliberately leaves the ATTRIBUTION RULE alone. It
  # writes only rows owned by a resolved repository; a request with no token, a wrong-prefix token
  # or an unresolvable one writes nothing, exactly as a 401 does.
  #
  # == Why it resolves the credential by hand
  #
  # There is no `current_repository` at this layer and no controller to ask — the credential is
  # sitting in the raw env and was simply never read. So the resolution below mirrors
  # `Api::BaseController#authenticate_api_key!` limb for limb, and the ORDER of those limbs is
  # load-bearing rather than incidental:
  #
  #   1. `env["HTTP_AUTHORIZATION"]`, matched as Bearer — the Rack-layer spelling of
  #      `request.headers["Authorization"]`. There is no `request.headers` here.
  #   2. The prefix gate, BEFORE any table is read. `Api::BaseController` states the intent at the
  #      equivalent line: "The prefix decides WHICH table before any of them is read — and, on a
  #      mismatch, that no table is read at all." Ingest accepts `ApiKey` only, so a `sgu_` user key
  #      resolves NO repository here and must not be looked up in `api_keys` at all.
  #   3. `ApiKey.authenticate`, a single digest lookup that returns nil on a miss.
  #
  # What it deliberately does NOT mirror is `touch_last_used!`. That lives inside the `before_action`
  # these paths never reach, and stamping it from here would silently change what the connection
  # indicator means — a key would read as "recently used" on the strength of a request that was
  # refused at the boundary. That is a separate decision and is not taken here.
  #
  # == Why it is scoped to the ingest path
  #
  # Both middlewares are scoped to `/api/`, which is WIDER than this table's meaning. An
  # `IngestRejection` is a DELIVERY that authenticated and was then refused for its payload, and
  # that is what the panel says out loud. `/api/v1/repository` also takes a `sgk_` repository key,
  # so a corrupt gzip body sent there would resolve a perfectly good repository and write a row
  # claiming a delivery was refused when no delivery was ever attempted. That would replace the
  # false "No rejected deliveries" this class removes with a false row of its own — the same
  # quiet falsehood one grain over. So the seam asks the narrower question the table can answer.
  #
  # == It cannot fail the request
  #
  # {Ingest::RejectionRecorder} already argues at length why a failed record must not turn a clean
  # 400 into a 500, and that reasoning transfers here unchanged and with one addition: this layer
  # ALSO resolves a credential, so it has a failure mode the controller path does not — the lookup
  # itself can raise. Everything is therefore wrapped, and a failure is reported rather than
  # swallowed, on that class's standing rule that a loss which is invisible on the surface by
  # construction has to be loud somewhere.
  class BoundaryRefusalRecorder
    # The one path a row may be attributed to, in its canonical spelling. See "Why it is scoped to
    # the ingest path" above, and `#ingest_path?` for why the comparison strips trailing slashes
    # rather than testing this string for equality outright.
    INGEST_PATH = "/api/v1/ingest"

    # `Api::BaseController#bearer_token`'s pattern, verbatim.
    BEARER_PATTERN = /\ABearer\s+(?<token>.+)\z/i

    # @param env [Hash] the raw Rack env of the request being refused
    # @param message [String] the middleware's own message, stored as the single reason
    # @return [IngestRejection, nil] the row written, or nil when no repository resolved or the
    #   write failed and was reported. No caller branches on it; it is returned so tests can.
    def self.record(env, message)
      new(env, message).record
    end

    def initialize(env, message)
      @env = env
      @message = message
    end

    def record
      return nil unless ingest_path?

      repository = resolve_repository
      return nil if repository.nil?

      RejectionRecorder.record(repository, [@message], user_agent: @env["HTTP_USER_AGENT"])
    rescue StandardError => e
      # The resolution half of this path — the half `Ingest::RejectionRecorder` does not own and so
      # does not already guard. A refused request must not start 500ing because the lookup that
      # decides who to bill the refusal to could not run.
      report(e)
      nil
    end

    private

    # Trailing slashes are STRIPPED rather than compared, because the router treats
    # `/api/v1/ingest`, `/api/v1/ingest/` and `/api/v1/ingest//` as the same action — all three
    # reach `ingests#create` (verified against `routes.recognize_path` and a real dispatch). An
    # exact string match would therefore have re-created this ticket's own defect one grain over:
    # a corrupt gzip POSTed to a trailing-slash spelling is a real delivery to the real endpoint,
    # refused for its payload, and would have stored nothing — leaving the panel saying "No
    # rejected deliveries" again, silently, for a URL a gem produces just by joining a configured
    # base to a path. Note `\/+\z` and not `chomp`: `chomp` removes only ONE trailing slash and
    # would still miss the doubled spelling the router accepts.
    #
    # It stays an equality test AFTER stripping, not a prefix test — `/api/v1/ingest/extra` is not
    # this endpoint (the router 404s it) and must not be attributed to it.
    def ingest_path? = @env["PATH_INFO"].to_s.sub(%r{/+\z}, "") == INGEST_PATH

    # Nil at every limb that `Api::BaseController` would have answered with a 401: no header, a
    # header that is not a Bearer, a token for the wrong table, or a token that resolves nothing.
    def resolve_repository
      token = bearer_token
      # The prefix gate, before `api_keys` is touched. A `sgu_` user key stops here.
      return nil unless token&.start_with?(ApiKey::TOKEN_PREFIX)

      ApiKey.authenticate(token)&.repository
    end

    def bearer_token
      match = @env["HTTP_AUTHORIZATION"].to_s.match(BEARER_PATTERN)

      match && match[:token].strip
    end

    # `handled: true` because the request continues and answers the 400 it had already determined.
    # No `repository_id` in the context — reaching here often means precisely that resolving one is
    # what failed — so the component and stage are what make a burst of these attributable.
    def report(error)
      Rails.error.report(error, handled: true, severity: :warning,
                                context: { stage: "boundary_resolve",
                                           component: "Ingest::BoundaryRefusalRecorder" })
    end
  end
end
