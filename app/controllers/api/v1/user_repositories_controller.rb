# frozen_string_literal: true

# WHICH REPOSITORIES THE CREDENTIAL BEHIND THIS TOKEN MAY OPEN — the first endpoint that answered
# to a `sgu_` user key, and since SPGD-952 also to an `sga_` agent key.
#
# ## Why this is not an action on `Api::V1::RepositoriesController`
#
# That controller serves `GET /api/v1/repository`, singular, which answers to a `sgk_` repository
# key and is a report about the ONE repository that key names. This answers to different
# credentials and returns a set. Two surfaces that share a noun and nothing else — the singular
# route's credential is not accepted here and vice versa, so the near-identical paths cannot
# quietly serve the wrong thing. (For a while the seam could not express two accepted credentials
# on one controller, and this header said so; SPGD-952 widened it — `accepts_user_credential` and
# `accepts_agent_credential` read together below — which changed what the seam CAN say, not the
# reason this is a separate controller from the singular one.)
#
# ## What the two accepted credentials mean here
#
# A `sgu_` key speaks for a PERSON, and this surface lists what that person may open. An `sga_`
# key speaks for NOBODY: it lists the set granted onto the key at mint time, and can read one of
# those repositories in full — but every action that must act AS the person (register, rename,
# delete; `#registrable`'s grant reading) refuses it with a 403. See `Api::BaseController` for
# `authorized_repositories`, the one read boundary both credentials resolve through, and
# `require_person_credential` for the guard the person-only actions declare.
#
# ## The authorization rule is not reinvented here
#
# `Repository.accessible_by` is this application's read-side boundary for a PERSON — owned UNION
# shared-through-a-membership — and it lives on the model so that every surface asking "which
# repositories may this person see" asks the same place. The dashboard's repository list reads it;
# so does this for a `sgu_` key. For an `sga_` key the boundary is the key's own repository set
# (`AgentApiKey#repositories`), never `accessible_by` of anybody — a repository outside either
# boundary is not filtered out of these responses, it never enters them, so nothing here can leak
# the fact that it exists.
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

  # THE THREE SHARD SCALARS `latest_run.shards` serves on every entry, primed for the whole list in
  # ONE grouped aggregate — the same include the card grid and the `history` block already reach
  # for (`ShardCountPreloading`'s "ONE MODULE, TWO BASES" precedent). Without it, every entry that
  # asks `TestRun#shard_count`, `#timed_shard_count` or `#machine_seconds` pays one memoized `pick`
  # per row, and an unpaginated list is exactly the window that N+1 ships green on: a fixture with
  # one repository cannot see it at all. Primed in `#index` right after the runs are resolved, so
  # the aggregate is taken only when the runs were, and an account with no repositories pays
  # nothing for either.
  include ShardCountPreloading

  # THE THREE NARROWING ASKS the web repositories index already reads — `?q=`, `?role=owned|shared`,
  # `?sort=stale` — under the SAME guards the card grid reads them AND through the SAME application
  # of them. The web shipped them first (`repositories_controller.rb`, the SPGD-802 block) because
  # one `BulkRegistration::MAX_BATCH` gesture puts a hundred repositories on an account; this
  # endpoint serves the identical `Repository.accessible_by` population, UNPAGINATED, and read no
  # parameter at all — so the same hundred-repo body rode every agent call in full, and every
  # narrowing ask re-paid it.
  #
  # Including rather than re-deriving is the whole point, and it covers the RULE and not merely the
  # reads: sharing `RepositoryNarrowing` is what makes a shape the web clamps to no-ask IMPOSSIBLE
  # to answer differently here, and what makes the order this list serves under `?sort=stale`
  # impossible to drift from the order the card grid draws. See the module for why the application
  # is shared and not just the parameter guards.
  include RepositoryNarrowing

  # THIS ENDPOINT NEEDS A PERSON — or an agent credential bounded by its own grants. A `sgk_`
  # repository key resolves no user and gets 401 — which is the direction of the seam that is easy
  # to get wrong, because a repository key IS a valid credential and this list would otherwise have
  # to invent an answer for one. See `Api::BaseController`.
  #
  # The `sga_` agent credential is accepted for the READS only, and every action that must act AS
  # the person guards itself below: the agent credential carries its own repository set and
  # permission set (never a person's), so `#create`/`#registrable`/`#update`/`#destroy` — which
  # redeem the person's GitHub grant or hold the person's owner rights — refuse it with a 403
  # rather than crash on a nil `current_api_user` or, worse, half-apply a person-shaped rule to a
  # credential that is not one.
  accepts_user_credential
  accepts_agent_credential

  before_action :require_person_credential, only: %i[create registrable update destroy]

  # The name every first key gets. Deliberately the same string `ApiKeysController` defaults to, so
  # a repository registered by an agent and one registered in a browser have identically-named keys
  # rather than two conventions a person has to learn.
  #
  # The naming is only half of that parity — see `#create` for the other half, which is the one that
  # cannot be repaired later if it is skipped.
  #
  # It reads `ApiKey::DEFAULT_NAME` rather than repeating the literal, because there is now a THIRD
  # caller minting an unnamed first key — `BulkRegistration`, registering a whole organization from
  # the browser — and the parity this constant exists to state is only true while all three say the
  # same thing. Kept as a named constant here rather than inlined at its call site: the sentence
  # above is about this endpoint's contract, and the alias is where a reader of this file looks.
  FIRST_KEY_NAME = ApiKey::DEFAULT_NAME

  # The omission marker for `#serialize`'s third argument — see that method for why an omitted
  # `latest_run` must leave the key ABSENT rather than present-and-null. A one-off frozen object
  # compared by `equal?`, so no serialized value can ever collide with it; not a Symbol, which a
  # future key could echo, and not `nil`, which is a REAL answer here ("CI has never reported").
  NO_LATEST_RUN_BLOCK = Object.new.freeze

  # The delivery verdicts are resolved ONCE for the whole response and threaded into `#serialize`,
  # which takes one repository and has no access to the collection. Resolving them per entry would
  # be the N+1 `RejectedIngests.verdict` exists to avoid — two aggregates per listed repository
  # instead of two for the list.
  #
  # `latest_run` is threaded for the same reason, and its two reads are grouped the same way:
  # `#index` resolves the `latest_test_runs_for` map once, here, and threads it into both
  # consumers, `#delivery_verdicts` and the serialized `latest_run` block (ONE `DISTINCT ON` for
  # the whole list, on `Repository#latest_test_run`'s exact tie-break, so a list entry and the
  # detail page it links to cannot name different runs), and the shard scalars each entry serves
  # are primed from ONE grouped aggregate. Adding a repository to the account therefore adds no
  # query to this endpoint — the property the budget example in `user_repositories_spec.rb` pins
  # at one row and at several.
  #
  # `?q=`, `?role=` and `?sort=stale` compose onto the same relation in the web index's exact
  # order — `credential boundary → ?q= → ?role= → order(:github_full_name) → ?sort=stale` — through
  # `RepositoryNarrowing`, the module that also applies them for the card grid. The boundary is
  # `authorized_repositories`: `Repository.accessible_by` of the person under a `sgu_` key, the
  # key's own mint-time-fixed set under `sga_` — so a repository outside whichever boundary applies
  # never enters the relation the asks chain onto. The reasoning for
  # each (the chain that is a security claim, the `sanitize_sql_like` escape, the complement that
  # makes the two roles partition exactly, and the loaded-set sort that re-derives nothing) lives
  # there, in one copy, so this endpoint and the grid cannot answer the same account differently.
  #
  # What is this action's own is WHERE the sort sits: `?sort=stale` runs against the
  # `latest_test_runs_for` map already resolved here for `delivery_health` and `latest_run`, so
  # the ordering costs no query at all. It also runs BEFORE `#delivery_verdicts`, which is safe
  # because that method returns an id-keyed hash (`repository_ids.index_with`) and is therefore
  # order-independent — reordering the list cannot desynchronise a verdict from its entry.
  #
  # An unparameterised request composes none of the three and serves the body this action has
  # always served — every parameter here narrows, partitions or reorders; none adds a key.
  def index
    scope = narrow_repositories(authorized_repositories, current_api_user)
    repositories = scope.order(:github_full_name).to_a
    latest_runs = latest_test_runs_for(repositories.map(&:id))
    preload_shard_counts(latest_runs.values)
    repositories = stale_first(repositories, latest_runs) if requested_sort == "stale"
    verdicts = delivery_verdicts(repositories, latest_runs: latest_runs)

    render json: {
      repositories: repositories.map do |repository|
        serialize(repository, verdicts[repository.id],
                  LatestRunSerializer.new(latest_runs[repository.id],
                                          depth: LatestRunSerializer::LIST_DEPTH).body)
      end
    }
  end

  # ONE REPOSITORY, IN FULL — the same overview `GET /api/v1/repository` serves an `sgk_` caller,
  # for a repository this PERSON may open, named by id rather than by a credential.
  #
  # ## Why the body is not written here
  #
  # It is `RepositoryOverview`'s, and that object is handed a repository and the ask. Reproducing
  # sixty serializers on this side would be two bodies for one contract, drifting the first time
  # either was touched — the failure this endpoint's own `#serialize` calls out for a four-field
  # block, at fifty times the surface. The singular route renders the same object, so the two
  # cannot come to describe the same repository differently.
  #
  # ## `api_key` is ABSENT here, not null
  #
  # That block describes the credential that made the request. This request was made with a USER
  # key, which is not a repository key and has no `last_used_at` or `rotated_at` to report; and the
  # repository's own `sgk_` keys are not the caller's to describe. A block of nulls would be a
  # sentence about a credential that does not exist, so the key is simply not served — see
  # `RepositoryOverview#body`, which takes the block from the caller that has one.
  #
  # `credential_health` DOES answer, and is arguably worth more here than on the singular route: it
  # reports on the repository's keys as a SET, which under a user key is a set the caller holds none
  # of and could not otherwise ask about (an `sgk_` key is reveal-once and unrecoverable).
  #
  # ## The read boundary is the credential's, and there is no policy object in this action
  #
  # `authorized_repositories` (see `Api::BaseController`) is the read boundary of WHICHEVER
  # credential made the request: for a `sgu_` key it is `Repository.accessible_by(person)` — owned
  # UNION shared-through-a-membership — and for an `sga_` agent key it is the key's own
  # mint-time-fixed repository set. `#index` above serves the same relation; a repository outside
  # the boundary does not enter this query, so there is nothing here that could leak one.
  #
  # ⭐ NIL IS 404, NEVER 403, and the two cases are deliberately indistinguishable. A repository
  # the credential cannot open and a repository that was never registered arrive here identically —
  # as `nil` from a scoped `find_by` — and separating them would mean asking a second, UNSCOPED
  # question for the sole purpose of telling a caller that something they may not see nevertheless
  # exists. That turns id enumeration into a census of the platform.
  # `Api::BaseController#render_not_found` carries the same argument at the surface it is rendered
  # from.
  #
  # `find_by` rather than `find`: a `RecordNotFound` from an `ActionController::API` with no rescue
  # registered is a 500, and "no such id" is an ordinary answer rather than an exception. It also
  # makes criterion 4 fall out for free — a malformed id (`"abc"`, `"9' OR 1=1"`) casts to no
  # integer, matches no row and lands on the same 404, with no raise and no special-casing.
  def show
    repository = authorized_repositories.find_by(id: params[:id])

    return render_not_found("No repository with that id is available to this key.") if repository.nil?

    render json: RepositoryOverview.new(repository: repository, params: params).body
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
  # `add_created_by_user_to_api_keys` says why: attribution recorded at mint time is the only
  # attribution a row will ever carry — it is not backfillable after the fact. (`ApiKeysController#destroy`
  # has been a retirement rather than a hard `destroy!` since SPGD-804, so a revoked key's row and
  # its `created_by_user` both survive; that makes durable attribution MORE true, not less.) There
  # is nothing to infer from either: this request KNOWS who minted the key, because
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

  # REMOVING ONE OF THEM — the mutating counterpart of `#show`, on the same credential. The
  # authorization is `RepositoryAuthorization`'s fork at `:repo_delete` — deliberately NOT
  # `:owner`, exactly as the web `RepositoriesController#destroy` resolves, because the two are
  # one implementation now and a member granted `repo.delete` may remove a repository from either
  # surface.
  #
  # No GitHub round trip and no notice to compose: the web action builds its flash sentence BEFORE
  # the row goes away only because a destroyed record cannot be asked for its associations, and a
  # JSON body has no such dependency — there is nothing to say about a repository except that it
  # is gone, and the caller named it.
  #
  # `204` rather than a body: the resource the URL named no longer exists, so there is nothing to
  # describe and no `message` a client could act on. This is the one response in the `sgu_`
  # surface that is deliberately NOT a JSON body, and it matches what DELETE means everywhere else
  # in this API's vocabulary (`UserRepositoryApiKeysController#destroy` follows it).
  def destroy
    repository = current_repository(:repo_delete)

    repository.destroy!

    head :no_content
  end

  # RENAMING ONE — the owner-only verb the `sgu_` surface was missing, through the SAME
  # grant-backed gate `#create` redeems. `RepositoryRegistration` with the recorded
  # `GithubRegistrationGrant` makes rename exactly as session-free as registration: the grant is
  # what GitHub said about this person while a browser still held a token, and a new name is a
  # registration question in every respect but the row's age.
  #
  # Owner-only through `RepositoryAuthorization`, the same asymmetry as the web `#update`: a member
  # granted `repo.delete` may DESTROY from this surface but only the OWNER renames —
  # `github_full_name` is both the repository's identity and the globally unique key, so no
  # membership permission grants it. Non-member → 404 (nil is 404, never 403 — see `#show`),
  # non-owner member → 403.
  #
  # Renaming is pure metadata: api_keys, test_runs and spec_intents are keyed by repository_id, so
  # none are touched. That is the whole point — the alternative (remove + re-register) destroys
  # every key and all telemetry.
  #
  # Refusals funnel through `render_bad_request(repository.errors.full_messages)` exactly as
  # `#create` does, so the gate's own sentences are served: name absent from the grant →
  # `:not_in_installation`; visible-but-not-administered → `:not_administered`; taken → "has
  # already been taken". A nil or stale grant is the 403 `#registrable` owns, with the
  # `:not_granted` sentence naming the browser-and-seven-days fix — 403 rather than 400 because
  # nothing in the REQUEST can help (see `render_not_granted`).
  def update
    repository = current_repository(:owner)

    grant = current_api_user.github_registration_grant
    return render_not_granted(grant) if grant.nil? || grant.stale?

    repository.assign_attributes(update_params)
    registration = RepositoryRegistration.new(repository: repository, verifier: grant_verifier)

    return render_bad_request(repository.errors.full_messages) unless registration.save

    # The same five identity fields `#index` serves, so a client that has read the list knows how
    # to read this — including `delivery_health`, which is not null here for the reason `#index`
    # gives: `refusing: false` is a positive finding and an absent key would read as "SpecGuard
    # does not track that".
    # `delivery_verdicts` is the one spelling of this expression the file owns — its own comment
    # says the verdict is never re-spelled and that key names are borrowed from
    # `serialized_delivery_health` precisely so surfaces do not name the same facts differently.
    # A single-element input costs nothing extra (the batched helpers already take an array).
    delivery_health = delivery_verdicts([repository])[repository.id]

    render json: { repository: serialize(repository, delivery_health) }, status: :ok
  end

  private

  # Top-level rather than nested under a `repository` key. This is a JSON API being driven by an
  # agent, not a Rails form being submitted by a browser, and `{"github_full_name": "org/repo"}` is
  # what a caller writing curl by hand will send.
  def create_params
    params.permit(:github_full_name)
  end

  # Same shape and same reason as `create_params`: a top-level `{"github_full_name": "org/repo"}`,
  # which is what an agent writing curl by hand sends. The web nests under `repository:` because a
  # form does; this API does not.
  def update_params
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
  # Both stamps are read UNGUARDED, and that is a statement about the column rather than an
  # oversight: `captured_at` is `NOT NULL` in the schema AND validated for presence, and this
  # method is only ever reached with a grant loaded from the database. It cannot be nil here. A
  # `&.` would read to the next maintainer as "this can be nil" — the opposite of the truth — and
  # would buy a shape (`captured_at: null, expires_at: null, stale: true`) that no client is told
  # to expect and no example asserts. `GithubRegistrationGrant#stale?` does answer a nil one, but
  # that is for the UNSAVED row it documents, which never reaches a serializer.
  def grant_state(grant)
    {
      captured_at: grant.captured_at.iso8601,
      expires_at: (grant.captured_at + GithubRegistrationGrant::MAX_AGE).iso8601,
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

  # Deliberately the same identity fields, under the same names, that
  # `Api::V1::RepositoriesController` serves in its own `repository` block. A client that has read
  # one of them knows how to read the other, and the two cannot drift into naming the same facts
  # differently.
  #
  # `role` is the one field this surface adds, and it earns its place: the list mixes repositories
  # the person owns with repositories somebody shared with them, and no other field distinguishes
  # them. Without it a client cannot tell which of these it may expect to administer once the
  # mutating endpoints land, and would have to guess.
  #
  # For an `sga_` agent credential every entry is delegated the same way — the key is not a person,
  # so "owner" and "member" are both answers to a question that was not asked — and the honest
  # value is the one that says so: `agent`. A client branching on owner/member reads `false` for
  # both, which is correct; a client that wants to know WHOSE rights these are reads the minting
  # owner off the account page, because the API does not serve it here.
  #
  # `delivery_health` is handed IN rather than looked up, because this method has one repository and
  # the reads behind that block are grouped over the whole list — see `#delivery_verdicts`. So is
  # `latest_run`: the block is `LatestRunSerializer`'s at LIST depth, and both its inputs — which
  # run, and the primed shard scalars — are resolved once for the whole list in `#index`.
  #
  # ⭐ `latest_run` IS AN INSERTION AT A POSITION, NOT A FLAG — the same shape
  # `RepositoryOverview#body` gives `api_key_block:`. `#index` hands it in and the key is served on
  # every entry, `nil` for a repository CI has never reported to (a different fact from a zeroed
  # block, and the serializer's own rule). `#update` omits it and the key is genuinely ABSENT from
  # that response rather than present-and-null: a rename receipt saying `latest_run: null` about a
  # repository that HAS runs would assert "CI has never reported" about the one thing the endpoint
  # knows was untouched by the rename. A real `nil` and an omitted block cannot share a default, so
  # the marker is a distinct object compared by identity, never a value a run could serialize to.
  def serialize(repository, delivery_health, latest_run = NO_LATEST_RUN_BLOCK)
    {
      id: repository.id,
      full_name: repository.github_full_name,
      name: repository.name,
      registered_at: repository.created_at.iso8601,
      role: credential_role(repository),
      delivery_health: delivery_health,
      **(latest_run.equal?(NO_LATEST_RUN_BLOCK) ? {} : { latest_run: latest_run })
    }
  end

  # Which side of the owner/member line this entry sits on — or, under the agent credential, that
  # the question does not apply. See `#serialize`.
  def credential_role(repository)
    return "agent" if @current_api_key.is_a?(AgentApiKey)

    repository.user_id == current_api_user.id ? "owner" : "member"
  end

  # THE `?role=` ASK UNDER THE AGENT CREDENTIAL. The ownership ask partitions by WHO OWNS each
  # repository — a PERSON fact (`?role=owned` is `user_id = viewer.id` inside
  # `RepositoryNarrowing`) — and under the `sga_` credential there is no person in the request:
  # every entry serves `role: "agent"` (see `#credential_role`), so there is no owned/shared line
  # to draw, and dereferencing `current_api_user.id` would be a 500 on an otherwise valid read.
  # The ask therefore clamps to the module's own no-ask, the same answer an absent or
  # out-of-vocabulary value already gets. The clamp lives HERE rather than in the shared module
  # because a person viewer is that module's contract — the web grid and the `sgu_` path always
  # have one — and this controller is the one surface that can hold the request without one;
  # widening the module for a caller it never sees would put an API-only `nil` branch inside a
  # rule both surfaces read. `super` keeps the guard's own clamp intact: non-String shapes,
  # blanks and unknown values answer no-ask before this question is even asked.
  def requested_role
    return nil if @current_api_key.is_a?(AgentApiKey)

    super
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
  #
  # `latest_runs:` hands in the newest-run-per-repository read a caller has ALREADY taken. `#index`
  # resolves it once because the `latest_run` block needs the RUN and not only its timestamp; a
  # second resolution inside here would be the same `DISTINCT ON` issued twice per request. The
  # keyword is optional rather than required because `#update` wants only the verdict — its
  # response carries no run block — and resolving one repository's newest run is exactly what this
  # method did before the block existed on any list.
  def delivery_verdicts(repositories, latest_runs: nil)
    repository_ids = repositories.map(&:id)
    last_rejections = last_rejection_times_for(repository_ids)
    latest_runs ||= latest_test_runs_for(repository_ids)

    repository_ids.index_with do |repository_id|
      verdict = RejectedIngests.verdict(last_rejection_at: last_rejections[repository_id],
                                        last_accepted_run_at: latest_runs[repository_id]&.created_at)

      { refusing: verdict.refusing?, last_rejection_at: verdict.last_rejection_at&.iso8601 }
    end
  end
end
