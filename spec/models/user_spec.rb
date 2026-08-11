# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  let(:auth) do
    OmniAuth::AuthHash.new(
      "provider" => "github", "uid" => "1001",
      "info" => { "nickname" => "octocat", "email" => "octocat@example.com",
                  "image" => "https://example.test/avatar.png" }
    )
  end

  it "creates a user from a GitHub identity" do
    user = described_class.from_github_omniauth(auth)

    expect(user).to be_persisted
    expect(user.github_handle).to eq("octocat")
    expect(user.email).to eq("octocat@example.com")
    expect(user.avatar_url).to eq("https://example.test/avatar.png")
  end

  it "keys on the GitHub uid, so a renamed handle stays the same user" do
    original = described_class.from_github_omniauth(auth)
    renamed = described_class.from_github_omniauth(
      OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "octocat-renamed" }))
    )

    expect(renamed.id).to eq(original.id)
    expect(renamed.github_handle).to eq("octocat-renamed")
    expect(described_class.count).to eq(1)
  end

  # The whole reason `created_api_keys` is `dependent: :nullify` and not `dependent: :destroy` like
  # every other association in this codebase. A key belongs to the *repository*; the person who
  # minted it is an attribution, not an owner. Deleting a departed collaborator must never revoke
  # the credential the owner's CI is authenticating with — it must only forget who minted it.
  describe "deleting a user who minted keys on someone else's repository" do
    let(:owner) { described_class.create!(github_uid: "1001", github_handle: "octocat") }
    let(:collaborator) { described_class.create!(github_uid: "9999", github_handle: "departing-dev") }
    let(:repository) { create_repository(user: owner) }

    it "nullifies the attribution and leaves the key working" do
      api_key = repository.api_keys.create!(name: "CI — main", created_by_user: collaborator)
      raw_token = api_key.raw_token

      expect { collaborator.destroy }.not_to change(ApiKey, :count)

      expect(api_key.reload.created_by_user).to be_nil
      # Not just present — still a live credential on the Bearer path.
      expect(ApiKey.authenticate(raw_token)).to eq(api_key)
    end

    it "does not touch keys minted by anyone else" do
      owners_key = repository.api_keys.create!(name: "Owner's key", created_by_user: owner)

      collaborator.destroy

      expect(owners_key.reload.created_by_user).to eq(owner)
    end
  end

  describe "handle normalization" do
    it "stores a mixed-case, padded handle in canonical form" do
      user = create_user(github_handle: "  Octocat  ")

      expect(user.reload.github_handle).to eq("octocat")
    end

    it "normalizes the handle taken from a GitHub identity" do
      user = described_class.from_github_omniauth(
        OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "Octocat" }))
      )

      expect(user.reload.github_handle).to eq("octocat")
    end

    it "leaves a blank handle blank so the presence validation still fires" do
      user = described_class.new(github_uid: "1001", github_handle: "   ")

      expect(user).not_to be_valid
      expect(user.errors[:github_handle]).to be_present
    end
  end

  describe ".resolve_by_handle" do
    it "resolves a handle regardless of the case and padding the caller typed" do
      user = create_user(github_handle: "Octocat")

      ["OCTOCAT", "octocat", " Octocat ", "OctoCat"].each do |typed|
        resolution = described_class.resolve_by_handle(typed)

        expect(resolution).to be_found, "expected #{typed.inspect} to resolve, got #{resolution.status}"
        expect(resolution.user).to eq(user)
        expect(resolution.match_count).to eq(1)
      end
    end

    it "reports a handle nobody holds as not found, without raising" do
      create_user(github_handle: "octocat")

      resolution = described_class.resolve_by_handle("nobody-here")

      expect(resolution).to be_not_found
      expect(resolution).not_to be_ambiguous
      expect(resolution).not_to be_malformed
      expect(resolution.user).to be_nil
      expect(resolution.match_count).to eq(0)
    end

    # "that is not a GitHub handle" and "nobody has signed in with that handle" are different facts,
    # and a caller that cannot tell them apart gives the wrong advice: an owner who pasted a profile
    # URL would be told to go ask their colleague to re-authenticate.
    it "reports a query that is not handle-shaped as malformed, distinctly from not found" do
      create_user(github_handle: "octocat")

      ["", "   ", nil, "octo/cat", "octo cat", "https://github.com/octocat", "-octocat", "a" * 40].each do |typed|
        resolution = described_class.resolve_by_handle(typed)

        expect(resolution).to be_malformed, "expected #{typed.inspect} to be malformed, got #{resolution.status}"
        expect(resolution).not_to be_not_found
        expect(resolution).not_to be_found
        expect(resolution.user).to be_nil
        expect(resolution.match_count).to eq(0)
      end
    end

    # `from_github_omniauth` falls back to the display name when `nickname` is blank, so a row can
    # hold a string GitHub never issued as a login. Sign-in must keep working (decision b), but such
    # a value is not an identity anyone can be invited by — resolving it must not hand back the row.
    it "does not resolve a handle the fallback chain manufactured" do
      user = described_class.from_github_omniauth(
        OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "", "name" => "The Octocat" }))
      )

      expect(user.reload.github_handle).to eq("the octocat")
      expect(described_class.resolve_by_handle("The Octocat")).to be_malformed
      expect(described_class.resolve_by_handle("the octocat")).to be_malformed
      expect(described_class.resolve_by_handle("the octocat")).not_to be_found
    end

    # A row holds whatever handle its owner had at their last sign-in, so a recycled GitHub handle
    # can legitimately sit on two rows. Picking one would grant access to the wrong person.
    context "when a recycled handle sits on two rows" do
      let!(:renamer) { create_user(github_uid: "1001", github_handle: "octocat") }
      let!(:claimant) { create_user(github_uid: "2002", github_handle: "Octocat") }

      it "keeps both rows — the collision is legal, not a validation error" do
        expect(renamer).to be_persisted
        expect(claimant).to be_persisted
        expect(described_class.where(github_handle: "octocat").count).to eq(2)
      end

      it "reports ambiguity instead of picking a row" do
        resolution = described_class.resolve_by_handle("OCTOCAT")

        expect(resolution).to be_ambiguous
        expect(resolution).not_to be_found
        expect(resolution.match_count).to eq(2)
        expect(resolution.user).to be_nil
        expect(resolution.user).not_to eq(renamer)
        expect(resolution.user).not_to eq(claimant)
      end
    end
  end

  # The GitHub authorization the app holds on this user's behalf. Everything ownership verification
  # can do rests on it, and it is the only secret this table stores.
  describe "the stored GitHub authorization" do
    describe "#github_scopes" do
      # Read off what GitHub reported granting, never off what was requested. A user can uncheck an
      # organization on the consent screen and come back with less than was asked for; treating the
      # request as the grant is how a feature ends up calling an API it has no scope for.
      it "reads the granted scopes, however GitHub spaced them" do
        user = create_user(github_token_scopes: nil)
        user.assign_github_authorization("credentials" => { "token" => "gho_x" },
                                         "extra" => { "scope" => " Repo , read:user " })

        expect(user.github_scopes).to eq(Set["repo", "read:user"])
      end

      it "is empty rather than nil when nothing was granted" do
        expect(create_user(github_token_scopes: nil).github_scopes).to be_empty
      end
    end

    describe "#github_repository_access?" do
      it "is true for a token carrying repo" do
        expect(create_user(github_token_scopes: "repo,read:user")).to be_github_repository_access
      end

      # A narrower grant is a usable answer, not a dead end: a user who granted only `public_repo`
      # simply will not see their private repositories in the picker.
      it "is true for a token carrying public_repo alone" do
        expect(create_user(github_token_scopes: "public_repo")).to be_github_repository_access
      end

      # A live token at the sign-in scopes cannot read repositories. This is what every user looks
      # like between signing in and first registering something.
      it "is false for a token carrying only the sign-in scopes" do
        expect(create_user(github_token_scopes: "read:user,user:email"))
          .not_to be_github_repository_access
      end

      it "is false when there is no token, whatever the scopes column says" do
        expect(create_user(github_access_token: nil, github_token_scopes: "repo"))
          .not_to be_github_repository_access
      end
    end

    describe "#assign_github_authorization" do
      it "records the token, the scopes and when the grant was made" do
        user = create_user(github_access_token: nil, github_token_scopes: nil)

        user.assign_github_authorization("credentials" => { "token" => "gho_new" },
                                         "extra" => { "scope" => "repo" })

        expect(user.github_access_token).to eq("gho_new")
        expect(user.github_token_scopes).to eq("repo")
        expect(user.github_token_updated_at).to be_present
      end

      # A callback without a token is not evidence of a revocation. Clearing on one would demote a
      # user who had already connected, silently, on their next ordinary sign-in.
      it "leaves an existing grant alone when the callback carries no token" do
        user = create_user(github_access_token: "gho_kept", github_token_scopes: "repo")

        user.assign_github_authorization("info" => {})

        expect(user.github_access_token).to eq("gho_kept")
        expect(user.github_token_scopes).to eq("repo")
      end
    end

    # Rotating the encryption keys is survivable rather than a 500 on every page that asks whether
    # GitHub is connected: an unopenable envelope is operationally identical to no token, and the
    # user is walked through authorizing again.
    it "reports a token it cannot decrypt as absent rather than raising" do
      user = create_user
      User.connection.execute(
        "UPDATE users SET github_access_token = 'not-an-envelope' WHERE id = #{user.id}"
      )

      expect { user.reload.github_access_token }.not_to raise_error
      expect(user.reload.github_access_token).to be_nil
      expect(user.reload).not_to be_github_repository_access
    end
  end
end
