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

    # @intent: {"entity": "GithubRegistrationGrant", "action": "mint grant", "behavior": "rendering the registration picker for a person who can see three repositories but administers one creates a grant whose registrable_full_names is exactly acme/billing-service", "layer": "request"}
    it "grants only the repositories GitHub names this person an administrator of" do
      expect { visit_picker }.to change { grant_for(@user) }.from(nil)

      expect(grant_for(@user).registrable_full_names).to eq(["acme/billing-service"])
    end

    # The other half of the same fixture, and NOT a restatement of it: the two repositories this
    # person can see but not administer are recorded, because a refusal has to be able to tell them
    # apart from a name GitHub has never heard of. Recorded is not granted — the example above is
    # what pins that, and `spec/requests/api/v1/user_repository_registration_spec.rb` pins that a
    # visible-but-unadministered name is refused.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "record visible repositories", "behavior": "the persisted grant's visible_full_names lists all three visible names (billing-service, checkout, ledger) separately from the single registrable one", "layer": "request"}
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

    # @intent: {"entity": "GithubRegistrationGrant", "action": "refuse stale overwrite", "behavior": "when a second picker render reads GitHub truncated the prior grant survives with registrable_full_names still naming both repositories and captured_at still at the three-days-ago stamp", "layer": "request"}
    it "keeps the previous grant, and its previous timestamp, when the page walk was truncated" do
      stub_github(repos: [github_repo("acme/billing-service")], truncated: true)

      visit_picker

      grant = grant_for(@user)
      expect(grant.registrable_full_names).to eq(%w[acme/billing-service acme/checkout])
      expect(grant.captured_at).to eq(captured_three_days_ago)
    end

    # @intent: {"entity": "GithubRegistrationGrant", "action": "refuse stale overwrite", "behavior": "when a second picker render finds GitHub unavailable the prior grant survives with both registrable names and the three-days-ago captured_at", "layer": "request"}
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
    # @intent: {"entity": "GithubRegistrationGrant", "action": "replace on complete read", "behavior": "when the second render's reading is complete the grant is rewritten to the single remaining name and captured_at moves past the three-days-ago stamp", "layer": "request"}
    it "does replace it when the reading was complete" do
      stub_github(repos: [github_repo("acme/billing-service")])

      visit_picker

      grant = grant_for(@user)
      expect(grant.registrable_full_names).to eq(["acme/billing-service"])
      expect(grant.captured_at).to be > captured_three_days_ago
    end
  end

  # SPGD-975 — an uninstall performed ON GITHUB, which is a different act from SpecGuard's own
  # Disconnect button and reaches this code by none of the same paths. Nothing deletes the local
  # `GithubInstallation` row (`GithubInstallation:18-25`: reacting to uninstall EVENTS is a later
  # slice), so the person keeps holding rows and `sources` runs `collect` — where GitHub answers
  # NotFound for the dead row, `read` absorbs that as an empty listing plus `:unreadable`
  # (deliberately not an error, see its comment), and before the third gate BOTH existing gates
  # passed: a fresh EMPTY grant was minted over an installation that no longer exists, re-minted by
  # every later render so it never lapsed on `MAX_AGE`, and `GrantVerifier#verdict_for` answered
  # `:not_in_installation` — "Add it on GitHub, then pick it here" — to somebody whose repository
  # is already there. The true verdict is `:not_granted`, whose sentence names the real fix.
  describe "when GitHub answers NotFound for every installation the person holds" do
    before do
      @user = sign_in_via_github
      stub_github(not_found: true)
    end

    # Criterion 1: the mint is refused, through the real render the grant hangs off.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "refuse unanswered reading", "behavior": "a picker render whose every installation 404s leaves the person with no GithubRegistrationGrant row at all", "layer": "request"}
    it "mints no grant at all" do
      expect { visit_picker }.not_to change(GithubRegistrationGrant, :count)

      expect(grant_for(@user)).to be_nil
    end

    # Criterion 2, asserted end to end at the endpoint that redeems a grant — the shape SPGD-808's
    # disconnect examples use. Read from `InstallationRepositories::MESSAGES` rather than quoted,
    # so this pins WHICH verdict is reached and cannot drift from the shipped wording.
    # @intent: {"entity": "GrantVerifier", "action": "answer not_granted after unanswered read", "behavior": "registering with an API key after an all-404 picker render answers with the not_granted message and never the not_in_installation claim", "layer": "request"}
    it "makes the API say SpecGuard has no record, not that the repository is missing from GitHub" do
      visit_picker

      key = create_user_api_key(user: @user)
      post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" }, as: :json,
                                   headers: { "Authorization" => "Bearer #{key.raw_token}" }

      expect(response.body).to include(InstallationRepositories::MESSAGES[:not_granted])
      expect(response.body).not_to include(InstallationRepositories::MESSAGES[:not_in_installation])
    end

    # Criterion 3, and the choice pinned: the refusing read does NOT delete. A person already
    # holding one of the false fresh-empty grants this slice stops minting keeps the row with its
    # OLD stamp — capture's discipline of "do not write a statement we cannot make" — so it lapses
    # on `MAX_AGE` (≤ 7 days) instead of being refreshed into immortality by the very read that
    # should have refused it. Dropping it at the read was the alternative and was refused: a read
    # must not destroy, and a github.com uninstall has no local moment to hook.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "leave false grant to lapse", "behavior": "a picker render whose every installation 404s leaves a pre-existing fresh-but-empty grant untouched with its original captured_at rather than refreshing or deleting it", "layer": "request"}
    it "leaves a pre-existing fresh-but-empty grant unrefreshed, to lapse on MAX_AGE" do
      false_stamp = 2.minutes.ago.change(usec: 0)
      create_registration_grant(user: @user, registrable: [], visible: [], captured_at: false_stamp)

      visit_picker

      grant = grant_for(@user)
      expect(grant.captured_at).to eq(false_stamp)
    end

    # The control criterion 3 needs: refusing the write is not freezing the person out. Once GitHub
    # answers for the installation again, the same render mints normally.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "recover after GitHub answers", "behavior": "after an all-404 render mints nothing, a later render whose installation answers writes the grant with the administered repository", "layer": "request"}
    it "mints normally again once GitHub answers for the installation" do
      visit_picker
      expect(grant_for(@user)).to be_nil

      stub_github(repos: [github_repo("acme/billing-service")])
      visit_picker

      expect(grant_for(@user).registrable_full_names).to eq(["acme/billing-service"])
    end

    # Criterion 6, pinned to the conservative rule: refuse only when NOTHING answered. A partial
    # reading — one installation answered, another 404s — is still GitHub's answer about everything
    # it did read, and the grant is written from it. The unread account stays a display concern
    # (`github_unread_accounts`).
    # @intent: {"entity": "GithubRegistrationGrant", "action": "grant partial reading", "behavior": "with one installation 404ing and another answering with acme/api, the picker render still mints a grant naming exactly acme/api", "layer": "request"}
    it "still writes the grant when at least one installation answered among several" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api")] }))
      end

      visit_picker

      expect(grant_for(@user).registrable_full_names).to eq(["acme/api"])
    end
  end

  # SPGD-756 call #1 and criterion 5. A merge would accumulate repositories the person has since
  # lost admin on — the exact failure the ownership gate exists to prevent — and would get worse the
  # longer an account lived.
  # @intent: {"entity": "GithubRegistrationGrant", "action": "replace grant wholesale", "behavior": "a re-render offering only acme/billing-service narrows registrable_full_names to exactly that list, dropping the acme/checkout the earlier reading granted", "layer": "request"}
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
  # @intent: {"entity": "GithubRegistrationGrant", "action": "keep one row per person", "behavior": "three renders of the picker change GithubRegistrationGrant count by exactly 1 and leave a single row for the signed-in user", "layer": "request"}
  it "keeps exactly one row per person however many times the page is rendered" do
    user = sign_in_via_github

    expect { 3.times { visit_picker } }.to change(GithubRegistrationGrant, :count).by(1)
    expect(GithubRegistrationGrant.where(user_id: user.id).count).to eq(1)
  end

  # The claim the refresh point is CHOSEN for: it hangs off a read the browser was already making,
  # so an active person's grant is always current and no GitHub call is added anywhere.
  # @intent: {"entity": "GithubRegistrationGrant", "action": "mint without extra round trip", "behavior": "one render of the picker after sign-in makes exactly one call to the GitHub repositories listing — no second call to mint the grant", "layer": "request"}
  it "costs no additional GitHub round trip" do
    sign_in_via_github
    fake = stub_github(repos: [github_repo("acme/billing-service")])

    visit_picker

    expect(fake.calls_to(:repositories)).to eq(1)
  end
end
