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

    # @intent: { entity: "Repository registration", action: "register under a grant", behavior: "a POST with a person key and a grant naming the name creates the repository owned by that person and answers 201 with its id", layer: "request" }
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
    # @intent: { entity: "registration api key", action: "mint a working key in the exchange", behavior: "the response token authenticates a follow-up read on the new repository, proving it is the real credential not a plausible string", layer: "request" }
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
    # @intent: { entity: "registration api key", action: "store no plaintext", behavior: "the stored row matches the digest and no attribute anywhere on it contains the revealed token", layer: "request" }
    it "stores no column carrying the plaintext it just revealed" do
      register("acme/billing-service")
      token = response.parsed_body.dig("api_key", "token")

      row = ApiKey.last
      expect(row.token_digest).to eq(ApiKey.digest(token))
      expect(row.attributes.values.map(&:to_s)).not_to include(a_string_including(token))
    end

    # Attribution, which is the one property of this key that CANNOT be repaired after the fact:
    # `ApiKeysController#destroy` is a hard `destroy!` with no audit row, so a key minted with a
    # NULL creator is unattributed forever — the reason `add_created_by_user_to_api_keys` went to
    # the trouble of a backfill rather than starting the column empty.
    #
    # Asserted on the STORED row, and on the person rather than on "not nil", because the only
    # candidate this request could get wrong is a different one: ownership and authorship are the
    # same person here, so an implementation reading either off the repository would also pass a
    # nil-check. `repositories/_api_keys` renders this column, and "Unknown" is a sentence about a
    # key minted before attribution existed or whose creator was deleted — neither is true of one
    # minted a second ago by a person who is still here.
    # @intent: { entity: "registration api key", action: "record the creator", behavior: "the minted key names the person whose grant was redeemed as created_by, an attribution that cannot be repaired after the fact", layer: "request" }
    it "records the person who minted it as its creator" do
      register("acme/billing-service")

      expect(ApiKey.last.created_by_user).to eq(person)
    end

    # The response promises a repository AND a key, so the two writes are one transaction. Without
    # it a failed mint leaves the caller holding a registration they cannot deliver to and cannot
    # re-register — the retry is refused as already taken — with no API path out, because minting a
    # key over the API is a slice that has not shipped.
    #
    # The stub is the shape of the only failure that is real: `token_digest` carries a unique index.
    # @intent: { entity: "Repository registration", action: "roll back on a failed mint", behavior: "when the promised key cannot be saved the whole registration unwinds and no repository row is left behind", layer: "request" }
    it "registers nothing when the key it promised cannot be minted" do
      allow_any_instance_of(ApiKey).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect do
        register("acme/billing-service")
      rescue ActiveRecord::RecordNotUnique
        nil
      end.not_to change(Repository, :count)
    end

    # `Repository#normalize_full_name` runs before the grant is consulted (the gate's `valid?` step),
    # and the grant is keyed case-insensitively for the reason `InstallationRepositories
    # .verify_batch` gives: GitHub logins and repository names are.
    # @intent: { entity: "Repository registration", action: "match the grant case-insensitively", behavior: "a differently-cased org/repo spelling still redeems the grant because normalization and matching fold case", layer: "request" }
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

    # @intent: { entity: "Repository registration", action: "refuse an unknown name", behavior: "a name outside both grant sets answers 400 with the not-in-installation sentence and writes nothing", layer: "request" }
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
    # @intent: { entity: "Repository registration", action: "refuse a visible non-admin repo", behavior: "a repository the person can see but does not administer gets its own refusal sentence distinct from the unknown-name one", layer: "request" }
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
    # @intent: { entity: "Repository registration", action: "refuse a malformed name first", behavior: "a name that is not org/repo is refused by the record own rules before the grant is ever consulted", layer: "request" }
    it "still refuses a name that is not org/repo" do
      expect { register("nonsense") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("must look like org/repo")
    end

    # @intent: { entity: "Repository registration", action: "refuse a taken name", behavior: "a name another account already registered is refused 400 even though the grant names it", layer: "request" }
    it "refuses a name another account already registered" do
      create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                        github_full_name: "acme/billing-service")

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
    end

  end

  # SPGD-775 — the RACE the sequential refusal above cannot win.
  #
  # The uniqueness validation's SELECT runs before the INSERT, so a row that appears in between is
  # invisible to it and the unique index is what refuses, as `ActiveRecord::RecordNotUnique`.
  #
  # This action is the worst-placed reader of that exception: the save sits inside an explicit
  # `ActiveRecord::Base.transaction`, which a plain `save` JOINS rather than savepoints, so the
  # violation aborted the enclosing transaction and propagated out of the action as a BARE 500 with
  # no JSON body — for the condition the sequential path answers with a 400 and a sentence.
  # `Repository#save` contains it now, and the containment reaches here with no change to this
  # controller: `next false` -> `render_bad_request(repository.errors.full_messages)`.
  #
  # The race is simulated by silencing the uniqueness validation, which is exactly what it does on
  # its own when it cannot see the winning row yet (spec/support/uniqueness_race.rb). A spec that
  # merely registered the same name twice in sequence would prove nothing: the validation catches
  # that unaided, so it would pass with or without any of this.
  describe "when it LOSES the uniqueness race" do
    let(:rival) { create_user(github_uid: "2002", github_handle: "hubot") }

    before { create_registration_grant(user: person, registrable: %w[acme/billing-service acme/ledger]) }

    # @intent: { entity: "Repository registration", action: "lose the race politely", behavior: "when the unique index refuses what the validation missed the answer is a 400 with a JSON body, not a bare 500", layer: "request" }
    it "answers 400 with a body rather than a bare 500" do
      create_repository(user: rival, github_full_name: "acme/billing-service")
      allow(uniqueness_validator(Repository)).to receive(:validate_each)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(response.parsed_body["message"]).to include("has already been taken")
    end

    # ...and the refusal has to leave the CONNECTION usable, not merely answer politely. Without the
    # savepoint the rescue would hand back a tidy `false` while Postgres refused every subsequent
    # statement with `PG::InFailedSqlTransaction` — worse than the 500, because it reports success at
    # refusing. A SECOND registration on the same connection is the assertion: it either serves, or
    # the connection is already dead.
    #
    # Only the raced name is silenced, so the control that follows is refused by nothing.
    # @intent: { entity: "Repository registration", action: "leave the connection usable", behavior: "after the raced refusal the connection still serves a second registration and the refused attempt left no key behind", layer: "request" }
    it "leaves the connection usable for the next registration" do
      create_repository(user: rival, github_full_name: "acme/billing-service")
      allow(uniqueness_validator(Repository)).to receive(:validate_each).and_wrap_original do |original, *args|
        args.first.github_full_name == "acme/billing-service" ? nil : original.call(*args)
      end

      register("acme/billing-service")
      expect(response).to have_http_status(:bad_request)

      # Nothing half-registered either: the transaction rolled back as a unit, so the refused row
      # left no `sgk_` key behind.
      expect(ApiKey.joins(:repository).where(repositories: { github_full_name: "acme/billing-service" }))
        .to be_empty

      expect { register("acme/ledger") }.to change(Repository, :count).by(1)
      expect(response).to have_http_status(:created)
    end
  end

  # SPGD-756 criterion 6 and call #6 — the fail-open decay a snapshot buys, and the two halves that
  # bound it. Both land on `:not_granted`, whose sentence names a fix neither other refusal does.
  describe "when there is no current grant to redeem" do
    # @intent: { entity: "GithubRegistrationGrant", action: "refuse a person with no grant", behavior: "a person who never had a grant gets the not-granted sentence naming the SpecGuard-side fix", layer: "request" }
    it "refuses a person who has never had one" do
      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    # @intent: { entity: "GithubRegistrationGrant", action: "refuse a stale grant", behavior: "a grant past its age bound is refused with the same not-granted sentence even when it names the repository", layer: "request" }
    it "refuses a grant past its bound, even though it names the repository" do
      create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    # The control the example above needs: without it, a bound of zero would pass it.
    # @intent: { entity: "GithubRegistrationGrant", action: "redeem an old but current grant", behavior: "a grant just inside the bound still registers, the control that pins the bound actually divides", layer: "request" }
    it "still redeems a grant that is old but inside the bound" do
      create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago + 1.hour)

      expect { register("acme/billing-service") }.to change(Repository, :count).by(1)
    end

    # The distinguishability half of criterion 6, asserted as a property of the strings rather than
    # by re-reading either of them: a refusal a client cannot tell apart from "you are not an
    # administrator" sends a person to GitHub when the fix is in SpecGuard.
    # @intent: { entity: "GithubRegistrationGrant", action: "keep refusals distinguishable", behavior: "the not-granted message differs from every other refusal sentence so a client is not sent to GitHub for a SpecGuard fix", layer: "request" }
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

    # @intent: { entity: "GithubRegistrationGrant", action: "redeem across keys", behavior: "a second key of the same person redeems the same grant, because the grant belongs to the person not the key", layer: "request" }
    it "redeems the same grant from a second key the same person holds" do
      laptop = create_user_api_key(user: person, name: "Laptop")
      agent = create_user_api_key(user: person, name: "Agent")

      register("acme/billing-service", token: laptop.raw_token)
      expect(response).to have_http_status(:created)

      register("acme/checkout", token: agent.raw_token)
      expect(response).to have_http_status(:created)
    end

    # @intent: { entity: "GithubRegistrationGrant", action: "survive a key revocation", behavior: "destroying one key does not change what a surviving key of the same person can register", layer: "request" }
    it "leaves the surviving key registering exactly as before when another is revoked" do
      lost = create_user_api_key(user: person, name: "Lost laptop")
      kept = create_user_api_key(user: person, name: "Agent")
      lost.destroy!

      expect { register("acme/billing-service", token: kept.raw_token) }
        .to change(Repository, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    # Somebody else's grant is not evidence about this person, and neither is somebody else's key.
    # @intent: { entity: "GithubRegistrationGrant", action: "refuse another person grant", behavior: "somebody else grant is not evidence about this person, so the POST is refused 400 with nothing written", layer: "request" }
    it "does not let one person redeem another person's grant" do
      stranger = create_user(github_uid: "2002", github_handle: "hubot")
      create_registration_grant(user: stranger, registrable: ["acme/payments"])

      expect { register("acme/payments") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
    end
  end

  # SPGD-756 criterion 9 — inherited from `UserApiKey.authenticate`, asserted rather than assumed.
  # @intent: { entity: "Repository registration", action: "refuse an archived owner", behavior: "archiving the person makes their key unauthenticated, so nothing registers however good the grant", layer: "request" }
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
  # @intent: { entity: "Repository registration", action: "refuse a repository key", behavior: "an sgk repository credential resolves no person and is refused 401 before anything is written", layer: "request" }
  it "refuses a repository key, and writes nothing" do
    create_registration_grant(user: person, registrable: ["acme/checkout"])
    repository_key = create_repository(user: person).api_keys.create!

    expect { register("acme/checkout", token: repository_key.raw_token) }
      .not_to change(Repository, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  # @intent: { entity: "Repository registration", action: "refuse a credential-less POST", behavior: "a request with no Authorization header at all writes nothing and answers 401", layer: "request" }
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
  # @intent: { entity: "Repository registration", action: "redeem a browser-minted grant", behavior: "a person picker visit in the browser leaves a grant an agent key redeems minutes later with no session and no GitHub call", layer: "request" }
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
