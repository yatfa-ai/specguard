# frozen_string_literal: true

require "rails_helper"

# SPGD-878 — `PATCH /api/v1/repositories/:id`, the rename verb over the `sgu_` surface. It was
# deferred on a stale premise (rename believed session-bound); `RepositoryRegistration` with the
# recorded `GithubRegistrationGrant` — the same `GrantVerifier` `#create` redeems — makes it
# exactly as session-free as registration.
#
# NOTHING HERE SIGNS IN, for the same reason as the POST's spec file: the endpoint must reach for
# no session, and a spec that established one could not tell an implementation reading
# `current_user` apart from one that does not.
RSpec.describe "API v1 — PATCH /api/v1/repositories/:id", type: :request do
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:user_api_key) { create_user_api_key(user: person) }
  let(:repository) { create_repository(user: person, github_full_name: "acme/billing-service") }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def rename(new_full_name, id: repository.id, token: user_api_key.raw_token)
    patch "/api/v1/repositories/#{id}", params: { github_full_name: new_full_name }, as: :json,
                                       headers: bearer(token)
  end

  # THE WHOLE POINT OF THE VERB, asserted rather than narrated: rename is pure metadata, and the
  # alternative (remove + re-register) destroys every key and all telemetry. Key and run counts
  # are checked on BOTH sides of the rename so a survivor count cannot pass by accident.
  describe "a successful rename" do
    before do
      create_registration_grant(user: person, registrable: ["acme/billing-service", "acme/ledger"])
      repository.api_keys.create!
      create_test_run(repository: repository)
    end

    # @intent: { entity: "repository", action: "rename in place", behavior: "a successful PATCH is pure metadata - the repository count is unchanged and every api key and test run survives the new full name", layer: "request" }
    it "changes the name and preserves every key and every run" do
      expect { rename("acme/ledger") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:ok)
      repository.reload
      expect(repository.github_full_name).to eq("acme/ledger")
      expect(repository.api_keys.count).to eq(1)
      expect(repository.test_runs.count).to eq(1)

      body = response.parsed_body.dig("repository")
      expect(body["id"]).to eq(repository.id)
      expect(body["full_name"]).to eq("acme/ledger")
    end

    # GitHub logins and repository names are case-insensitive; the grant is keyed to match.
    # @intent: { entity: "registration grant", action: "match case-insensitively", behavior: "the grant match and the stored name are case-insensitive, so ACME/LEDGER renames onto a lowercase grant", layer: "request" }
    it "matches the grant case-insensitively" do
      rename("ACME/LEDGER")

      expect(response).to have_http_status(:ok)
      expect(repository.reload.github_full_name).to eq("ACME/LEDGER")
    end
  end

  # The 404/403 fork `current_repository(:owner)` owns — the same asymmetry as the web `#update`,
  # and the deliberate contrast with `#destroy`, which a member granted `repo.delete` MAY fire.
  # Nil is 404, never 403, for the reason `#show` gives at length.
  describe "who may rename" do
    before { create_registration_grant(user: person, registrable: ["acme/ledger"]) }

    # @intent: { entity: "repository", action: "hide the unopenable", behavior: "a repository the caller cannot even open answers 404 so its existence stays hidden and nothing is written", layer: "request" }
    it "answers 404 for a repository the key's person cannot even open" do
      stranger_repository = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"))

      rename("acme/ledger", id: stranger_repository.id)

      expect(response).to have_http_status(:not_found)
      expect(stranger_repository.reload.github_full_name).to eq("acme/billing-service")
    end

    # @intent: { entity: "repository", action: "refuse a non-owner", behavior: "a non-owner member is refused with 403 even when granted repo.delete, and the name is left alone", layer: "request" }
    it "answers 403 for a non-owner member, even one who could delete it" do
      member = create_user(github_uid: "3003", github_handle: "tri-person")
      create_membership(repository: repository, user: member, permissions: [RepositoryMembership::REPO_DELETE])
      member_key = create_user_api_key(user: member)

      rename("acme/ledger", token: member_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end
  end

  # The gate's own refusals, served in its own vocabulary exactly as `#create` serves them.
  describe "when the grant does not name the new repository" do
    before do
      create_registration_grant(user: person,
                                registrable: ["acme/billing-service"],
                                visible: ["acme/billing-service", "acme/ledger"])
    end

    # @intent: { entity: "registration grant", action: "refuse an unknown name", behavior: "a name outside the installation grant answers 400 with the gate own message and no write happens", layer: "request" }
    it "refuses a name GitHub never told this person about, and writes nothing" do
      expect { rename("someone-else/private-thing") }
        .not_to(change { repository.reload.github_full_name })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_in_installation))
    end

    # @intent: { entity: "registration grant", action: "refuse the unadministered", behavior: "a name the person can see but not administer is refused 400 naming exactly that distinction", layer: "request" }
    it "refuses a repository they can see but do not administer, and says which it is" do
      expect { rename("acme/ledger") }.not_to(change { repository.reload.github_full_name })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_administered))
    end

    # @intent: { entity: "repository", action: "refuse a taken name", behavior: "a full name another account already registered answers 400 with an already-taken message and no write", layer: "request" }
    it "refuses a name another account already registered" do
      create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                        github_full_name: "acme/ledger")

      expect { rename("acme/ledger") }.not_to(change { repository.reload.github_full_name })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("has already been taken")
    end
  end

  # The 403 `#registrable` owns, with the sentence naming the fix neither other refusal does.
  describe "when there is no current grant to redeem" do
    # @intent: { entity: "registration grant", action: "refuse the ungranted", behavior: "a person with no registration grant at all answers 403 not_granted with the fix-naming message and nothing is written", layer: "request" }
    it "refuses a person who has never had one" do
      rename("acme/ledger")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("not_granted")
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    # @intent: { entity: "registration grant", action: "refuse a stale grant", behavior: "a grant past its age bound is treated as absent even though it names the new repository, answering 403 not_granted", layer: "request" }
    it "refuses a grant past its bound, even though it names the new repository" do
      create_registration_grant(user: person, registrable: ["acme/ledger"],
                                captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)

      rename("acme/ledger")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end
  end

  # The credential seam, in the direction this verb opens: a `sgk_` repository key is a valid
  # credential that resolves no person, so it must be refused before anything is written.
  # @intent: { entity: "credential seam", action: "refuse a repository key", behavior: "an sgk_ repository key resolves no person and is refused 401 before anything is written", layer: "request" }
  it "refuses a repository key, and writes nothing" do
    create_registration_grant(user: person, registrable: ["acme/ledger"])
    repository_key = repository.api_keys.create!

    expect { rename("acme/ledger", token: repository_key.raw_token) }
      .not_to(change { repository.reload.github_full_name })

    expect(response).to have_http_status(:unauthorized)
  end

  # @intent: { entity: "credential seam", action: "refuse a bare request", behavior: "a request carrying no credential at all answers 401 and nothing is written", layer: "request" }
  it "refuses a request carrying no credential at all" do
    rename("acme/ledger", token: nil)

    expect(response).to have_http_status(:unauthorized)
  end
end
