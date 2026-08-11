# frozen_string_literal: true

require "rails_helper"

# The decision half of ownership verification: given what GitHub says, may this user register this
# repository? Every example here is about a *verdict*, never about HTTP — the client is the seam,
# installed through `GithubApi.factory` exactly as production would swap it.
RSpec.describe GithubOwnership do
  let(:user) { create_user }

  def verify(full_name = "acme/billing-service")
    described_class.verify(user: user, full_name: full_name)
  end

  it "verifies a repository GitHub reports the user as an admin of" do
    stub_github(repos: [github_repo("acme/billing-service", admin: true)], strict: true)

    verdict = verify

    expect(verdict).to be_verified
    expect(verdict.status).to eq(:verified)
  end

  # The gap this whole slice exists to close. The repository is real and visible — it is simply
  # somebody else's — and before verification existed this registered successfully.
  it "refuses a repository the user can see but does not administer" do
    stub_github(repos: [github_repo("someone-else/private-repo", admin: false)], strict: true)

    verdict = verify("someone-else/private-repo")

    expect(verdict).not_to be_verified
    expect(verdict.status).to eq(:not_admin)
    expect(verdict.message).to include("administer")
    # The fix is to pick something else, not to grant more access — so the form must not offer the
    # authorize button here.
    expect(verdict).not_to be_reauthorize
  end

  it "refuses a repository the token cannot see at all" do
    stub_github(repos: [], strict: true)

    verdict = verify("ghost/repo")

    expect(verdict.status).to eq(:not_found)
    expect(verdict.message).to include("not visible to your GitHub account")
  end

  # Asked of the stored grant, not discovered from a 403 — so it costs no round trip, and it is the
  # answer for a user who has signed in and never authorized repository access.
  it "answers not_connected without calling GitHub when no token is stored" do
    user.update!(github_access_token: nil, github_token_scopes: nil)
    fake = stub_github(repos: [github_repo("acme/billing-service")])

    verdict = verify

    expect(verdict.status).to eq(:not_connected)
    expect(verdict).to be_reauthorize
    expect(fake.calls).to be_empty
  end

  # A live token at the sign-in scopes cannot read repositories. That is a different fact from
  # "no token", and collapsing them would send the user to reconnect an authorization that is
  # working fine.
  it "answers not_connected when the stored grant lacks a repository scope" do
    narrow_github_scope(user)
    fake = stub_github

    verdict = verify

    expect(verdict.status).to eq(:not_connected)
    expect(fake.calls).to be_empty
  end

  it "accepts a grant of public_repo alone" do
    user.update!(github_token_scopes: "public_repo")
    stub_github(repos: [github_repo("acme/billing-service")], strict: true)

    expect(verify).to be_verified
  end

  it "reports a rejected token as something to reconnect, not as a refusal" do
    stub_github(unauthorized: true)

    verdict = verify

    expect(verdict.status).to eq(:token_rejected)
    expect(verdict).to be_reauthorize
  end

  # Fails closed, and this is the example that pins it: if an outage verified by default, the
  # squatting gap would reopen on every GitHub 500.
  it "refuses when GitHub cannot be reached" do
    stub_github(unavailable: true)

    verdict = verify

    expect(verdict).not_to be_verified
    expect(verdict.status).to eq(:unavailable)
    expect(verdict).not_to be_reauthorize
  end

  # The three 403s, kept apart. Collapsing them into `:unavailable` is what told a user behind an
  # SSO-enforced organization to "try again shortly" for a condition that never clears on its own —
  # so each example asserts the status AND that it is not the outage one.
  {
    sso_required: :sso_required,
    rate_limited: :rate_limited,
    insufficient_scope: :scope_too_narrow
  }.each do |reason, status|
    it "refuses a #{reason} 403 as #{status} rather than as an outage" do
      stub_github(forbidden: reason)

      verdict = verify

      expect(verdict).not_to be_verified
      expect(verdict.status).to eq(status)
      expect(verdict.status).not_to eq(:unavailable)
    end
  end

  # The SSO sentence has to name the organization remedy, because that is the only thing that
  # resolves it. Asserted against the message the form will actually show, not against a literal.
  it "tells an SSO-blocked user their organization may need to approve SpecGuard" do
    stub_github(forbidden: :sso_required)

    expect(verify.message).to include("organization may need to approve SpecGuard")
    expect(verify.message).not_to include("Try again shortly")
  end

  # A too-narrow grant is fixed by granting more, so the form must offer the authorize button
  # rather than an error the field cannot resolve. The other two 403s are NOT reauthorize cases:
  # re-authorizing does not clear a rate limit or an org's SSO policy.
  it "offers re-authorization for a too-narrow grant only" do
    stub_github(forbidden: :insufficient_scope)
    expect(verify).to be_reauthorize

    stub_github(forbidden: :sso_required)
    expect(verify).not_to be_reauthorize

    stub_github(forbidden: :rate_limited)
    expect(verify).not_to be_reauthorize
  end

  it "asks GitHub about the trimmed name it was given" do
    fake = stub_github(repos: [github_repo("acme/billing-service")], strict: true)

    expect(verify("  acme/billing-service  ")).to be_verified
    expect(fake.calls).to eq([[:repository, "acme/billing-service"]])
  end
end
