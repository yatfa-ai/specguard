Rails.application.routes.draw do
  root "pages#home"

  # The public integration guide (SPGD-705). Deliberately outside every authentication gate, and
  # that is the requirement rather than an oversight: its intended reader is as often an AI coding
  # agent handed nothing but this URL as it is a person, and such an agent has no session and
  # cannot acquire one. It documents the two `api/v1` routes declared below and promises nothing
  # beyond them, so there is nothing on it a signed-out reader must not see.
  #
  # `/docs/…` rather than a bare `/integrate` so the next document has an obvious home; the named
  # helper is `integration_guide_path`, which is what the repository page's agent-prompt block
  # builds its URL from — the prompt is only correct because it points at this page, so the two
  # must not be able to drift apart through a hand-written string.
  get "docs/integrate", to: "pages#integrate", as: :integration_guide

  # --- Human auth: GitHub OAuth -------------------------------------------------
  post  "/auth/github",          to: "sessions#passthru", as: :github_auth
  get   "/auth/github/callback", to: "sessions#create"
  post  "/auth/github/callback", to: "sessions#create"
  get   "/auth/failure",         to: "sessions#failure"
  delete "/sign_out",            to: "sessions#destroy", as: :sign_out

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

  # --- Machine auth: Bearer API key ---------------------------------------------
  namespace :api do
    namespace :v1 do
      # The Phase-1 protected endpoint: a valid key resolves its repository, a bad key gets 401.
      # Phase 3 (/check-intent) mounts alongside these.
      get "repository", to: "repositories#show"
      post "ingest", to: "ingests#create"
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
