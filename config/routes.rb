Rails.application.routes.draw do
  root "pages#home"

  # The public integration guide (SPGD-705). Deliberately outside every authentication gate, and
  # that is the requirement rather than an oversight: its intended reader is as often an AI coding
  # agent handed nothing but this URL as it is a person, and such an agent has no session and
  # cannot acquire one. It documents the two CI-facing `api/v1` routes declared below — the ones a
  # repository's own `sgk_` key answers — and promises nothing beyond them, so there is nothing on
  # it a signed-out reader must not see.
  #
  # `/docs/…` rather than a bare `/integrate` so the next document has an obvious home; the named
  # helper is `integration_guide_path`, which is what the repository page's agent-prompt block
  # builds its URL from — the prompt is only correct because it points at this page, so the two
  # must not be able to drift apart through a hand-written string.
  get "docs/integrate", to: "pages#integrate", as: :integration_guide

  # --- Human auth: GitHub OAuth -------------------------------------------------
  # Identity only. This asks GitHub for a handle, an avatar and an email address, and has never
  # asked for more — repository access is a separate thing entirely, below.
  post  "/auth/github",          to: "sessions#passthru", as: :github_auth
  get   "/auth/github/callback", to: "sessions#create"
  post  "/auth/github/callback", to: "sessions#create"
  get   "/auth/failure",         to: "sessions#failure"
  delete "/sign_out",            to: "sessions#destroy", as: :sign_out

  # --- Repository access: GitHub App installation --------------------------------
  # Connecting repositories is installing the SpecGuard GitHub App on them and picking them in
  # GitHub's own picker. POST going out (CSRF-protected, so nobody else can start the flow for a
  # signed-in user); GET coming back, because GitHub redirects a browser to it.
  #
  # `authorize` is the smaller of the two ways out: it asks GitHub only for a credential that speaks
  # for the signed-in user, which every session needs before it can read anything and which a user
  # who has already authorized the App is granted without seeing a screen. It is what the reconnect
  # button posts to, and it exists so that needing a credential does not walk somebody through the
  # repository picker again.
  #
  # The callback path is configured on the App itself on github.com — as BOTH its callback URL and
  # its setup URL, which is why one action serves both journeys. Renaming it here without changing
  # it there sends every returning user to a 404 with no error anywhere.
  post "/github/installation",           to: "github_installations#create",    as: :github_installation
  post "/github/installation/authorize", to: "github_installations#authorize",
                                         as: :github_installation_authorize
  get  "/github/installation/callback",  to: "github_installations#callback",
                                         as: :github_installation_callback

  # Dropping SpecGuard's record of one connected account, from `/account`. The only one of the four
  # that talks to nobody: `create` and `authorize` send the user to github.com and `callback` reads
  # what GitHub answered, while this deletes a row we wrote and stops there.
  #
  # DELETE on a member path, so the id is a path segment rather than a query parameter and Rails'
  # CSRF check applies — the same shape the account key's own Revoke takes. The id is scoped through
  # `current_user.github_installations` in the action, so one typed into the URL bar reaches nobody
  # else's row.
  delete "/github/installation/:id", to: "github_installations#destroy",
                                     as: :github_installation_disconnect

  # --- Dashboard ----------------------------------------------------------------
  resources :repositories, only: %i[index new create show edit update destroy] do
    # Registering a whole GitHub organization at once (SPGD-355). A COLLECTION route deliberately:
    # `/repositories/bulk` sits in the same path space as `/repositories/:id`, and Rails emits
    # collection routes ahead of member ones, so the literal segment cannot be swallowed as an id.
    # Declaring it as a sibling `resource` outside this block would depend on file ordering to stay
    # correct, which is not a property to rest a route on.
    #
    # Both verbs answer at one path: the GET chooses (an organization, then its repositories, via
    # `?organization=`), the POST performs. One name — `bulk_repositories_path` — for both, because
    # the form posts back to the page it was rendered from.
    collection do
      get "bulk", to: "bulk_registrations#new", as: :bulk
      post "bulk", to: "bulk_registrations#create"
    end

    resources :api_keys, only: %i[create destroy] do
      # A member POST, not a second collection `create`: rotation changes an existing key in place
      # and the route has to name which one. See ApiKeysController#regenerate.
      post :regenerate, on: :member
    end
    # `/repositories/:repository_id/members` reads as the thing it lists (people), while the
    # controller is named for the row it actually manipulates (RepositoryMembership). `edit`
    # /`update` change a member's permission set in place: the alternative is Revoke + re-add,
    # which fires a consequence dialog about surviving API keys for an operation that is not a
    # removal, and resets the "Since" column so a narrowed colleague reads as a brand-new one.
    resources :members, only: %i[index new create edit update destroy], controller: "memberships"

    # Deleting one run from the "Recent runs" panel (SPGD-812). A member route with only `destroy`,
    # the same shape `api_keys` above uses: the id is a path segment so Rails' CSRF check applies,
    # and the action scopes the lookup through the repository, so a run id belonging to another
    # repository resolves to nobody's row.
    #
    # Gated at `:repo_delete` in the action, not at a per-run permission: a run is not a
    # separately-shareable object, it is repository history, and the price of removing one is
    # bounded above by the price of removing the repository (RepositoriesController#destroy gates
    # the same capability for the whole cascade).
    resources :runs, only: %i[destroy]
  end

  # --- Account: what belongs to the person rather than to a repository ------------
  # The first top-level surface that is not about one repository. `sgu_` user keys authenticate AS
  # the person across everything they may open (see `UserApiKey`), so there is no repository to hang
  # them off and `/repositories/:id/api_keys` would be the wrong address in a way that quietly
  # misdescribes the credential.
  #
  # Singular `resource`, because there is exactly one account per session and its id is the session
  # — an `/account/:id` would be an invitation to type somebody else's.
  resource :account, only: :show do
    resources :api_keys, only: %i[create destroy], controller: "user_api_keys"
  end

  # --- Machine auth: Bearer API key ---------------------------------------------
  namespace :api do
    namespace :v1 do
      # The Phase-1 protected endpoint: a valid key resolves its repository, a bad key gets 401.
      # Phase 3 (/check-intent) mounts alongside these.
      get "repository", to: "repositories#show"
      post "ingest", to: "ingests#create"

      # PLURAL, and a different credential from the singular route above — which is the whole
      # reason it is a separate controller rather than an `index` on that one. `/repository`
      # answers to a `sgk_` repository key and reports on the one repository it names;
      # `/repositories` answers to a `sgu_` user key and lists what that PERSON may open. The two
      # refuse each other's tokens with a 401 (see `Api::BaseController`), so the near-identical
      # paths cannot quietly serve the wrong thing.
      get "repositories", to: "user_repositories#index"
      # WHAT MAY BE REGISTERED, as opposed to what already IS — the reading `get "repositories"`
      # above cannot give, because that one serves `Repository.accessible_by` and a repository the
      # person has not registered yet is by definition not in it.
      #
      # A DEDICATED PATH rather than a `?registrable=1` opt-in on the route above, and the choice
      # was made on evidence rather than taste: `git grep -rn "params\[:" -- app/controllers/api`
      # returns exactly one line in the whole API tree, so there is no opt-in query-param
      # convention here to follow — adding one would be INVENTING the first, on the endpoint whose
      # response shape two shipped clients already read. A literal segment cannot be swallowed as
      # an id (there is no `:id` member route in this namespace), and it is declared ABOVE `post
      # "repositories"` only for reading order; the two do not compete for a path.
      #
      # Same controller as its two neighbours for the reason stated on the `post`: same credential,
      # same noun, and a second controller would carry its own `accepts_user_credential`
      # declaration to forget.
      get "repositories/registrable", to: "user_repositories#registrable"
      # Registering over the API. Same controller as the `get` above because it is the same
      # credential and the same noun; a separate controller would need its own
      # `accepts_user_credential` declaration and would be one omission away from a 401 nobody can
      # explain. The GitHub ownership check is NOT skipped here — see the controller.
      post "repositories", to: "user_repositories#create"
      # DELETING ONE OF THEM — the mutating half of the `sgu_` surface (SPGD-754), on the same
      # controller as its siblings for the same reason they share one: same credential, same noun,
      # and a second controller would carry its own `accepts_user_credential` declaration to forget.
      #
      # The authorization is `RepositoryAuthorization`'s fork at `:repo_delete` — NOT `:owner`,
      # matching the web `RepositoriesController#destroy` exactly, because the two are the same
      # code now and a member granted `repo.delete` may remove a repository in either surface.
      delete "repositories/:id", to: "user_repositories#destroy"
      # MINTING AND REVOKING A REPOSITORY'S OWN `sgk_` KEYS — mirroring the web nesting
      # (`resources :api_keys, only: %i[create destroy]` under `resources :repositories`), WITHOUT
      # the member `regenerate`: in-place rotation is ruled out of the API surface, and its
      # no-grace-window stop is the model's own documented behaviour rather than something to port.
      # The `:repository_id` segment is what `RepositoryAuthorization#current_repository` reads.
      post "repositories/:repository_id/api_keys", to: "user_repository_api_keys#create"
      delete "repositories/:repository_id/api_keys/:id", to: "user_repository_api_keys#destroy"
      # ONE REPOSITORY, BY NAME, FOR THE PERSON HOLDING THE KEY — the reading `get "repositories"`
      # above stops one grain short of. That one lists what a person may open and serves six identity
      # fields per row; this opens one and serves the whole overview.
      #
      # ⚠️ THE MEMBER ROUTE IS DECLARED LAST, AND THAT IS LOAD-BEARING RATHER THAN COSMETIC. Rails
      # matches in declaration order, and `:id` is a greedy dynamic segment that would happily
      # swallow the literal `registrable` above — `/repositories/registrable` would resolve to
      # `#show` with `params[:id] == "registrable"`, answer 404, and take a shipped endpoint off the
      # air. The note on `get "repositories/registrable"` says a literal "cannot be swallowed as an
      # id (there is no `:id` member route in this namespace)"; that parenthesis stops being true on
      # this line, so the ordering is now what keeps it safe. Do not sort these routes.
      #
      # PLURAL, and therefore the `sgu_` side: `GET /api/v1/repository` (singular) answers to a
      # `sgk_` repository key and is left exactly as it was. The two credentials stay disjoint —
      # `Api::BaseController`'s `accepted_credential` is one `class_attribute` per controller, so a
      # surface answering to both is not expressible and deliberately so. The BODY is shared anyway,
      # by `RepositoryOverview` rather than by a shared credential; see that class.
      get "repositories/:id", to: "user_repositories#show"
      # MANAGING A REPOSITORY'S MEMBERS over the `sgu_` surface (SPGD-875) — list, add by handle,
      # edit permissions, revoke — mirroring the web nesting (`resources :memberships` under
      # `resources :repositories`) in the named-per-route shape `user_repository_api_keys` uses
      # directly above, for the reason the `post "repositories"` note states: a second
      # `accepts_user_credential` declaration to forget on a controller nobody routed is one
      # omission away from a 401 nobody can explain, so same noun, same controller.
      #
      # The `:repository_id` segment is what `RepositoryAuthorization#current_repository` reads;
      # the `:id` on the member routes is a MEMBERSHIP id, scoped to the repository by the
      # controller's `find_membership!` — a foreign repository's membership id answers 404 there.
      get "repositories/:repository_id/members", to: "user_repository_members#index"
      post "repositories/:repository_id/members", to: "user_repository_members#create"
      patch "repositories/:repository_id/members/:id", to: "user_repository_members#update"
      delete "repositories/:repository_id/members/:id", to: "user_repository_members#destroy"
    end
  end

  # --- The protocol contract, downloadable ---------------------------------------
  # A convenience mirror of the OpenTestIntent v1 schema, served unauthenticated so anyone reading
  # the docs can fetch what their annotations are validated against. The canonical copy lives in the
  # vendor-neutral `open-test-intent` repository, which is what the schema's `$id` names; this is a
  # second address for the same bytes, not a second source of truth.
  #
  # `format: false` because the `.v1.json` in the path is part of the schema's FILENAME, not a
  # format request. Left on, Rails' optional `(.:format)` segment would make `/schemas/
  # open-test-intent.v1` answer too, advertising an address whose name no longer says which
  # version it returns.
  get "/schemas/open-test-intent.v1.json", to: "schemas#open_test_intent_v1",
                                           as: :open_test_intent_schema, format: false

  get "up", to: "rails/health#show", as: :rails_health_check
end
