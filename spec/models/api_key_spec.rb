# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiKey do
  let(:repository) { create_repository }

  it "never persists the raw token — only its SHA-256 digest" do
    api_key = repository.api_keys.create!

    expect(api_key.raw_token).to start_with("sgk_")
    expect(api_key.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(api_key.raw_token))
    expect(described_class.column_names).not_to include("token")
  end

  it "cannot recover the raw token once reloaded — that is what makes reveal-once true" do
    raw = repository.api_keys.create!.raw_token

    expect(described_class.find_by(token_digest: described_class.digest(raw)).raw_token).to be_nil
  end

  it "issues a distinct token per key" do
    tokens = Array.new(3) { repository.api_keys.create!.raw_token }

    expect(tokens.uniq.size).to eq(3)
  end

  it "authenticates a valid raw token back to its key" do
    api_key = repository.api_keys.create!

    expect(described_class.authenticate(api_key.raw_token)).to eq(api_key)
  end

  it "refuses an unknown or blank token" do
    repository.api_keys.create!

    expect(described_class.authenticate("sgk_nope")).to be_nil
    expect(described_class.authenticate(nil)).to be_nil
    expect(described_class.authenticate("")).to be_nil
  end

  it "exposes a hint that identifies the key without revealing it" do
    api_key = repository.api_keys.create!

    expect(api_key.token_hint).not_to include(api_key.raw_token.delete_prefix("sgk_"))
  end

  describe "#regenerate!" do
    it "stops the previous token authenticating and authenticates the new one" do
      api_key = repository.api_keys.create!
      retired = api_key.raw_token

      api_key.regenerate!

      # Asserted through `authenticate` rather than against the digest column, because resolving a
      # Bearer token is the only thing the old token's survival would actually mean.
      expect(described_class.authenticate(retired)).to be_nil
      expect(api_key.raw_token).not_to eq(retired)
      expect(described_class.authenticate(api_key.raw_token)).to eq(api_key)
    end

    it "persists the rotation, so a reload does not resurrect the old token" do
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      api_key.regenerate!

      # `regenerate!` mutating only the in-memory record would leave the old digest on the row and
      # the old token still valid for every other process — the thing rotation exists to prevent.
      expect(described_class.authenticate(retired)).to be_nil
      expect(described_class.find(api_key.id).token_digest)
        .to eq(described_class.digest(api_key.raw_token))
    end

    it "keeps storing the digest only — the new token is no more recoverable than the old one" do
      api_key = repository.api_keys.create!
      api_key.regenerate!

      expect(described_class.find(api_key.id).raw_token).to be_nil
      expect(described_class.column_names).not_to include("token")
    end

    it "rotates the same row, keeping its identity and provenance" do
      creator = create_user(github_uid: "2002", github_handle: "minter")
      api_key = repository.api_keys.create!(name: "CI — main", created_by_user: creator)

      expect { api_key.regenerate! }.not_to change(described_class, :count)

      reloaded = described_class.find(api_key.id)
      expect(reloaded.name).to eq("CI — main")
      expect(reloaded.created_by_user).to eq(creator)
      expect(reloaded.repository).to eq(repository)
    end

    it "issues a distinct token on every rotation" do
      api_key = repository.api_keys.create!
      tokens = [api_key.raw_token] + Array.new(2) { api_key.regenerate!.raw_token }

      expect(tokens.uniq.size).to eq(3)
    end

    it "moves the hint onto the new token" do
      api_key = repository.api_keys.create!
      retired_hint = api_key.token_hint

      api_key.regenerate!

      # The hint is how the table identifies a key. Leaving it on the retired token would show a
      # fingerprint of a credential that no longer authenticates.
      expect(api_key.token_hint).not_to eq(retired_hint)
      expect(api_key.token_hint).to end_with(api_key.token_digest.last(6))
    end
  end
end
