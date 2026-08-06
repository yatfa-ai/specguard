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
end
