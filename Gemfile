source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Bundle and process CSS [https://github.com/rails/cssbundling-rails]
# Tailwind comes from npm (`@tailwindcss/cli`) rather than from tailwindcss-rails, so the build is
# pinned by package-lock.json and `css:build` hooks into `assets:precompile`. The built stylesheet
# is NOT committed — see .gitignore and the README.
gem "cssbundling-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

# --- SpecGuard ---
# ViewComponent — the UI::* primitive library inherited from yatfa's design system
gem "view_component"
# pgvector support for ActiveRecord (vector column type + nearest_neighbors)
gem "neighbor"
# JSON Schema (draft-07) validation for the vendored OpenTestIntent contract
gem "json_schemer", "~> 2.4"
# GitHub OAuth for human sign-in
gem "omniauth"
gem "omniauth-github"
gem "omniauth-rails_csrf_protection"
# Background jobs — embedding generation runs asynchronously rather than in the request.
# Runs in the primary database; see config/database.yml for why.
gem "solid_queue"
# HTTP client for the embedding provider (OpenRouter → voyageai/voyage-4-lite, 1024-dim). One JSON
# POST is not enough to justify a vendor SDK — see app/services/embedding_generator.rb.
gem "faraday"

group :development, :test do
  # Test framework
  gem "rspec-rails", "~> 8.0"
  # SpecGuard's own Ruby client, so this suite reports itself to the platform it is. `require:
  # false` because nothing in the app loads it: the formatter is pulled in by `--require` from
  # SPEC_OPTS, which only CI sets. A local `bin/rspec` therefore behaves exactly as it did before —
  # deliberate, because an unconfigured formatter does not stay quiet, it appends one JSON object
  # per line to `SPECGUARD_OUTPUT_PATH` (see the gem's formatter: api_key set → POST, unset → file).
  gem "specguard-rspec", "~> 0.2.3", require: false
  # Node matchers for ViewComponent unit specs (render_inline + have_css), and the browser-driven
  # system specs in spec/system.
  gem "capybara"
  # Drives a real headless Chromium for spec/system. Only the system specs need it, and they are
  # the only place a claim about Turbo, Stimulus or anything else that requires JS can be settled:
  # a request spec renders the response body itself and so cannot see a browser refuse it.
  gem "selenium-webdriver"
end
