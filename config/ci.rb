# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"

  # The Phase-1 design-system gate. The baseline is shrink-only and starts at 0/0/0, so this
  # goes red the first time a view reaches for a raw palette colour, an ad-hoc heading size,
  # or a raw DaisyUI button.
  step "Style: Design-system drift", "bin/rails lint:design_system"

  # app/assets/builds/ is generated and gitignored, so there is no committed artifact to go stale
  # and nothing to compare against. The build itself happens in the "Setup" step above — `bin/setup`
  # runs `npm ci && npm run build:css`, and fails loudly if npm is missing.
  #
  # This asserts the result. It is not the only protection: because the layout names the asset
  # (`stylesheet_link_tag "application"`), Propshaft raises `MissingAssetError` on the first render
  # if the build produced nothing. That is precisely what the old `:app` GLOB did not do — a glob
  # over app/assets/**/*.css just yields a smaller set, so a missing stylesheet rendered no link and
  # the suite went green against an app with no CSS.
  #
  # The step earns its place by failing HERE, named, before 3000 examples explode inside a view.
  step "Style: Stylesheet was built", "test -s app/assets/builds/application.css"

  step "Tests", "bin/rspec"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
