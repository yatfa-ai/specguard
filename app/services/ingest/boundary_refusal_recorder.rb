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
  # == Two credentials, two addresses (SPGD-984)
  #
  # The endpoint answers to two credentials at two paths, and each resolves its repository from a
  # different place — both of them readable HERE, above the controller, with the body unparsed:
  #
  #   * `POST /api/v1/ingest` with a `sgk_` repository key. The key IS one repository.
  #   * `POST /api/v1/repositories/:repository_id/ingest` with a `sga_` agent key. The key covers a
  #     SET, so the repository is the one the PATH names — and it is the path, not the body, that
  #     makes full attribution possible: this layer exists precisely because the body could not be
  #     read, so a body-borne repository would have left every agent-key boundary refusal — the
  #     ≥256 KiB gzipped payloads the agent route is FOR — unattributable, re-creating the false
  #     "No rejected deliveries" this class was written to remove. The only unattributable residue
  #     is a request whose PATH itself is garbage, which is the residue the `sgk_` route already has.
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
  #      mismatch, that no table is read at all." Ingest accepts `ApiKey` (`sgk_`) and
  #      `AgentApiKey` (`sga_`), so a `sgu_` user key resolves NO repository here and must not be
  #      looked up in either table. This gate USED TO state an `ApiKey`-only contract — one prefix,
  #      one table — and is now a two-entry dispatch on the same rule: the prefix still names
  #      exactly one table (the prefixes are same-length and mutually exclusive), and a token
  #      matching neither reads none.
  #   3. `ApiKey.authenticate` / `AgentApiKey.authenticate`, a single digest lookup that returns
  #      nil on a miss. For the agent key the repository is then the PATH's, and it must pass the
  #      key's own boundaries before a row is written — see `#resolve_agent_repository`.
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

    # The agent credential's address (SPGD-984): the repository is the segment. Anchored and
    # numeric so `/api/v1/repositories/12/ingest/extra` and `/api/v1/repositories/abc/ingest` are
    # not this endpoint (the router would not dispatch the first; the second names nothing).
    AGENT_INGEST_PATH = %r{\A/api/v1/repositories/(?<repository_id>\d+)/ingest\z}

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
    def normalized_path = @env["PATH_INFO"].to_s.sub(%r{/+\z}, "")

    def ingest_path? = normalized_path == INGEST_PATH

    # The repository id the PATH names on the agent route, or nil when the path is not that route.
    def agent_path_repository_id
      normalized_path.match(AGENT_INGEST_PATH)&.[](:repository_id)
    end

    # Nil at every limb that `Api::BaseController` would have answered with a 401, a 404 or a 403:
    # no header, a header that is not a Bearer, a token for a table this path does not serve, or a
    # token that resolves nothing — and, for the agent route, a repository outside the key's set or
    # a key without the ingest permission.
    #
    # THE PREFIX GATE, WIDENED (SPGD-984). This used to be `return nil unless
    # token&.start_with?(ApiKey::TOKEN_PREFIX)` — the `ApiKey`-only contract: one prefix, one
    # table, every other token a silent nil. It is now a dispatch keyed on WHICH PATH was posted
    # to as well as which prefix was presented, and the pairing is deliberate: a `sgk_` token at
    # the agent path or an `sga_` token at the segment-less path is a request the controller
    # answers 401 (the prefix is not accepted at that address — see `Api::V1::IngestsController`
    # for why the agent credential is only reachable by the segment route), so a row for it would
    # claim a delivery that never authenticated. The `sgu_` user key matches neither branch and
    # reads no table, exactly as before.
    def resolve_repository
      token = bearer_token
      return nil if token.nil?

      if ingest_path? && token.start_with?(ApiKey::TOKEN_PREFIX)
        ApiKey.authenticate(token)&.repository
      elsif (repository_id = agent_path_repository_id) && token.start_with?(AgentApiKey::TOKEN_PREFIX)
        resolve_agent_repository(AgentApiKey.authenticate(token), repository_id)
      end
    end

    # The agent route's attribution: the repository the PATH names, written ONLY if the key holds
    # the same two boundaries the controller measures it against — covers the repository AND holds
    # `runs.ingest`. The check is the policy's own (`AgentApiKeyPolicy`), not a second spelling of
    # it, so a request the controller would have answered 404 or 403 cannot leave a refusal row
    # that says it was a delivery refused for its payload: a key writing rows into a repository it
    # may not even open would turn the Rejected-deliveries panel into a write channel for anyone
    # holding any agent key.
    def resolve_agent_repository(key, repository_id)
      return nil if key.nil?

      repository = Repository.find_by(id: repository_id)
      return nil if repository.nil?

      policy = AgentApiKeyPolicy.new(key, repository)
      repository if policy.member? && policy.can?(:runs_ingest)
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
