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

  # The CLIENT-SIDE half of criterion 1's "revealed exactly once". The server-side half is two
  # examples up — the flash is consumed, a reload shows only the hint — but the partial's own
  # comments name two mechanisms as what makes that claim "actually true", and neither is a thing
  # any other example here would notice the loss of: both failure modes are silent, and this
  # credential has no rotation and no second reveal, so the panel failing at its one job is
  # unrecoverable in a way the repository panel's is not.
  #
  # Adapted from the sibling panel's guards in `repository_api_key_regeneration_spec.rb`, which
  # this partial was copied from. Deliberately NOT the whole set: the wording, the both-outcomes
  # messages, the no-JS status line and the button type are settled by the shared components and
  # asserted there. What is asserted here is what is specific to THIS render — the `sgu_` payload,
  # the filename, and the cache opt-out on the page that carries the token.
  describe "the reveal panel" do
    def reveal_panel
      Capybara.string(response.body)
              .find("[data-controller='copy-text'][data-copy-text-auto-copy-value]")
    end

    it "hands auto-copy the bare token, under a filename named after the key" do
      mint("Laptop")

      # `copy-text` copies `textContent` verbatim for both the clipboard and the download, so this
      # is asserting WHICH payload the panel controller grabs, not merely that it has one. Document
      # order would hand it the curl snippet if that snippet's nested scope were ever collapsed —
      # and a reader whose clipboard holds a curl command has no way back to the token.
      own_sources = own_copy_sources(reveal_panel)

      expect(own_sources.size).to eq(1)
      expect(own_sources.first.text.strip).to match(/\Asgu_[A-Za-z0-9_-]{20,}\z/)

      # `revealed_token_filename` moved to `ApplicationHelper` because a SECOND panel renders it.
      # This is that second call site, and the only assertion that would notice it stop being made.
      expect(reveal_panel["data-copy-text-download-filename-value"])
        .to eq("specguard-laptop-api-key.txt")
    end

    # Turbo Drive would falsify the panel's own bold claim on its own: it snapshots the live DOM
    # when the reader navigates away and repaints it on Back, plaintext token included, and
    # `connect()` fires on a restored snapshot exactly as on a fresh render — so auto-copy would
    # re-run too, over a clipboard the reader has since used.
    #
    # Asserted as the meta and not `data-turbo-cache="false"` on the panel because the element-level
    # attribute does not exist in turbo-rails 2.0.23: `getSetting("cache-control")` reads exactly
    # this tag, so an example asserting the attribute would pass while the token stayed in cache.
    # The meta can stop rendering without this partial being touched at all — a change to how
    # `content_for :head` is captured, or to `accounts/show`'s structure around the render.
    it "keeps the render carrying the token out of Turbo's snapshot cache" do
      mint("Laptop")

      cache_control = Capybara.string(response.body)
                              .find("meta[name='turbo-cache-control']", visible: :all)

      expect(cache_control["content"]).to eq("no-cache")
    end

    # Paired with the example above: that one alone would also pass if the meta were parked in the
    # layout for every page, which would quietly cost the whole app its snapshot cache. This is what
    # makes the assertion about THIS render rather than about the application template.
    it "leaves the snapshot cache alone on a page with no token on it" do
      mint("Laptop")

      get account_path

      expect(response.body).not_to match(/sgu_[A-Za-z0-9_-]{20,}/)
      expect(response.body).not_to include("turbo-cache-control")
    end
  end
end
