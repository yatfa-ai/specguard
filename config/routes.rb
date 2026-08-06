Rails.application.routes.draw do
  root "pages#home"

  # --- Human auth: GitHub OAuth -------------------------------------------------
  post  "/auth/github",          to: "sessions#passthru", as: :github_auth
  get   "/auth/github/callback", to: "sessions#create"
  post  "/auth/github/callback", to: "sessions#create"
  get   "/auth/failure",         to: "sessions#failure"
  delete "/sign_out",            to: "sessions#destroy", as: :sign_out

  # --- Dashboard ----------------------------------------------------------------
  resources :repositories, only: %i[index new create show edit update destroy] do
    resources :api_keys, only: %i[create destroy]
    # `/repositories/:repository_id/members` reads as the thing it lists (people), while the
    # controller is named for the row it actually manipulates (RepositoryMembership). No `edit`
    # /`update` yet: editing an existing member's permissions is the same checkbox grid `new`
    # renders, and lands as its own slice.
    resources :members, only: %i[index new create destroy], controller: "memberships"
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

  get "up", to: "rails/health#show", as: :rails_health_check
end
