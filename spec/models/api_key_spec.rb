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
end
