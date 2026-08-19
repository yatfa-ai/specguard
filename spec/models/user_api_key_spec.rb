# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserApiKey do
  let(:user) { create_user }

  it "never persists the raw token — only its SHA-256 digest" do
    user_api_key = create_user_api_key(user: user)

    expect(user_api_key.raw_token).to start_with("sgu_")
    expect(user_api_key.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(user_api_key.raw_token))
    expect(described_class.column_names).not_to include("token")
  end

  it "cannot recover the raw token once reloaded — that is what makes reveal-once true" do
    raw = create_user_api_key(user: user).raw_token

    expect(described_class.find_by(token_digest: described_class.digest(raw)).raw_token).to be_nil
  end

  it "issues a distinct token per key" do
    tokens = Array.new(3) { create_user_api_key(user: user).raw_token }

    expect(tokens.uniq.size).to eq(3)
  end

  it "authenticates a valid raw token back to its key" do
    user_api_key = create_user_api_key(user: user)

    expect(described_class.authenticate(user_api_key.raw_token)).to eq(user_api_key)
  end

  it "refuses an unknown or blank token" do
    create_user_api_key(user: user)

    expect(described_class.authenticate("sgu_nope")).to be_nil
    expect(described_class.authenticate(nil)).to be_nil
    expect(described_class.authenticate("")).to be_nil
  end

  it "exposes a hint that identifies the key without revealing it" do
    user_api_key = create_user_api_key(user: user)

    expect(user_api_key.token_hint).to start_with("sgu_")
    expect(user_api_key.token_hint).not_to include(user_api_key.raw_token.delete_prefix("sgu_"))
  end

  # `Api::BaseController` states that authentication costs one indexed read, and `authenticate` is
  # where that is either true or not. It is asserted HERE as well as over HTTP because this is the
  # site: the request spec can only see the consequence, while this pins the two properties that
  # produce it, separately, so a regression names which one it broke.
  #
  # `count_queries` comes from spec/support/query_capture.rb.
  describe "what resolving a token costs" do
    it "resolves in a single statement" do
      raw = create_user_api_key(user: user).raw_token

      expect(count_queries { described_class.authenticate(raw) }).to eq(1)
    end

    # The half that `joins(:user)` would fail. Both spellings resolve in one statement and both
    # refuse an archived owner, so the example above and the archiving examples below CANNOT tell
    # them apart. The difference is only visible here: `joins` filters through the `users` row and
    # discards it, leaving `Api::BaseController#bind_principal` to read the same row again by
    # primary key on every authenticated request; `eager_load` brings its columns back in the one
    # statement. A count of zero is the whole claim.
    it "carries the person back with it, so binding the principal reads nothing" do
      raw = create_user_api_key(user: user).raw_token

      resolved = described_class.authenticate(raw)

      expect(resolved.association(:user).loaded?).to be(true)
      expect(count_queries { resolved.user }).to eq(0)
      expect(resolved.user).to eq(user)
    end
  end

  # The prefix is what `Api::BaseController` discriminates on BEFORE it reads either table, so a
  # `sgu_` that happened to also start `sgk_` — or either being a prefix of the other — would make
  # that decision ambiguous rather than merely ugly.
  it "carries a prefix that cannot be confused with a repository key's" do
    expect(described_class::TOKEN_PREFIX).not_to eq(ApiKey::TOKEN_PREFIX)
    expect(described_class::TOKEN_PREFIX).not_to start_with(ApiKey::TOKEN_PREFIX)
    expect(ApiKey::TOKEN_PREFIX).not_to start_with(described_class::TOKEN_PREFIX)
  end

  # SPGD-752 success criterion 4. The reason this is asserted at the MODEL rather than only over
  # HTTP: `authenticate` is the single resolution site, so a key that survives archiving here
  # survives it on every endpoint that will ever be added.
  describe "an archived owner" do
    it "stops the token authenticating that worked a moment earlier" do
      user_api_key = create_user_api_key(user: user)
      raw = user_api_key.raw_token
      expect(described_class.authenticate(raw)).to eq(user_api_key)

      user.update!(archived_at: Time.current)

      expect(described_class.authenticate(raw)).to be_nil
    end

    it "leaves the row standing — archiving destroys nothing, it only refuses" do
      user_api_key = create_user_api_key(user: user)

      user.update!(archived_at: Time.current)

      expect(described_class.exists?(user_api_key.id)).to be(true)
    end
  end

  # SPGD-752 success criterion 5, and the contrast the criterion names: `created_api_keys` is
  # `:nullify` because a repository key merely RECORDS who minted it, and none of that reasoning
  # survives a credential whose whole meaning is the person.
  describe "when the owner is deleted" do
    it "leaves no orphan key authenticating as nobody" do
      raw = create_user_api_key(user: user).raw_token

      user.destroy!

      expect(described_class.authenticate(raw)).to be_nil
      expect(described_class.count).to eq(0)
    end

    it "is not `dependent: :nullify` — the column could not express it anyway" do
      expect(User.reflect_on_association(:user_api_keys).options[:dependent]).to eq(:destroy)
      expect(described_class.columns_hash["user_id"].null).to be(false)
    end
  end

  # Deliberately absent: `ApiKey#regenerate!` is not ported. See UserApiKey's own note — a user key
  # has no CI fixture to keep pointed at a row, so the replacement for a lost one is a fresh key
  # plus a revoke.
  it "has no in-place rotation" do
    expect(described_class.new).not_to respond_to(:regenerate!)
    expect(described_class.column_names).not_to include("rotated_at")
  end

  it "requires a name, so several keys can be told apart on the revoke button" do
    expect(user.user_api_keys.new(name: nil)).not_to be_valid
  end
end
