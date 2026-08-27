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
    it "says there is no record — not that one lapsed" do
      get account_path

      expect(response).to have_http_status(:ok)
      expect(panel_state).to eq("absent")
      expect(response.body).to include("No current record")
    end

    # "You never had one" and "yours expired" have the same fix and are different facts. The page
    # must not report an age it does not have.
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
    it "states when registration access was last refreshed, what it covers, and when it lapses" do
      get account_path

      expect(response.body).to include("Last refreshed").and include("2 days ago")
      expect(response.body).to include("Repositories covered")
      expect(response.body).to include("Lapses").and include("in 5 days")
      expect(panel_state).to eq("current")
    end

    # The count is the REGISTRABLE set, which is the set that actually permits anything —
    # `visible_full_names` grants nothing and would overstate what the reader can do.
    it "counts the repositories it can register, not the wider visible set" do
      grant.update!(visible_full_names: %w[acme/billing-service acme/checkout acme/ledger])

      get account_path

      expect(response.body).to include(">2</dd>")
      expect(response.body).not_to include(">3</dd>")
    end

    # The expiry shown must be the bound actually enforced. Asserted by MOVING the grant to a
    # timestamp derived from `MAX_AGE` and reading the page back, so a literal seven days written
    # into the view would survive an edit to the constant and fail here.
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

    it "says the record has lapsed, and when" do
      get account_path

      expect(panel_state).to eq("lapsed")
      expect(response.body).to include("has lapsed")
      expect(response.body).to include("Lapsed")
    end

    # The whole point of the page: the state is visible while everything else on it still works.
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

    before { with_configured_app }

    it "posts to the existing `github_installation_authorize` action" do
      get account_path

      expect(response.body).to include(github_installation_authorize_path(return_to: account_path))
      expect(response.body).to include("Reconnect GitHub")
    end

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
  end

  # THE INVARIANT THIS PAGE MOST HAD TO PRESERVE. The sole `GithubRegistrationGrant.capture` call
  # site is `GithubRepositoryListing#github_sources`, deliberately — a GitHub read the browser was
  # making anyway. Refreshing from here would add a page-walk per installation to a page that lists
  # no repositories, and would silently make the account page the second refresh point the ticket
  # forbids.
  describe "the cost of rendering it" do
    it "makes no GitHub call" do
      create_registration_grant(user: person, captured_at: 3.days.ago)
      github = stub_github

      get account_path

      expect(response).to have_http_status(:ok)
      expect(github.calls).to be_empty
    end

    it "neither captures a grant nor restamps the one it reads" do
      grant = create_registration_grant(user: person, captured_at: 3.days.ago)
      before_state = grant.attributes

      expect(GithubRegistrationGrant).not_to receive(:capture)

      get account_path

      expect(grant.reload.attributes).to eq(before_state)
    end

    # One read of the grant for the page, through the `has_one`. A second would mean the view had
    # gone back for it rather than reading what the controller loaded.
    it "reads the grant once" do
      create_registration_grant(user: person)

      statements = queries_against("github_registration_grants") { get account_path }

      expect(statements.size).to eq(1)
    end
  end

  # A grant is one per person (unique index on `user_id`), and the page reads it through the
  # association off the SESSION — there is no parameter through which somebody else's could be
  # asked for.
  it "shows the signed-in person's own grant and nobody else's" do
    stranger = create_user(github_uid: "9009", github_handle: "hubot")
    create_registration_grant(user: stranger, registrable: ["acme/stranger-only"])

    get account_path

    expect(panel_state).to eq("absent")
    expect(response.body).not_to include("stranger-only")
  end
end
