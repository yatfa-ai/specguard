# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"

  # The Phase-1 design-system gate. The baseline is shrink-only and starts at 0/0/0, so this
  # goes red the first time a view reaches for a raw palette colour, an ad-hoc heading size,
  # or a raw DaisyUI button.
  step "Style: Design-system drift", "bin/rails lint:design_system"

  # app/assets/builds/tailwind.css is committed so a clone can boot without Node; this proves
  # the committed file is still what the sources actually produce.
  step "Style: Stylesheet is current", "bin/rails lint:stylesheet"

  step "Tests", "bin/rspec"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
