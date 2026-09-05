# frozen_string_literal: true

# Base class for every machine-facing endpoint.
#
# Auth is a Bearer API key. There are now THREE kinds of them, and the distinction is the whole
# subject of this class:
#
#   * `sgk_…` — an `ApiKey`, which speaks for ONE repository and resolves `current_repository`.
#   * `sgu_…` — a `UserApiKey`, which speaks for ONE PERSON and resolves `current_api_user`.
#   * `sga_…` — an `AgentApiKey`, which speaks for NOBODY: it carries its own repository set and
#     permission set, and answers repository questions through `AgentApiKeyPolicy` rather than
#     through any person's rights.
#
# ## "Resolved a key" and "resolved a repository" are two different facts
#
# They used to be one. `authenticate_api_key!` resolved a key and then read its repository
# unconditionally, which was correct while every credential had one, and both shipped endpoints lean
# on it structurally: `Api::V1::IngestsController` passes `current_repository` straight into
# `Ingest::RunRecorder.record(...)` on the strength of "authentication got this far, so there is
# one". A user key reaching that line does not raise where it is written — it arrives as `nil` and
# surfaces as a 500, or worse as telemetry recorded against nothing.
#
# So the requirement is DECLARED, per controller, and it is declared to this class rather than
# checked downstream:
#
#   class Api::V1::IngestsController < Api::BaseController
#     accepts_repository_credential
#
# ## Failing closed, and what that costs
#
# A controller that declares NOTHING answers 401 to everything, including a perfectly valid key.
# That is deliberate and it is the safe direction: the alternative default — accept whichever
# credential the caller happened to send — hands a new endpoint the union of every credential
# surface there is, on the
# day somebody forgets a line, and nothing in the response would say so. Be honest about the cost:
# at runtime a missing declaration presents as "my key stopped working" rather than as an error
# naming the controller. That is what makes the trade acceptable rather than merely safe:
# `spec/requests/api/v1/credential_seam_spec.rb` walks the route table and fails, by class name, on
# any routed subclass that has declared nothing — so the omission is loud where it is cheap to fix
# and silent only where being silent is also being safe.
#
# ## One indexed read, still
#
# The prefix is checked BEFORE any lookup, against the classes this controller accepts — a scan of
# the declaration, not of any table, and at most one class can match because the prefixes are
# same-length and mutually exclusive. So a repository key sent to a user-key endpoint (or either
# sent to an endpoint accepting neither) is refused with no query at all, and a valid presentation
# costs exactly the single `find_by` on a unique digest index that resolution has always been.
# Probing tables per request would have been the naive shape; it still is.
#
# `bind_principal` is part of that claim, not an exception to it. It runs on every authenticated
# request, and reading the principal is free only because resolution brings it back in the SAME
# statement: `UserApiKey.authenticate` uses `eager_load(:user)` rather than `joins(:user)` for
# exactly this reason, and its comment spells out the difference. `ApiKey`'s branch is not the same
# shape and is not held to the same claim — `current_repository` is the endpoint's PAYLOAD, was
# never joined against, and costs its own read by design.
#
# This paragraph is a measured claim rather than an asserted one, and the measurement is scoped to
# match it: `spec/requests/api/v1/credential_seam_spec.rb` counts a whole valid presentation across
# BOTH credential tables AND `users`, so a second read of the person fails there. A guard filtered
# to the credential tables alone would report "exactly one read" while the request made two, which
# is precisely how this paragraph came to be wrong once already.
class Api::BaseController < ActionController::API
  # The credential classes this endpoint accepts — a subset of {ApiKey, UserApiKey, AgentApiKey},
  # empty for "has not said, therefore nothing". Set through the macros below rather than assigned
  # directly, so the declaration reads as a sentence in the subclass and greps as one.
  #
  # It is an ARRAY now rather than the single class it was, because the plural endpoints answer to
  # a person's `sgu_` key AND to the `sga_` agent credential, and the one-class shape had no way to
  # say that. What did NOT change is the discipline the single class enforced: an endpoint accepts
  # only the credential classes it names, a token whose prefix matches none of them is refused
  # before any table is read, and an endpoint that declares nothing still answers 401 to
  # everything. Every prefix match in the array resolves exactly one table — the prefixes are
  # same-length and mutually exclusive (the discipline `UserApiKey::TOKEN_PREFIX` documents, and
  # the seam spec walks), so "which credential is this?" is answered by the token's first four
  # characters and never by probing.
  #
  # `instance_accessor: false` because a public instance method on a controller is a routable
  # action, and this one is configuration rather than behaviour.
  class_attribute :accepted_credentials, instance_accessor: false, default: [].freeze

  before_action :authenticate_api_key!

  # The resolve-and-authorize seam for a repository named in the URL — the SAME implementation the
  # browser tree authorizes with (`ApplicationController` includes the same module), so a change to
  # who may do what cannot land on one surface and miss the other. See the module's header for the
  # `authorizing_user` seam this class answers below, and for why the 404-vs-403 fork it carries is
  # rendered here as JSON rather than left to Rails' default public-exception page (the two
  # `rescue_from` registrations immediately below).
  include RepositoryAuthorization

  # The web tree answers the middleware mapping in `config/application.rb` for these exceptions;
  # an `ActionController::API` has no equivalent wiring, and an escaped raise would render Rails'
  # default public-exception body instead of this controller's own `{error:, message:}` shape. So
  # the fork's two halves are each caught HERE, at the base every machine endpoint inherits from,
  # and rendered with the renderers below — preserving the property the concern exists to carry:
  # a non-member learns nothing of the repository's existence (404), a member missing the
  # capability is told the truth (403), and both bodies are the API's own rather than HTML.
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from SpecGuard::NotAuthorized, with: :render_forbidden

  # This endpoint needs `current_repository`. A `sgu_` user key gets 401 here.
  def self.accepts_repository_credential
    accept_credential ApiKey
  end

  # This endpoint needs `current_api_user`. A `sgk_` repository key gets 401 here.
  def self.accepts_user_credential
    accept_credential UserApiKey
  end

  # This endpoint also answers to an `sga_` agent credential, whose own repository set and
  # permission set bound every action it reaches (see `AgentApiKeyPolicy`). Declared ALONGSIDE
  # `accepts_user_credential`, never instead of it: the agent credential is the bounded form of
  # what the person credential carries, and the endpoints that accept it are read-only for it —
  # the actions that must act AS a person guard themselves with `require_person_credential`.
  def self.accepts_agent_credential
    accept_credential AgentApiKey
  end

  # The one writer behind the three macros. `|` dedupes so a doubled declaration is idempotent
  # rather than a doubled array, and the frozen assignment is what makes each subclass's set its
  # own rather than a shared mutable default.
  def self.accept_credential(klass)
    self.accepted_credentials = (accepted_credentials | [klass]).freeze
  end

  private

  # Private on purpose: a public method on a controller is a routable action.
  #
  # `current_repository` is NOT in this list any more: it is supplied by `RepositoryAuthorization`
  # (included above), which resolves the repository named in the URL and authorizes a capability
  # against it. For a repository-credential endpoint the attribute reader's old behaviour is
  # preserved exactly: `bind_principal` sets `@current_repository` during authentication, and the
  # concern's `current_repository` called with no capability returns that memoized value without
  # consulting `params` at all — the ingest contract, where the credential IS the authorization.
  # For a user-credential endpoint it resolves `params[:repository_id]`/`params[:id]` and
  # authorizes, which is the mutating half this slice ships.
  #
  # `current_api_user` rather than `current_user`: the name `current_user` means "the person holding
  # this browser session" everywhere else in this application
  # (`ApplicationController#current_user`), and this is a different thing arrived at a different way
  # — a person named by a token, with no session anywhere near it.
  attr_reader :current_api_key, :current_api_user

  # How `RepositoryAuthorization` names THIS tree's principal. The API's principal is the person a
  # `sgu_` key speaks for — `current_api_user` — which is a different thing, arrived at a different
  # way, from the web tree's `current_user`, and the two names stay separate on purpose. See the
  # module's header; the web tree answers the same seam with `current_user`.
  def authorizing_user
    current_api_user
  end

  def authenticate_api_key!
    credentials = self.class.accepted_credentials
    # See "Failing closed" above. Not an exception: a misconfiguration must not be distinguishable
    # from a bad key by anyone holding one.
    return render_unauthorized if credentials.empty?

    token = bearer_token
    # The prefix decides WHICH table before any of them is read — and, on a mismatch, that no
    # table is read at all. With more than one accepted credential this is a scan over the
    # DECLARATION, not over the database: the prefixes are same-length and mutually exclusive
    # (see `accepted_credentials`), so at most one class matches and the scan reads nothing.
    credential = credentials.find { |klass| token&.start_with?(klass::TOKEN_PREFIX) }
    return render_unauthorized unless credential

    @current_api_key = credential.authenticate(token)
    if @current_api_key.nil?
      attribute_refused_revocation(token, credential)
      return render_unauthorized
    end

    bind_principal
    @current_api_key.touch_last_used!
  end

  # THE ONE 401 THE PLATFORM OWNS A ROW FOR — and the only write on the failure path.
  #
  # `authenticate` returning nil resolves no principal, so the 401 itself writes nothing and stays
  # unattributable in general. A REVOKED repository key is the exception this method closes: the
  # row still exists (`ApiKey#revoke!` retires rather than deletes), the digest still names it, and
  # this platform stamped the instant the token was retired — so the refused presentation is a fact
  # about a row this application owns, the same criterion `credential_health` already states for
  # reporting a 401 it did not observe. Stamping `last_refused_at` is what lets the repository page
  # and the agent API say "a key you revoked is still being presented" instead of "Not connected
  # yet".
  #
  # COST, and the shape it is held to: at most ONE indexed read — the same unique digest index
  # resolution uses, with `revoked_at` checked on the row it returns — plus, on a hit, the stamp.
  # No write on a miss: an unknown token (never a key for anything) stays unattributable, and
  # nothing is synthesized for it. A VALID presentation never reaches this method at all, so it
  # still costs exactly the one resolving read the seam spec pins.
  #
  # `credential == ApiKey` is an explicit guard, not a reliance on the prefix check above: a
  # `sgu_` token is refused before resolution on a user-key endpoint, but this method's contract
  # is about the credential CLASS — `UserApiKey` has no revocation lifecycle (`revoked_at` is not
  # its column) and must never be probed here. Stated rather than inherited, so a future change to
  # the prefix discipline cannot silently widen this write path to the other table.
  def attribute_refused_revocation(token, credential)
    return unless credential == ApiKey

    ApiKey.revoked.find_by(token_digest: ApiKey.digest(token))&.touch_last_refused!
  end

  # The one place the credentials diverge after resolution. A `case` rather than a polymorphic
  # method on the models: `ApiKey` is deliberately untouched by this change (its guarantees are what
  # the separate-table decision exists to preserve), so the knowledge of what each key binds to
  # lives here, where the distinction is already the subject.
  #
  # `AgentApiKey` binds NOTHING beyond the key already held in `@current_api_key` — that is the
  # credential's whole point. A `sgu_` key binds a person and inherits their rights; an `sga_` key
  # resolves to itself and carries its own boundaries, which is why the principal the authorization
  # concern sees is the key (see `build_repository_policy` below) and there is no person anywhere
  # in the request.
  def bind_principal
    case @current_api_key
    when ApiKey      then @current_repository = @current_api_key.repository
    when UserApiKey  then @current_api_user   = @current_api_key.user
    when AgentApiKey then # the key itself is the principal; there is nobody to bind
    end
  end

  # HOW THE AGENT CREDENTIAL ANSWERS REPOSITORY QUESTIONS. `RepositoryAuthorization`'s default
  # builds the person policy (`RepositoryPolicy.new(authorizing_user, …)`), which is the right
  # answer for the web tree and for a `sgu_` key and the WRONG answer for an `sga_` key: it would
  # measure the request against `current_api_user` — nil here, and a person's membership rights
  # even if one were bound — rather than against the boundaries the key itself carries. So the
  # branch lives HERE, next to `bind_principal`, where the knowledge of what each credential is
  # already lives, and the concern keeps asking its protocol questions (`member?` / `can?`) of
  # whichever policy this hands back. The 404-vs-403 fork is thereby shared, not re-decided: an
  # agent key out of set is a 404, in set without the permission a 403, exactly as for a person.
  def build_repository_policy(repository)
    if @current_api_key.is_a?(AgentApiKey)
      AgentApiKeyPolicy.new(@current_api_key, repository)
    else
      super
    end
  end

  # THE READ BOUNDARY AS A RELATION — the repositories this credential may list and name by id.
  # For a person credential that is `Repository.accessible_by` (owned UNION shared-with-them);
  # for an agent credential it is the key's own set, mint-time fixed — deliberately NOT
  # `accessible_by` of anybody, because the key holds nobody's rights. The plural endpoints
  # scope through this one method, so a repository outside whichever boundary applies never
  # enters a query, let alone a response.
  def authorized_repositories
    if @current_api_key.is_a?(AgentApiKey)
      @current_api_key.repositories
    else
      Repository.accessible_by(current_api_user)
    end
  end

  # THE GUARD FOR ACTIONS THAT MUST ACT AS A PERSON. A controller that accepts the agent
  # credential accepts it for its READ actions; the mutating and person-anchored verbs —
  # registering, renaming, deleting, minting `sgk_` keys, editing members — are refused here,
  # declared per action with `before_action … only:`, because the seam is controller-scoped and
  # the narrowing is the endpoint's own sentence.
  #
  # 403, not 401: the token is valid and of a class this endpoint accepts — "a valid Bearer API
  # key is required" would be a lie. What is refused is the ACT: an agent key cannot act as a
  # person, which is the same authenticated-but-not-yours shape every other 403 on this surface
  # carries. On the only two classes a multi-credential endpoint can resolve, this passes
  # `UserApiKey` and refuses `AgentApiKey`; a `sgk_` key can never reach a controller that does
  # not accept it, because the prefix turns it away first.
  def require_person_credential
    return if @current_api_key.is_a?(UserApiKey)

    render_forbidden("This action requires a personal key — an agent key cannot act as a person.")
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    match = header.match(/\ABearer\s+(?<token>.+)\z/i)

    match && match[:token].strip
  end

  def render_unauthorized
    render json: { error: "unauthorized", message: "A valid Bearer API key is required." },
           status: :unauthorized
  end

  # ⭐ THE ANSWER FOR "YOU MAY NOT SEE THIS", AND FOR "THIS DOES NOT EXIST", DELIBERATELY THE SAME
  # ONE. A member route scoped through `Repository.accessible_by(current_api_user)` never has the
  # forbidden row in hand to refuse — it was not in the relation — so there is no 403 to render and
  # no query that would establish one. Answering 403 would require asking a SECOND, unscoped
  # question purely to tell a caller that something they cannot open is nevertheless there, which
  # discloses the existence of every repository on the platform to anyone willing to enumerate ids.
  #
  # So the two states are indistinguishable from outside, and that is the property rather than a
  # limitation of the implementation. See `Api::V1::UserRepositoriesController#show`.
  #
  # No `details`: a 404 has nothing per-field to say, and the id is already in the caller's URL.
  def render_not_found(message = "The requested resource could not be found.")
    render json: { error: "not_found", message: message }, status: :not_found
  end

  # The OTHER half of the fork `RepositoryAuthorization` carries, rendered for a member of the
  # repository who lacks the capability the action asked for. Unlike the 404 above there is a real
  # row and a real permission in hand, so the caller is owed the truth rather than silence — 404
  # here would be a lie to someone who can already see the repository.
  #
  # `message` is the renderer's own sentence rather than the exception's: `SpecGuard::NotAuthorized`
  # carries no text, and the capability that was refused is the controller's knowledge, not the
  # policy's — a caller who held `view` and asked for `keys.manage` is told what they may do about
  # it (ask the owner) rather than which internal symbol was missing.
  def render_forbidden(message = "You do not have permission to do that on this repository.")
    render json: { error: "forbidden", message: message }, status: :forbidden
  end

  # `details` carries every validation failure; `message` repeats the first so a client that reads
  # only the two conventional keys still learns which spec is at fault.
  def render_bad_request(details)
    details = Array(details)

    render json: { error: "bad_request",
                   message: details.first || "The request could not be understood.",
                   details: details },
           status: :bad_request
  end
end
