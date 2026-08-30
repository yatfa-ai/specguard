# frozen_string_literal: true

require "rails_helper"

# SPGD-756 criterion 8 — the WEB path, after the gate was extracted out of `RepositoriesController`
# into `RepositoryRegistration` so a session-free caller could reach it.
#
# `spec/requests/repositories_spec.rb` already covers what registering and renaming DO, and none of
# its assertions changed. What it cannot cover is the two things the extraction put at risk, because
# neither of them existed before it:
#
#   1. The browser must still ask GitHub LIVE. The grant is a recording taken for the machine
#      surface's benefit; a web request that consulted it would be answering from a snapshot when
#      the authoritative answer is one round trip away, and would keep admitting somebody who lost
#      admin up to a week ago.
#   2. The `valid?` -> ownership -> `save` order, and the laziness that hangs off it, must survive
#      being moved into another object.
RSpec.describe "Registering in a browser, after the gate moved", type: :request do
  before { @user = sign_in_via_github }

  describe "the browser asks GitHub, not the grant" do
    # The sharpest direction: the grant says yes and GitHub says no. A path consulting the grant
    # registers this; the live path refuses it.
    # @intent: {"entity": "Repository", "action": "refuse grant-only repository", "behavior": "a name the grant lists but GitHub does not is refused with 422, no Repository row created, and the not_in_installation message rendered", "layer": "request"}
    it "refuses a repository the grant names but GitHub does not" do
      create_registration_grant(user: @user, registrable: ["acme/payments"])
      stub_github(repos: [github_repo("acme/billing-service")])

      expect {
        post repositories_path, params: { repository: { github_full_name: "acme/payments" } }
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(InstallationRepositories::MESSAGES.fetch(:not_in_installation))
    end

    # The other direction, and the one that would break real people rather than merely admit them:
    # somebody who has never held a grant — everybody, on the day this ships — must still be able to
    # register in a browser exactly as they always could.
    # @intent: {"entity": "Repository", "action": "register without grant", "behavior": "a signed-in user holding no grant at all still creates exactly one Repository row by posting a name GitHub lists live", "layer": "request"}
    it "registers for somebody who holds no grant at all" do
      expect(GithubRegistrationGrant.where(user_id: @user.id)).to be_empty

      expect {
        post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
      }.to change(Repository, :count).by(1)
    end

    # @intent: {"entity": "Repository", "action": "register past grant age", "behavior": "a grant captured a day beyond GithubRegistrationGrant::MAX_AGE with an empty registrable list still allows the live registration, creating one Repository", "layer": "request"}
    it "registers on a live yes even when the grant is long past its bound" do
      create_registration_grant(user: @user, registrable: [],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.day)

      expect {
        post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
      }.to change(Repository, :count).by(1)
    end

    # @intent: {"entity": "Repository", "action": "refuse grant-allowed rename", "behavior": "renaming to a name the grant would have allowed but GitHub does not list answers 422 and leaves the repository still named acme/billing-service", "layer": "request"}
    it "refuses a rename the grant would have allowed" do
      create_registration_grant(user: @user, registrable: %w[acme/billing-service acme/renamed])
      stub_github(repos: [github_repo("acme/billing-service")])
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/renamed" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end
  end

  describe "the order the gate runs in" do
    # `valid?` first, asserted WITHOUT a message expectation: GitHub is stubbed as down, so an
    # ownership check that ran first would produce the outage refusal. The uniqueness refusal is
    # therefore evidence that the record's own rules answered before GitHub was ever asked about
    # the name.
    # @intent: {"entity": "Repository", "action": "validate before GitHub", "behavior": "an already-taken name is refused 422 with has already been taken and no outage message, proving the record's own rules answered before GitHub was asked", "layer": "request"}
    it "refuses an already-registered name from the record's own rules, before asking GitHub" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "acme/taken")
      stub_github(unavailable: true)

      post repositories_path, params: { repository: { github_full_name: "acme/taken" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
      expect(response.body).not_to include(InstallationRepositories::MESSAGES.fetch(:unavailable))
    end

    # The laziness the extraction most easily loses. `github_sources` is memoized AND lazy, and a
    # verifier built with `sources: github_sources` rather than with a lambda would force that read
    # at construction — before the gate has decided whether the name is even changing. A rename form
    # submitted unchanged would then start costing a GitHub page walk, and would start failing
    # closed during an outage, for a write that changes nothing.
    # @intent: {"entity": "Repository", "action": "skip GitHub on unchanged rename", "behavior": "a rename submitted with the name unchanged redirects to the repository page and makes zero GitHub repositories calls", "layer": "request"}
    it "asks GitHub nothing when a rename leaves the name unchanged" do
      repository = create_repository(user: @user)
      fake = stub_github(repos: [github_repo("acme/billing-service")])

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(fake.calls_to(:repositories)).to eq(0)
    end

    # The control the example above needs: a rename that DOES change the name must still ask.
    # Without it, an implementation that never verifies anything passes.
    # @intent: {"entity": "Repository", "action": "ask GitHub on real rename", "behavior": "a rename that actually changes the name redirects to the repository page and makes exactly one GitHub repositories call", "layer": "request"}
    it "does ask when the rename actually changes the name" do
      repository = create_repository(user: @user)
      fake = stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/renamed")])

      patch repository_path(repository), params: { repository: { github_full_name: "acme/renamed" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(fake.calls_to(:repositories)).to eq(1)
    end

    # The verdict is what lets the 422 offer an install button instead of an error no field can
    # fix. It is collected inside `RepositoryRegistration` now, and the controller has to bring it
    # back out — a detail nothing else would notice going missing.
    # @intent: {"entity": "Repository", "action": "offer install button", "behavior": "with the App not installed at all the 422 response carries the not_installed message so the form can offer an install button rather than an unfixable error", "layer": "request"}
    it "still offers the install button when the App is not installed at all" do
      uninstall_github_app(@user)

      post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(InstallationRepositories::MESSAGES.fetch(:not_installed))
    end
  end

  # SPGD-775 criterion 2 — the same refusal, arrived at the other way.
  #
  # "Refuses an already-registered name" above is the SEQUENTIAL path: the uniqueness validation's
  # SELECT sees the row and answers before anything is written. When the row appears AFTER that
  # SELECT — a double-submitted form, a re-post on a slow connection — the validation passes and the
  # unique index refuses instead, as `ActiveRecord::RecordNotUnique`. Nothing caught that, and with
  # no `rescue_from` anywhere in this app it reached the 500 handler: a crash for the exact
  # condition the sequential path answers with a sentence.
  #
  # The point of the assertion is that the person sees the SAME form and the SAME words either way,
  # so this deliberately re-states the sequential example's expectations rather than settling for
  # "not a 500". The race is simulated by silencing the uniqueness validation, which is exactly what
  # it does on its own when it cannot see the winning row yet (spec/support/uniqueness_race.rb) — a
  # spec that merely posted the same name twice would prove nothing, because the validation catches
  # that unaided.
  describe "losing the uniqueness race to a concurrent registration" do
    # @intent: {"entity": "Repository", "action": "survive uniqueness race", "behavior": "when the uniqueness validation cannot see the winning row the unique-index refusal is answered with a 422 re-render of the form saying has already been taken, no Repository row created and no 500", "layer": "request"}
    it "re-renders the form with the duplicate message instead of raising" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/taken")])
      allow(uniqueness_validator(Repository)).to receive(:validate_each)

      expect {
        post repositories_path, params: { repository: { github_full_name: "acme/taken" } }
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
    end
  end
end
