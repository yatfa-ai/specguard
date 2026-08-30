# frozen_string_literal: true

require "rails_helper"

# SPGD-768 success criterion 5: the account page states the age and the expiry of the one
# credential on it that lapses on its own.
#
# The defect being closed is a SILENT one, which is why the examples below assert the presence of
# sentences rather than merely a status: nothing about a lapsed grant looks broken. `GET
# /api/v1/repositories` needs no grant and keeps answering, and the key's own "Last used" keeps
# updating — so a person whose registration access expired a week ago sees a page that is, without
# this panel, indistinguishable from a working one.
RSpec.describe "Account registration access", type: :request do
  before { @person = sign_in_via_github }

  attr_reader :person

  # The three states the panel distinguishes, named as a reader would recognise them.
  def panel_state
    response.body[/data-grant-state="([a-z]+)"/, 1]
  end

  describe "with no grant ever captured" do
    # @intent: {"entity": "RegistrationGrant", "action": "render absent state", "behavior": "a signed-in user with no grant ever captured gets a 200 account page whose panel carries data-grant-state absent and the sentence No current record", "layer": "request"}
    it "says there is no record — not that one lapsed" do
      get account_path

      expect(response).to have_http_status(:ok)
      expect(panel_state).to eq("absent")
      expect(response.body).to include("No current record")
    end

    # "You never had one" and "yours expired" have the same fix and are different facts. The page
    # must not report an age it does not have.
    # @intent: {"entity": "RegistrationGrant", "action": "omit age and expiry", "behavior": "with no grant captured the page prints neither a Last refreshed nor a Lapses sentence", "layer": "request"}
    it "reports no age and no expiry" do
      get account_path

      expect(response.body).not_to include("Last refreshed")
      expect(response.body).not_to include("Lapses")
    end
  end

  describe "with a current grant" do
    let!(:grant) do
      create_registration_grant(user: person,
                                registrable: ["acme/billing-service", "acme/checkout"],
                                captured_at: 2.days.ago)
    end

    # The three facts criterion 5 asks for, in one example because they are one sentence to a
    # reader: when it was refreshed, how much it covers, and when it lapses.
    # @intent: {"entity": "RegistrationGrant", "action": "state age coverage expiry", "behavior": "a grant captured 2 days ago renders Last refreshed 2 days ago, Repositories covered, Lapses in 5 days and data-grant-state current", "layer": "request"}
    it "states when registration access was last refreshed, what it covers, and when it lapses" do
      get account_path

      expect(response.body).to include("Last refreshed").and include("2 days ago")
      expect(response.body).to include("Repositories covered")
      expect(response.body).to include("Lapses").and include("in 5 days")
      expect(panel_state).to eq("current")
    end

    # The count is the REGISTRABLE set, which is the set that actually permits anything —
    # `visible_full_names` grants nothing and would overstate what the reader can do.
    # @intent: {"entity": "RegistrationGrant", "action": "count registrable set", "behavior": "the Repositories covered figure is 2, taken from the registrable pair rather than the three-repository visible set it also widened", "layer": "request"}
    it "counts the repositories it can register, not the wider visible set" do
      grant.update!(visible_full_names: %w[acme/billing-service acme/checkout acme/ledger])

      get account_path

      expect(response.body).to include(">2</dd>")
      expect(response.body).not_to include(">3</dd>")
    end

    # The expiry shown must be the bound actually enforced. Asserted by MOVING the grant to a
    # timestamp derived from `MAX_AGE` and reading the page back, so a literal seven days written
    # into the view would survive an edit to the constant and fail here.
    # @intent: {"entity": "RegistrationGrant", "action": "derive expiry from max age", "behavior": "a grant moved to MAX_AGE minus one day ago renders Lapses in 1 day, so the shown bound tracks the constant rather than a literal in the view", "layer": "request"}
    it "derives the expiry from `MAX_AGE` rather than restating it" do
      grant.update!(captured_at: (GithubRegistrationGrant::MAX_AGE - 1.day).ago)

      get account_path

      expect(response.body).to include("Lapses").and include("in 1 day")
      expect(panel_state).to eq("current")
    end
  end

  describe "with a lapsed grant" do
    # A minute past the bound, so the fixture is pinned to `MAX_AGE` itself: widening the bound
    # makes this grant current again and fails here.
    before do
      create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                captured_at: (GithubRegistrationGrant::MAX_AGE + 1.minute).ago)
    end

    # @intent: {"entity": "RegistrationGrant", "action": "render lapsed state", "behavior": "a grant captured past MAX_AGE renders data-grant-state lapsed with the sentences has lapsed and Lapsed", "layer": "request"}
    it "says the record has lapsed, and when" do
      get account_path

      expect(panel_state).to eq("lapsed")
      expect(response.body).to include("has lapsed")
      expect(response.body).to include("Lapsed")
    end

    # The whole point of the page: the state is visible while everything else on it still works.
    # @intent: {"entity": "RegistrationGrant", "action": "report lapse beside healthy key", "behavior": "with a used API key named Agent present the panel still reads lapsed while the key row beside it renders Agent", "layer": "request"}
    it "reports it while the key beside it goes on looking healthy" do
      key = create_user_api_key(user: person, name: "Agent")
      key.touch_last_used!

      get account_path

      expect(response.body).to include("Agent")
      expect(panel_state).to eq("lapsed")
    end
  end

  # Criterion 5's second half. The affordance already existed and is routed; this points at it
  # rather than building a second one.
  describe "the reconnect affordance" do
    # Spelled the way `spec/requests/github_installation_spec.rb` spells it, and needed for the
    # same reason: the suite's default instance is UNCONFIGURED, and `github_authorize_button`
    # deliberately renders an explanation instead of a link there. That is the helper's own
    # behaviour rather than this page's, and the example below asserts it directly.
    def with_configured_app
      allow(SpecGuard::GithubApp).to receive_messages(
        configured?: true, slug: "specguard", client_id: "Iv1.test", client_secret: "secret"
      )
    end

    # GitHub's answer to "who is this and what do they hold", stubbed at the service the callback
    # exchanges through — the same seam and the same shape `github_installation_spec.rb` uses, so
    # no example here reaches github.com or needs a real code.
    def stub_user_authorization(installation_id: 777, account_login: "acme")
      row = GithubAppUserAuthorization::Installation.new(installation_id: installation_id,
                                                         account_login: account_login)
      allow(GithubAppUserAuthorization).to receive(:authorize).and_return(
        GithubAppUserAuthorization::Authorization.new(token: "ghu_from_callback",
                                                      expires_at: 1.hour.from_now,
                                                      installations: [row])
      )
    end

    before { with_configured_app }

    # @intent: {"entity": "RegistrationGrant", "action": "render reconnect affordance", "behavior": "the page offers a Reconnect GitHub button whose href posts to github_installation_authorize with return_to the new-repository path", "layer": "request"}
    it "posts to the existing `github_installation_authorize` action" do
      get account_path

      expect(response.body).to include(github_installation_authorize_path(return_to: new_repository_path))
      expect(response.body).to include("Reconnect GitHub")
    end

    # @intent: {"entity": "RegistrationGrant", "action": "offer reconnect in every state", "behavior": "the Reconnect GitHub button renders whether the grant is absent, current or lapsed", "layer": "request"}
    it "offers it whether the record is absent, current or lapsed" do
      get account_path
      expect(response.body).to include("Reconnect GitHub")

      create_registration_grant(user: person, captured_at: 1.day.ago)
      get account_path
      expect(response.body).to include("Reconnect GitHub")

      person.github_registration_grant
            .update!(captured_at: (GithubRegistrationGrant::MAX_AGE + 1.minute).ago)
      get account_path
      expect(response.body).to include("Reconnect GitHub")
    end

    # THE EXAMPLE THAT PINS THE PROMISE RATHER THAN THE LINK.
    #
    # The panel tells a lapsed reader "Reconnect GitHub to refresh it", and asserting that the href
    # exists cannot tell whether that sentence is true — an earlier revision of this page rendered a
    # button that completed a full GitHub round trip and refreshed NOTHING, with every affordance
    # example green. So this walks the loop the reader actually walks: render the panel, POST the
    # button EXACTLY as rendered (the `return_to` is read back out of the body rather than written
    # in here, so pointing the button somewhere that does not capture fails HERE), carry `state`
    # through the callback, and assert the STATE MOVED.
    # @intent: {"entity": "RegistrationGrant", "action": "refresh grant via button", "behavior": "POSTing the authorize button exactly as rendered and completing the callback advances grant.captured_at and the panel reads current instead of lapsed", "layer": "request"}
    it "refreshes the grant when the reader follows it, and the panel stops reading lapsed" do
      grant = create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                        captured_at: (GithubRegistrationGrant::MAX_AGE + 1.minute).ago)
      was_captured_at = grant.captured_at
      stub_github
      stub_user_authorization

      get account_path
      expect(panel_state).to eq("lapsed")
      # The button as the page actually renders it — not a path this example chose.
      return_to = CGI.unescape(response.body[%r{authorize\?return_to=([^"]*)}, 1])

      post github_installation_authorize_path(return_to: return_to)
      state = CGI.unescape(response.location[/state=([^&]*)/, 1])
      get github_installation_callback_path, params: { installation_id: 777, code: "abc", state: state }
      follow_redirect!

      expect(grant.reload.captured_at).to be > was_captured_at

      get account_path
      expect(panel_state).to eq("current")
    end

    # WHY THE BUTTON DOES NOT RETURN TO THIS PAGE, stated as a test rather than only as a comment,
    # because it reads like an oversight and would be "tidied" back. Capture is memoized and LAZY
    # inside `GithubRepositoryListing#github_sources`, so it fires only where a view renders a
    # picker — and `AccountsController` does not include that concern. Returning here would look
    # correct and refresh nothing.
    # @intent: {"entity": "RegistrationGrant", "action": "return to capture page", "behavior": "the button's return_to is the new-repository path and never the account path, and AccountsController does not include GithubRepositoryListing", "layer": "request"}
    it "returns to a page that can actually capture, which this one cannot" do
      get account_path

      expect(response.body).to include(github_installation_authorize_path(return_to: new_repository_path))
      expect(response.body).not_to include(github_installation_authorize_path(return_to: account_path))
      expect(AccountsController.include?(GithubRepositoryListing)).to be(false)
    end
  end

  # THE INVARIANT THIS PAGE MOST HAD TO PRESERVE. The sole `GithubRegistrationGrant.capture` call
  # site is `GithubRepositoryListing#github_sources`, deliberately — a GitHub read the browser was
  # making anyway. Refreshing from here would add a page-walk per installation to a page that lists
  # no repositories, and would silently make the account page the second refresh point the ticket
  # forbids.
  describe "the cost of rendering it" do
    # @intent: {"entity": "RegistrationGrant", "action": "render without github calls", "behavior": "rendering the account page with a current grant issues no GitHub calls and still answers 200 ok", "layer": "request"}
    it "makes no GitHub call" do
      create_registration_grant(user: person, captured_at: 3.days.ago)
      github = stub_github

      get account_path

      expect(response).to have_http_status(:ok)
      expect(github.calls).to be_empty
    end

    # @intent: {"entity": "RegistrationGrant", "action": "leave grant untouched", "behavior": "rendering the page neither calls GithubRegistrationGrant.capture nor changes any attribute of the existing grant", "layer": "request"}
    it "neither captures a grant nor restamps the one it reads" do
      grant = create_registration_grant(user: person, captured_at: 3.days.ago)
      before_state = grant.attributes

      expect(GithubRegistrationGrant).not_to receive(:capture)

      get account_path

      expect(grant.reload.attributes).to eq(before_state)
    end

    # One read of the grant for the page, through the `has_one`. A second would mean the view had
    # gone back for it rather than reading what the controller loaded.
    # @intent: {"entity": "RegistrationGrant", "action": "read grant once", "behavior": "the page reads the github_registration_grants table exactly once through the has_one association", "layer": "request"}
    it "reads the grant once" do
      create_registration_grant(user: person)

      statements = queries_against("github_registration_grants") { get account_path }

      expect(statements.size).to eq(1)
    end
  end

  # A grant is one per person (unique index on `user_id`), and the page reads it through the
  # association off the SESSION — there is no parameter through which somebody else's could be
  # asked for.
  # @intent: {"entity": "RegistrationGrant", "action": "scope to own grant", "behavior": "a stranger's grant renders nothing of itself \u2014 panel_state stays absent and the stranger-only repository name never appears", "layer": "request"}
  it "shows the signed-in person's own grant and nobody else's" do
    stranger = create_user(github_uid: "9009", github_handle: "hubot")
    create_registration_grant(user: stranger, registrable: ["acme/stranger-only"])

    get account_path

    expect(panel_state).to eq("absent")
    expect(response.body).not_to include("stranger-only")
  end
end
