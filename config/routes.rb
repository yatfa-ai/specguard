Rails.application.routes.draw do
  root "pages#home"

  # --- Human auth: GitHub OAuth -------------------------------------------------
  post  "/auth/github",          to: "sessions#passthru", as: :github_auth
  get   "/auth/github/callback", to: "sessions#create"
  post  "/auth/github/callback", to: "sessions#create"
  get   "/auth/failure",         to: "sessions#failure"
  delete "/sign_out",            to: "sessions#destroy", as: :sign_out

  # --- Dashboard ----------------------------------------------------------------
  resources :repositories, only: %i[index new create show destroy] do
    resources :api_keys, only: %i[create destroy]
  end

  # --- Machine auth: Bearer API key ---------------------------------------------
  namespace :api do
    namespace :v1 do
      # The Phase-1 protected endpoint: a valid key resolves its repository, a bad key gets 401.
      # Phase 2 (/ingest) and Phase 3 (/check-intent) mount alongside it.
      get "repository", to: "repositories#show"
    end
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
