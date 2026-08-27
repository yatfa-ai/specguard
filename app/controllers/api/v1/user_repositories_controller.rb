# frozen_string_literal: true

# WHICH REPOSITORIES THE PERSON BEHIND THIS TOKEN MAY OPEN — the first endpoint that answers to a
# `sgu_` user key, and the one endpoint this slice ships to prove that credential works.
#
# ## Why this is not an action on `Api::V1::RepositoriesController`
#
# That controller serves `GET /api/v1/repository`, singular, which answers to a `sgk_` repository
# key and is a report about the ONE repository that key names. This answers to a different
# credential and returns a set. Two surfaces that share a noun and nothing else: the same class
# would carry two `accepts_*_credential` declarations, which the seam has no way to express and no
# reason to.
#
# ## The authorization rule is not reinvented here
#
# `Repository.accessible_by` is this application's read-side boundary — owned UNION shared-through-a
# -membership — and it lives on the model so that every surface asking "which repositories may this
# person see" asks the same place. The dashboard's repository list reads it; so does this. A
# repository the person neither owns nor is a member of is not filtered out of this response, it
# never enters it, so nothing here can leak the fact that it exists.
#
# ## Ordering
#
# `github_full_name` — stable, and the only column on this list a client could page or diff against
# without SpecGuard promising an id ordering it has not designed. `accessible_by` returns a relation
# precisely so a caller can chain this without landing in the scope (see the note there).
#
# ## `#create` — registering, without the GitHub credential registration has always needed
#
# The ownership gate is not bypassed here and it is not reimplemented here. `RepositoryRegistration`
# is the same gate the web tree uses, in the same order; what differs is the EVIDENCE it is handed.
# The web passes a verifier that asks GitHub live with the token in the browser's session. This
# request has no session and no token — that is the whole point of an API key — so it passes one
# backed by a `GithubRegistrationGrant`: what GitHub said about this person, recorded at a moment a
# live token was in hand. A person with no grant, or one past its bound, registers NOTHING.
#
# ## Why the first `sgk_` key comes back in this same response
#
# A repository with no key is a repository nothing can deliver to, and minting one is the very next
# thing every caller would do. The web equivalent is two gestures because a person is there to make
# them; an agent registering a repository in order to wire CI up would otherwise have to follow a
# second endpoint that does not exist yet. The token is revealed HERE and nowhere else, ever —
# `ApiKey` stores a SHA-256 digest and holds the plaintext in memory for exactly the request that
# minted it, so this response body is the only copy that will ever be handed out. That is the same
# reveal-once property the web page's flash has, delivered as JSON instead of as HTML.
class Api::V1::UserRepositoriesController < Api::BaseController
  # The two grouped reads behind `delivery_health` — the newest refusal and the newest accepted run,
  # one query each for the whole list. Shared with `RepositoriesController`, whose card grid badges
  # the same verdict for a person; see `#delivery_verdicts` for why this list carries the block at
  # all, and the module for why the grid's shard priming did not come with it.
  include DeliveryHealthLookups

  # THIS ENDPOINT NEEDS A PERSON. A `sgk_` repository key resolves no user and gets 401 — which is
  # the direction of the seam that is easy to get wrong, because a repository key IS a valid
  # credential and this list would otherwise have to invent an answer for one. See
  # `Api::BaseController`.
  accepts_user_credential

  # The name every first key gets. Deliberately the same string `ApiKeysController` defaults to, so
  # a repository registered by an agent and one registered in a browser have identically-named keys
  # rather than two conventions a person has to learn.
  #
  # The naming is only half of that parity — see `#create` for the other half, which is the one that
  # cannot be repaired later if it is skipped.
  FIRST_KEY_NAME = "Default CI Key"

  # The delivery verdicts are resolved ONCE for the whole response and threaded into `#serialize`,
  # which takes one repository and has no access to the collection. Resolving them per entry would
  # be the N+1 `RejectedIngests.verdict` exists to avoid — two aggregates per listed repository
  # instead of two for the list.
  def index
    repositories = Repository.accessible_by(current_api_user).order(:github_full_name).to_a
    verdicts = delivery_verdicts(repositories)

    render json: {
      repositories: repositories.map { |repository| serialize(repository, verdicts[repository.id]) }
    }
  end

  # WHAT MAY BE REGISTERED — the reading `#index` cannot give, because that one serves
  # `Repository.accessible_by` and a repository nobody has registered yet is by definition not in
  # it. Without this an agent holding an `sgu_` key can only guess a name and POST it blind, one at
  # a time, and learn the answer by being refused.
  #
  # ## It reads the snapshot; it does not take one
  #
  # ZERO GitHub round trips, and that is a requirement rather than an optimisation. This request
  # has no user token to ask GitHub with — that absence is the entire reason `GithubRegistrationGrant`
  # exists — so calling `InstallationRepositories.sources` here would ask with nothing and get
  # `:not_authorized` back, and calling `GithubRegistrationGrant.capture` would overwrite a good
  # grant with an empty reading. The only honest thing an API request can serve is what was
  # recorded, plus how old it is.
  #
  # ## It admits nothing
  #
  # `RepositoryRegistration` and its verifiers are untouched by this action and remain the only
  # thing that admits a registration. This is the same set the gate would consult, read out loud
  # in advance; a name appearing here is not a promise the write will succeed (the repository may
  # be registered by somebody else between the two calls, and `registered` below says when it
  # already is).
  #
  # ## The refusal is the gate's own sentence
  #
  # No grant and a stale grant are the two states `GrantVerifier` answers `:not_granted` for, and
  # this serves that key's message FROM `InstallationRepositories::MESSAGES` rather than writing a
  # second sentence beside it. A person who reads this refusal and a person who reads the POST's
  # are told the same thing and pointed at the same fix.
  def registrable
    grant = current_api_user.github_registration_grant

    return render_not_granted(grant) if grant.nil? || grant.stale?

    render json: {
      grant: grant_state(grant),
      repositories: registrable_entries(grant)
    }
  end

  # `current_api_user.repositories.new` rather than `Repository.new(user: …)`: ownership is set from
  # the CREDENTIAL and is not a field of the request, so there is no parameter a caller could send
  # that would register something under somebody else's account.
  #
  # ## `created_by_user`: the half of the parity with `ApiKeysController` that has no second chance
  #
  # `add_created_by_user_to_api_keys` says why: `ApiKeysController#destroy` is a hard `destroy!` with
  # no audit row, so attribution is not backfillable after the fact — a key minted NULL is NULL
  # forever. There is nothing to infer from either: this request KNOWS who minted the key, because
  # the person the `sgu_` key speaks for is the only reason the registration was permitted at all,
  # and the roadmap's own non-goal is that the key's reach is the person's reach. Leaving it blank
  # would render a false sentence — `repositories/_api_keys` shows "Unknown" for a creator that was
  # never recorded or has been deleted, and neither is true of a key a person minted a second ago —
  # and would silently undercount `MembershipsController#keys_minted_by`, the query behind the
  # warning shown when that person's access is revoked.
  #
  # ## One transaction, because the response promises both
  #
  # A repository that reached the database without its key leaves the caller holding a registration
  # they cannot deliver to and cannot re-register — the retry is refused with `has already been
  # taken` — and no API path out of it, since minting a key over the API is a slice that has not
  # shipped. The failure is remote (`name` is a constant and `token_digest` collisions are not a real
  # event), but rolling back is recoverable and half-registering is not.
  def create
    repository = current_api_user.repositories.new(github_full_name: create_params[:github_full_name])
    registration = RepositoryRegistration.new(repository: repository, verifier: grant_verifier)
    api_key = nil

    registered = ActiveRecord::Base.transaction do
      # `next false` rather than a raise: a refused registration has written nothing to roll back,
      # and the response it deserves is a 400 rather than the 500 an exception would become.
      next false unless registration.save

      api_key = repository.api_keys.create!(name: FIRST_KEY_NAME, created_by_user: current_api_user)
      true
    end

    # A refusal is a refusal whether it came from the record's own rules (not `org/repo`, already
    # registered) or from the ownership gate, and both have already been recorded on the record as
    # errors — so there is one response path rather than a branch that has to know which happened.
    return render_bad_request(repository.errors.full_messages) unless registered

    render json: registered_body(repository, api_key), status: :created
  end

  private

  # Top-level rather than nested under a `repository` key. This is a JSON API being driven by an
  # agent, not a Rails form being submitted by a browser, and `{"github_full_name": "org/repo"}` is
  # what a caller writing curl by hand will send.
  def create_params
    params.permit(:github_full_name)
  end

  # The two states that redeem nothing, answered with the WRITE GATE'S OWN SENTENCE — read from
  # `InstallationRepositories::MESSAGES`, never re-typed. `GrantVerifier#verdict_for` refuses on
  # exactly this condition (`@grant.nil? || @grant.stale?`) and lands on exactly this key, so the
  # reading and the write cannot tell a caller two different stories about the same account.
  #
  # 403 rather than 400: nothing is wrong with the REQUEST — it is well-formed and the credential
  # is valid — and nothing the caller can put in it would help. What is missing is a grant, and the
  # fix is somewhere this request cannot reach. `render_bad_request` would say the opposite, and
  # would send an agent looking for a parameter it got wrong.
  #
  # `grant` is passed rather than re-read, and a stale one still reports its `captured_at` and
  # `expires_at`: "your access lapsed four days ago" is a different fact from "you never had any",
  # both are actionable, and a bare refusal collapses them. `grant` is `null` for the second.
  def render_not_granted(grant)
    render json: {
      error: "not_granted",
      # The subject in front of it is this surface's, matching what `GithubRepositoryListing#
      # github_listing_error_message` does with the same hash: the MESSAGES entries are written as
      # predicates about a repository ("cannot be registered from an API key — …"), so a reading
      # about a whole account has to supply a subject. The SENTENCE is still the constant's.
      message: "Your repositories #{InstallationRepositories::MESSAGES.fetch(:not_granted)}",
      grant: grant && grant_state(grant)
    }, status: :forbidden
  end

  # How old the recording is and when it stops redeeming — the three facts that are currently
  # knowable nowhere. `expires_at` is DERIVED from the same `MAX_AGE` `stale?` divides on rather
  # than restated as a literal, so the number cannot drift from the bound it describes.
  #
  # `stale` is served even though a stale grant reaches this method only through
  # `#render_not_granted` (where it is always `true`): it is the field a client branches on, and a
  # block whose meaning depended on which response carried it would be a worse contract than one
  # scalar that is simply true or false wherever it appears.
  #
  # Both stamps are `&.`-guarded on the same column. `captured_at` is `NOT NULL` and validated, so
  # a persisted grant always carries one — but `stale?` nevertheless answers a nil one rather than
  # raising ("I cannot tell how old this is" reads as "too old"), and a serializer that raised on
  # the state its own `stale` field reports would turn that deliberate answer into a 500.
  def grant_state(grant)
    {
      captured_at: grant.captured_at&.iso8601,
      expires_at: grant.captured_at&.then { |at| (at + GithubRegistrationGrant::MAX_AGE).iso8601 },
      stale: grant.stale?
    }
  end

  # Every name GitHub said this person ADMINISTERS, each marked with whether SpecGuard already holds
  # it. `visible_full_names` is deliberately NOT served: it grants nothing, it exists only to decide
  # which refusal is true (see `GrantVerifier`), and a caller reading a list it cannot register from
  # would be reading a picker that offers what the write refuses.
  #
  # MARKED rather than EXCLUDED. An already-registered name is the answer to "why did my POST say
  # `has already been taken`", and dropping it from the list would make that state indistinguishable
  # from having lost admin — two different facts with two different fixes.
  #
  # One `IN` over the whole list rather than a lookup per name: the same batched shape
  # `BulkRegistration` uses, and for the same reason it gives — `LOWER(...)` because the grant
  # stores names downcased while `repositories.github_full_name` preserves the case it was
  # registered under, and the uniqueness rule the POST enforces is itself case-insensitive.
  #
  # Sorted, matching `#index`'s ordering rule: `github_full_name` is the only column on this list a
  # client could page or diff against.
  def registrable_entries(grant)
    names = grant.registrable_full_names.to_a
    registered = registered_names_among(names)

    names.sort.map { |name| { full_name: name, registered: registered.include?(name) } }
  end

  # WHICH of these names SpecGuard already holds, downcased for comparison against the grant's own
  # downcased set. Asked of `Repository` globally rather than of `accessible_by(current_api_user)`,
  # and the difference is load-bearing: a repository somebody ELSE registered still refuses this
  # person's POST with `has already been taken`, so a reading scoped to what they can open would
  # mark it `registered: false` and send them at a name that cannot be registered by anyone.
  #
  # That discloses no repository: every name in this set came from GitHub's answer about THIS
  # person's own administrative access, so the response says nothing they could not already read on
  # github.com. Nothing else about such a repository is served — no id, no owner, no `name` — only
  # the fact that the name is taken.
  #
  # A Set rather than an Array so the `include?` in the map above is a hash lookup per entry rather
  # than a scan of the whole list.
  def registered_names_among(names)
    return Set.new if names.empty?

    Repository.where("LOWER(repositories.github_full_name) IN (?)", names.map(&:downcase))
              .pluck(:github_full_name).map(&:downcase).to_set
  end

  # The evidence this request can offer, which is a recording rather than a live answer. `nil` is an
  # ordinary state and not an error: it is every person who has not opened SpecGuard in a browser
  # since this shipped, and `GrantVerifier` refuses on it with a sentence naming the fix.
  #
  # Through the association rather than `GithubRegistrationGrant.find_by(user_id: …)`, which is the
  # same query written the long way — `User has_one :github_registration_grant` is what makes "one
  # grant per person" a fact of the schema rather than a convention each caller re-states.
  def grant_verifier
    RepositoryRegistration::GrantVerifier.new(grant: current_api_user.github_registration_grant)
  end

  # `repository` is deliberately the same four fields `#index` and `Api::V1::RepositoriesController`
  # serve, so a client that has read either knows how to read this. `api_key` is NOT the same block
  # `GET /api/v1/repository` serves — that one reports on a key the caller already holds and could
  # not reveal it if it wanted to. This one carries `token`, once.
  def registered_body(repository, api_key)
    {
      repository: {
        id: repository.id,
        full_name: repository.github_full_name,
        name: repository.name,
        registered_at: repository.created_at.iso8601
      },
      api_key: {
        name: api_key.name,
        # ⚠️ THE ONLY TIME THIS VALUE EXISTS ANYWHERE. Nothing stores it and no endpoint can
        # re-serve it; a caller that loses it mints a replacement.
        token: api_key.raw_token,
        hint: api_key.token_hint,
        created_at: api_key.created_at.iso8601
      }
    }
  end

  # Deliberately the same four fields, under the same names, that `Api::V1::RepositoriesController`
  # serves in its own `repository` block. A client that has read one of them knows how to read the
  # other, and the two cannot drift into naming the same facts differently.
  #
  # `role` is the one field this surface adds, and it earns its place: the list mixes repositories
  # the person owns with repositories somebody shared with them, and no other field distinguishes
  # them. Without it a client cannot tell which of these it may expect to administer once the
  # mutating endpoints land, and would have to guess.
  #
  # `delivery_health` is handed IN rather than looked up, because this method has one repository and
  # the reads behind that block are grouped over the whole list — see `#delivery_verdicts`.
  def serialize(repository, delivery_health)
    {
      id: repository.id,
      full_name: repository.github_full_name,
      name: repository.name,
      registered_at: repository.created_at.iso8601,
      role: repository.user_id == current_api_user.id ? "owner" : "member",
      delivery_health: delivery_health
    }
  end

  # WHETHER EACH LISTED REPOSITORY'S DELIVERIES ARE BEING REFUSED — `repository_id =>` the same two
  # scalars `Api::V1::RepositoriesController` serves under `delivery_health` on the singular
  # endpoint, for every repository in the list, in two queries however long the list is.
  #
  # ## Why this list needs it at all
  #
  # The two credentials are disjoint (`config/routes.rb`): this endpoint takes a `sgu_` user key and
  # `GET /api/v1/repository` takes a `sgk_` repository key, and each refuses the other's with a 401.
  # So the singular endpoint is not a fallback an agent reading this list can reach for — that would
  # need N separate repository keys held at once, and a `role: "member"` entry may hold none and
  # have no way to mint one. The browser's card grid has badged a refused pipeline since SPGD-820;
  # without this block the same account renders one way to a person and another to an agent, and the
  # agent reads an ordinary-looking repository whose every run has been thrown away for a week.
  #
  # ## Served on EVERY entry, refused and clean alike
  #
  # `refusing: false` is a POSITIVE FINDING and an absent key would read as "SpecGuard does not
  # track that", which is a different fact. That is the sibling endpoint's own stated rule for the
  # same block (`repositories_controller.rb`: a repository with no accepted run "is not the empty
  # case, it is the worst case"), and it is restated here rather than re-decided.
  #
  # ## The verdict is asked for, never re-spelled
  #
  # `RejectedIngests.verdict` is the row-free way in, built for exactly a caller like this one, and
  # the comparison stays inside it: `rejected_ingests.rb` forbids a second inline expression of the
  # ordering rule, and the rule has two `nil` limbs that do not both fall out of a bare `>` — a
  # `nil` rejection is not refusing, and a `nil` accepted side WITH a rejection present is the most
  # refusing state there is, which inverts. So there is no timestamp comparison anywhere in this
  # controller.
  #
  # ## What is deliberately NOT here
  #
  # The verdict scalars and nothing else — no `rejections` array, no `rejections_window`, no
  # `bounded`. Fanning up to `IngestRejection::PANEL_LIMIT` rejection rows, each with up to twenty
  # reasons and a ~6 KB `details` column, across every repository in an unpaginated list is the
  # wrong cost on the wrong surface. It is the same line the browser grid drew for itself: the card
  # renders the marker and not the panel, because the thing it links to holds the panel.
  #
  # Key names are borrowed verbatim from `serialized_delivery_health`, on the rule `#serialize`
  # states above — the two surfaces do not get to name the same facts differently — and the
  # timestamp is serialized `&.iso8601` to match, `nil` when there has never been a rejection.
  def delivery_verdicts(repositories)
    repository_ids = repositories.map(&:id)
    last_rejections = last_rejection_times_for(repository_ids)
    latest_runs = latest_test_runs_for(repository_ids)

    repository_ids.index_with do |repository_id|
      verdict = RejectedIngests.verdict(last_rejection_at: last_rejections[repository_id],
                                        last_accepted_run_at: latest_runs[repository_id]&.created_at)

      { refusing: verdict.refusing?, last_rejection_at: verdict.last_rejection_at&.iso8601 }
    end
  end
end
