# frozen_string_literal: true

require "rails_helper"

# SPGD-752 success criterion 1: the account-level page a person mints, inspects and revokes their
# own `sgu_` keys from.
RSpec.describe "Account API keys", type: :request do
  before { @person = sign_in_via_github }

  attr_reader :person

  def mint(name)
    post account_api_keys_path, params: { user_api_key: { name: name } }
    follow_redirect!
    # The plaintext exists for exactly this render and nowhere else, so it is scraped here rather
    # than read off the model — which is the whole claim being tested.
    response.body[/sgu_[A-Za-z0-9_-]+/]
  end

  it "mints several named keys and lists them" do
    mint("Laptop")
    mint("Agent")

    get account_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Laptop").and include("Agent")
    expect(person.user_api_keys.pluck(:name)).to contain_exactly("Laptop", "Agent")
  end

  it "reveals the raw token exactly once" do
    token = mint("Laptop")
    expect(token).to be_present

    # The reveal rode the flash, which the redirect above consumed. A reload of the same page must
    # not be able to produce it again — only a digest was stored.
    get account_path

    expect(response.body).not_to include(token)
    expect(response.body).to include(person.user_api_keys.sole.token_hint)
  end

  it "persists only the digest" do
    token = mint("Laptop")

    key = person.user_api_keys.sole
    expect(key.token_digest).to eq(UserApiKey.digest(token))
    expect(UserApiKey.column_names).not_to include("token")
  end

  it "shows when each key was last used" do
    token = mint("Laptop")

    get account_path
    expect(response.body).to include("never")

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{token}" }

    get account_path
    expect(response.body).not_to include("never")
  end

  # The half of criterion 1 that is about the OTHER keys: resolution is a lookup of one digest on a
  # unique index, so revoking one must not disturb any sibling.
  it "revokes one key and leaves every other one working" do
    doomed = mint("Laptop")
    survivor = mint("Agent")

    delete account_api_key_path(person.user_api_keys.find_by!(name: "Laptop"))

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{doomed}" }
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{survivor}" }
    expect(response).to have_http_status(:ok)
  end

  it "offers no way to rotate a key in place" do
    mint("Laptop")

    get account_path

    expect(response.body).not_to include("Regenerate")
  end

  it "cannot reach a key belonging to somebody else" do
    stranger_key = create_user_api_key(user: create_user(github_uid: "9999", github_handle: "hubot"))

    delete account_api_key_path(stranger_key)

    # 404, not 403: authorization here IS the association — `current_user.user_api_keys.find` never
    # sees the row, so the key's existence is not disclosed to somebody guessing ids.
    expect(response).to have_http_status(:not_found)
    expect(UserApiKey.exists?(stranger_key.id)).to be(true)
  end

  it "sends a signed-out visitor away rather than showing the page" do
    delete sign_out_path

    get account_path

    expect(response).to redirect_to(root_path)
  end
end
