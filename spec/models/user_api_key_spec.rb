# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserApiKey do
  let(:user) { create_user }

  # @intent: { entity: "UserApiKey", action: "persist only a digest", behavior: "the raw sgu_ token is available in memory while the column store holds its SHA-256 digest and no raw-token column exists at all", layer: "unit" }
  it "never persists the raw token — only its SHA-256 digest" do
    user_api_key = create_user_api_key(user: user)

    expect(user_api_key.raw_token).to start_with("sgu_")
    expect(user_api_key.token_digest).to eq(OpenSSL::Digest::SHA256.hexdigest(user_api_key.raw_token))
    expect(described_class.column_names).not_to include("token")
  end

  # @intent: { entity: "UserApiKey", action: "make the token reveal-once", behavior: "reloading the key by digest leaves raw_token nil, so the plaintext credential exists only at creation time", layer: "unit" }
  it "cannot recover the raw token once reloaded — that is what makes reveal-once true" do
    raw = create_user_api_key(user: user).raw_token

    expect(described_class.find_by(token_digest: described_class.digest(raw)).raw_token).to be_nil
  end

  # @intent: { entity: "UserApiKey", action: "issue unique tokens", behavior: "three keys minted for the same user carry three distinct raw tokens, so no credential is ever shared between keys", layer: "unit" }
  it "issues a distinct token per key" do
    tokens = Array.new(3) { create_user_api_key(user: user).raw_token }

    expect(tokens.uniq.size).to eq(3)
  end

  # @intent: { entity: "UserApiKey", action: "authenticate a valid token", behavior: "passing the raw token to the class-level authenticate finder returns the exact key row it was minted for", layer: "unit" }
  it "authenticates a valid raw token back to its key" do
    user_api_key = create_user_api_key(user: user)

    expect(described_class.authenticate(user_api_key.raw_token)).to eq(user_api_key)
  end

  # @intent: { entity: "UserApiKey", action: "refuse invalid tokens", behavior: "authenticate returns nil for an unrecognized token and for blank input, so no nil-string coercion can match a digest", layer: "unit" }
  it "refuses an unknown or blank token" do
    create_user_api_key(user: user)

    expect(described_class.authenticate("sgu_nope")).to be_nil
    expect(described_class.authenticate(nil)).to be_nil
    expect(described_class.authenticate("")).to be_nil
  end

  # @intent: { entity: "UserApiKey", action: "expose a non-revealing hint", behavior: "token_hint shows the sgu_ prefix while never containing any part of the secret that follows it, so a revoke UI can identify a key without exposing it", layer: "unit" }
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
    # @intent: { entity: "UserApiKey", action: "resolve in one statement", behavior: "token resolution issues exactly one SQL query, keeping the authentication cost claim made by the API base controller true", layer: "unit" }
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
    # @intent: { entity: "UserApiKey", action: "eager-load the owner", behavior: "authentication preloads the user association, so binding the principal afterwards reads zero additional queries", layer: "unit" }
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
  # @intent: { entity: "UserApiKey", action: "disambiguate the token prefix", behavior: "the sgu_ prefix differs from the repository key prefix and neither is a prefix of the other, so prefix-based discrimination before any table read is unambiguous", layer: "unit" }
  it "carries a prefix that cannot be confused with a repository key's" do
    expect(described_class::TOKEN_PREFIX).not_to eq(ApiKey::TOKEN_PREFIX)
    expect(described_class::TOKEN_PREFIX).not_to start_with(ApiKey::TOKEN_PREFIX)
    expect(ApiKey::TOKEN_PREFIX).not_to start_with(described_class::TOKEN_PREFIX)
  end

  # SPGD-752 success criterion 4. The reason this is asserted at the MODEL rather than only over
  # HTTP: `authenticate` is the single resolution site, so a key that survives archiving here
  # survives it on every endpoint that will ever be added.
  describe "an archived owner" do
    # @intent: { entity: "UserApiKey", action: "revoke on owner archival", behavior: "a token that authenticated successfully stops resolving the moment its owner's archived_at is set", layer: "unit" }
    it "stops the token authenticating that worked a moment earlier" do
      user_api_key = create_user_api_key(user: user)
      raw = user_api_key.raw_token
      expect(described_class.authenticate(raw)).to eq(user_api_key)

      user.update!(archived_at: Time.current)

      expect(described_class.authenticate(raw)).to be_nil
    end

    # @intent: { entity: "UserApiKey", action: "preserve rows on archival", behavior: "archiving the owner leaves the key row in place so the credential can be audited, with refusal rather than destruction as the archival semantic", layer: "unit" }
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
    # @intent: { entity: "UserApiKey", action: "destroy with the owner", behavior: "deleting the user removes the key row entirely, so no credential can authenticate as an orphan afterward", layer: "unit" }
    it "leaves no orphan key authenticating as nobody" do
      raw = create_user_api_key(user: user).raw_token

      user.destroy!

      expect(described_class.authenticate(raw)).to be_nil
      expect(described_class.count).to eq(0)
    end

    # @intent: { entity: "UserApiKey", action: "depend on destroy not nullify", behavior: "the association declares dependent destroy and the user_id column is NOT NULL, so a dangling ownerless key is structurally impossible", layer: "unit" }
    it "is not `dependent: :nullify` — the column could not express it anyway" do
      expect(User.reflect_on_association(:user_api_keys).options[:dependent]).to eq(:destroy)
      expect(described_class.columns_hash["user_id"].null).to be(false)
    end
  end

  # Deliberately absent: `ApiKey#regenerate!` is not ported. See UserApiKey's own note — a user key
  # has no CI fixture to keep pointed at a row, so the replacement for a lost one is a fresh key
  # plus a revoke.
  # @intent: { entity: "UserApiKey", action: "omit in-place rotation", behavior: "the model exposes no regenerate! method and carries no rotated_at column, forcing replacement via a fresh key plus revoke", layer: "unit" }
  it "has no in-place rotation" do
    expect(described_class.new).not_to respond_to(:regenerate!)
    expect(described_class.column_names).not_to include("rotated_at")
  end

  # @intent: { entity: "UserApiKey", action: "require a name", behavior: "a key built with a nil name fails validation so multiple keys per user stay distinguishable on the revoke button", layer: "unit" }
  it "requires a name, so several keys can be told apart on the revoke button" do
    expect(user.user_api_keys.new(name: nil)).not_to be_valid
  end
end
