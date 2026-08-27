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

  # The administration guide (SPGD-762) — the document the reservation above anticipated.
  #
  # Same charter and same reason for being ungated as `integrate`, but a different SCOPE: that page
  # documents the CI-facing `sgk_` surface, this one documents the `sgu_` administration surface —
  # `get "repositories"` and `post "repositories"` below, the ones a PERSON's key answers. Splitting
  # them by credential rather than by count is what lets each page state its boundary as something
  # that stays true when a fifth route lands.
  #
  # It exists because registering over the API has a precondition stated nowhere in advance: a
  # `GithubRegistrationGrant` is captured only when a browser lists repositories, and expires after
  # `GithubRegistrationGrant::MAX_AGE`. Until this page, the only surface that ever said so was the
  # 400 that had already refused the request.
  get "docs/administer", to: "pages#administer", as: :administration_guide

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
      # Registering over the API. Same controller as the `get` above because it is the same
      # credential and the same noun; a separate controller would need its own
      # `accepts_user_credential` declaration and would be one omission away from a 401 nobody can
      # explain. The GitHub ownership check is NOT skipped here — see the controller.
      post "repositories", to: "user_repositories#create"
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
