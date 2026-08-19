# frozen_string_literal: true

require "rails_helper"

# SPGD-756 success criteria 3, 4 and 5 — the MINT half of the grant.
#
# Everything here goes through the real mint path rather than through `GithubRegistrationGrant
# .capture` directly, and that is deliberate. The grant's whole reason to exist is that it is taken
# at a moment a live GitHub token is in hand, and the claim that it costs nothing rests entirely on
# WHICH moment that is — a read the browser was making anyway. A spec that calls `capture` with a
# hand-built `Sources` would pass just as happily against a mechanism nothing ever invokes.
#
# The assertions are all against the PERSISTED row (`GithubRegistrationGrant.find_by`, reloaded),
# never against an in-memory object the mint path handed back.
RSpec.describe "The GitHub registration grant, as it is minted", type: :request do
  def grant_for(user) = GithubRegistrationGrant.find_by(user_id: user.id)

  # Renders the registration picker, which is the page whose `github_sources` read the grant hangs
  # off. Nothing about registering is exercised here — this is the ordinary act of LOOKING at the
  # list, which is what makes the refresh free.
  def visit_picker = get new_repository_path

  # SPGD-756 call #2 and criterion 3. `Sources#repos` is everything this person can SEE;
  # `Sources#registrable` is the subset GitHub names them an administrator of. Snapshotting the
  # first as the grant would reopen, verbatim, the gap `InstallationRepositories` exists to close:
  # an organization member with view access to one repository could register all fifty.
  describe "what goes into it" do
    before do
      stub_github(repos: [github_repo("acme/billing-service"),
                          github_repo("acme/ledger", admin: false),
                          github_repo("acme/checkout", admin: false)])
      @user = sign_in_via_github
    end

    it "grants only the repositories GitHub names this person an administrator of" do
      expect { visit_picker }.to change { grant_for(@user) }.from(nil)

      expect(grant_for(@user).registrable_full_names).to eq(["acme/billing-service"])
    end

    # The other half of the same fixture, and NOT a restatement of it: the two repositories this
    # person can see but not administer are recorded, because a refusal has to be able to tell them
    # apart from a name GitHub has never heard of. Recorded is not granted — the example above is
    # what pins that, and `spec/requests/api/v1/user_repository_registration_spec.rb` pins that a
    # visible-but-unadministered name is refused.
    it "records what they can merely see, separately, so a refusal can be worded truthfully" do
      visit_picker

      expect(grant_for(@user).visible_full_names)
        .to match_array(%w[acme/billing-service acme/checkout acme/ledger])
    end
  end

  # SPGD-756 call #3 and criterion 4 — the criterion whose absence silently NARROWS a person's
  # reach, which is why both directions of it are asserted.
  #
  # `Sources#complete?` is `!truncated && error.nil?`. In a grant an absent name is a REFUSAL, so a
  # set built from a reading that was cut short would refuse repositories this person genuinely
  # administers, and nothing about the refusal would say that SpecGuard, rather than GitHub, was the
  # one that could not answer.
  describe "when the reading of GitHub was incomplete" do
    # A deliberately distinctive prior stamp: an overwrite would move it to `Time.current`, so
    # "the previous grant survived" and "the previous grant's AGE survived" are both visible.
    let(:captured_three_days_ago) { 3.days.ago.change(usec: 0) }

    before do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])
      @user = sign_in_via_github
      visit_picker
      grant_for(@user).update_column(:captured_at, captured_three_days_ago)
    end

    it "keeps the previous grant, and its previous timestamp, when the page walk was truncated" do
      stub_github(repos: [github_repo("acme/billing-service")], truncated: true)

      visit_picker

      grant = grant_for(@user)
      expect(grant.registrable_full_names).to eq(%w[acme/billing-service acme/checkout])
      expect(grant.captured_at).to eq(captured_three_days_ago)
    end

    it "keeps the previous grant, and its previous timestamp, when an installation would not answer" do
      stub_github(unavailable: true)

      visit_picker

      grant = grant_for(@user)
      expect(grant.registrable_full_names).to eq(%w[acme/billing-service acme/checkout])
      expect(grant.captured_at).to eq(captured_three_days_ago)
    end

    # The control the two examples above need. Without it they pass against an implementation that
    # never writes a grant on a second render at all — which would leave every returning person's
    # grant frozen at its first reading and expiring under them.
    it "does replace it when the reading was complete" do
      stub_github(repos: [github_repo("acme/billing-service")])

      visit_picker

      grant = grant_for(@user)
      expect(grant.registrable_full_names).to eq(["acme/billing-service"])
      expect(grant.captured_at).to be > captured_three_days_ago
    end
  end

  # SPGD-756 call #1 and criterion 5. A merge would accumulate repositories the person has since
  # lost admin on — the exact failure the ownership gate exists to prevent — and would get worse the
  # longer an account lived.
  it "replaces the grant wholesale rather than merging into it" do
    stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])
    user = sign_in_via_github
    visit_picker
    expect(grant_for(user).registrable_full_names).to include("acme/checkout")

    stub_github(repos: [github_repo("acme/billing-service")])
    visit_picker

    expect(grant_for(user).registrable_full_names).to eq(["acme/billing-service"])
  end

  # One row per person, enforced by the database rather than by whichever code path happens to be
  # writing. SPGD-756 call #1: a per-key grant would let one person hold three divergent opinions
  # about their own GitHub access.
  it "keeps exactly one row per person however many times the page is rendered" do
    user = sign_in_via_github

    expect { 3.times { visit_picker } }.to change(GithubRegistrationGrant, :count).by(1)
    expect(GithubRegistrationGrant.where(user_id: user.id).count).to eq(1)
  end

  # The claim the refresh point is CHOSEN for: it hangs off a read the browser was already making,
  # so an active person's grant is always current and no GitHub call is added anywhere.
  it "costs no additional GitHub round trip" do
    sign_in_via_github
    fake = stub_github(repos: [github_repo("acme/billing-service")])

    visit_picker

    expect(fake.calls_to(:repositories)).to eq(1)
  end
end
