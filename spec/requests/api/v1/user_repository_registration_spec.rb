# frozen_string_literal: true

require "rails_helper"

# SPGD-756 — `POST /api/v1/repositories`, the endpoint that lets an agent register a repository
# WITHOUT the GitHub credential registration has always needed, and without skipping the check that
# credential exists to make.
#
# The evidence is a `GithubRegistrationGrant`: what GitHub said about this person, recorded while a
# browser session still held a token that could ask. `spec/requests/github_registration_grant_spec.rb`
# covers how one is minted; this file covers what redeeming one does and — mostly — what it refuses.
#
# NOTHING HERE SIGNS IN. That is a property under test rather than a convenience: the endpoint must
# reach for no session, and a spec that established one could not tell an implementation that reads
# `current_user` apart from one that does not.
RSpec.describe "API v1 — POST /api/v1/repositories", type: :request do
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:user_api_key) { create_user_api_key(user: person) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def register(full_name, token: user_api_key.raw_token)
    post "/api/v1/repositories", params: { github_full_name: full_name }, as: :json,
                                 headers: bearer(token)
  end

  # SPGD-756 criterion 1.
  describe "when the grant names the repository" do
    before { create_registration_grant(user: person, registrable: ["acme/billing-service"]) }

    it "registers it to the person the key speaks for" do
      expect { register("acme/billing-service") }.to change(Repository, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(Repository.last.user).to eq(person)
      expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")
      expect(response.parsed_body.dig("repository", "id")).to eq(Repository.last.id)
    end

    # The `sgk_` key is minted in the SAME exchange, because a repository with no key is a
    # repository nothing can deliver to and an agent has no second endpoint to mint one from.
    #
    # Asserted by USING the token rather than by matching its shape: `GET /api/v1/repository`
    # authenticating on it is the only evidence that what came back is the real credential and not
    # a plausible-looking string.
    it "hands back a working first key for it" do
      register("acme/billing-service")

      token = response.parsed_body.dig("api_key", "token")
      expect(token).to start_with("sgk_")

      get "/api/v1/repository", headers: bearer(token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")
    end

    # Reveal-once, asserted on the STORED ROW rather than on the model's documentation of itself.
    # Every attribute is checked, not just `token_digest`, so a column added later that happened to
    # carry the plaintext would fail here.
    it "stores no column carrying the plaintext it just revealed" do
      register("acme/billing-service")
      token = response.parsed_body.dig("api_key", "token")

      row = ApiKey.last
      expect(row.token_digest).to eq(ApiKey.digest(token))
      expect(row.attributes.values.map(&:to_s)).not_to include(a_string_including(token))
    end

    # `Repository#normalize_full_name` runs before the grant is consulted (the gate's `valid?` step),
    # and the grant is keyed case-insensitively for the reason `InstallationRepositories
    # .verify_batch` gives: GitHub logins and repository names are.
    it "matches the grant case-insensitively" do
      expect { register("ACME/Billing-Service") }.to change(Repository, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end

  # SPGD-756 criterion 2 — the criterion that decides the ticket. The runbook this endpoint replaces
  # wrote the row the ownership check would have gated; this is the assertion that the endpoint does
  # not.
  describe "when the grant does not name the repository" do
    before do
      create_registration_grant(user: person,
                                registrable: ["acme/billing-service"],
                                visible: ["acme/billing-service", "acme/ledger"])
    end

    it "refuses a name GitHub never told this person about, and writes nothing" do
      expect { register("someone-else/private-thing") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_in_installation))
      expect(response.parsed_body["error"]).to eq("bad_request")
    end

    # The ordinary position of an organization's non-admin members, and a DIFFERENT sentence with a
    # different fix. Telling them apart is the entire reason the grant records a visible set beside
    # the set it grants from.
    it "refuses a repository they can see but do not administer, and says which it is" do
      expect { register("acme/ledger") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_administered))
      expect(response.parsed_body["message"])
        .not_to include(InstallationRepositories::MESSAGES.fetch(:not_in_installation))
    end

    # The record's own rules still run, and they run FIRST — see `RepositoryRegistration`. A slug
    # that is not `org/repo` is refused without the grant being consulted at all.
    it "still refuses a name that is not org/repo" do
      expect { register("nonsense") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("must look like org/repo")
    end

    it "refuses a name another account already registered" do
      create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                        github_full_name: "acme/billing-service")

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
    end
  end

  # SPGD-756 criterion 6 and call #6 — the fail-open decay a snapshot buys, and the two halves that
  # bound it. Both land on `:not_granted`, whose sentence names a fix neither other refusal does.
  describe "when there is no current grant to redeem" do
    it "refuses a person who has never had one" do
      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    it "refuses a grant past its bound, even though it names the repository" do
      create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    # The control the example above needs: without it, a bound of zero would pass it.
    it "still redeems a grant that is old but inside the bound" do
      create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago + 1.hour)

      expect { register("acme/billing-service") }.to change(Repository, :count).by(1)
    end

    # The distinguishability half of criterion 6, asserted as a property of the strings rather than
    # by re-reading either of them: a refusal a client cannot tell apart from "you are not an
    # administrator" sends a person to GitHub when the fix is in SpecGuard.
    it "says something no other refusal says" do
      expect(InstallationRepositories::MESSAGES.fetch(:not_granted))
        .not_to eq(InstallationRepositories::MESSAGES.fetch(:not_administered))
      expect(InstallationRepositories::MESSAGES.fetch(:not_granted))
        .not_to eq(InstallationRepositories::MESSAGES.fetch(:not_in_installation))
      expect(InstallationRepositories::MESSAGES.fetch(:not_granted))
        .not_to eq(InstallationRepositories::MESSAGES.fetch(:not_authorized))
    end
  end

  # SPGD-756 criterion 7 and call #1. The grant is a statement about the PERSON, because the
  # roadmap's first non-goal is that a key's reach IS the person's reach. A per-key grant would
  # narrow that, and would give one person as many divergent opinions about their GitHub access as
  # they hold keys.
  describe "the grant belongs to the person, not to the key" do
    before { create_registration_grant(user: person, registrable: %w[acme/billing-service acme/checkout]) }

    it "redeems the same grant from a second key the same person holds" do
      laptop = create_user_api_key(user: person, name: "Laptop")
      agent = create_user_api_key(user: person, name: "Agent")

      register("acme/billing-service", token: laptop.raw_token)
      expect(response).to have_http_status(:created)

      register("acme/checkout", token: agent.raw_token)
      expect(response).to have_http_status(:created)
    end

    it "leaves the surviving key registering exactly as before when another is revoked" do
      lost = create_user_api_key(user: person, name: "Lost laptop")
      kept = create_user_api_key(user: person, name: "Agent")
      lost.destroy!

      expect { register("acme/billing-service", token: kept.raw_token) }
        .to change(Repository, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    # Somebody else's grant is not evidence about this person, and neither is somebody else's key.
    it "does not let one person redeem another person's grant" do
      stranger = create_user(github_uid: "2002", github_handle: "hubot")
      create_registration_grant(user: stranger, registrable: ["acme/payments"])

      expect { register("acme/payments") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
    end
  end

  # SPGD-756 criterion 9 — inherited from `UserApiKey.authenticate`, asserted rather than assumed.
  it "registers nothing for an archived owner, however good their grant is" do
    create_registration_grant(user: person, registrable: ["acme/billing-service"])
    token = user_api_key.raw_token
    person.update!(archived_at: Time.current)

    expect { register("acme/billing-service", token: token) }.not_to change(Repository, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  # The credential seam, in the direction this new verb opens. A `sgk_` repository key is a
  # perfectly valid credential and resolves no person, so it must be refused here — and refused
  # BEFORE anything is written.
  it "refuses a repository key, and writes nothing" do
    create_registration_grant(user: person, registrable: ["acme/checkout"])
    repository_key = create_repository(user: person).api_keys.create!

    expect { register("acme/checkout", token: repository_key.raw_token) }
      .not_to change(Repository, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a request carrying no credential at all" do
    expect { post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" }, as: :json }
      .not_to change(Repository, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  # THE WHOLE POINT, END TO END, through both real paths: a person looks at their repository list in
  # a browser, which mints the grant for free, and an agent holding their key registers minutes
  # later with no session and no GitHub credential anywhere near it.
  #
  # This is the one example here that signs in, and it does so BEFORE the key is used rather than
  # around it — the browser's part is over by the time the API request is made.
  it "lets a browser's look at the picker become an agent's registration" do
    stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/ledger", admin: false)])
    user = sign_in_via_github
    get new_repository_path
    key = create_user_api_key(user: user)

    expect { register("acme/billing-service", token: key.raw_token) }.to change(Repository, :count).by(1)
    expect(response).to have_http_status(:created)

    expect { register("acme/ledger", token: key.raw_token) }.not_to change(Repository, :count)
    expect(response.parsed_body["message"])
      .to include(InstallationRepositories::MESSAGES.fetch(:not_administered))
  end
end
