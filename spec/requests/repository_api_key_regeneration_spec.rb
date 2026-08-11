# frozen_string_literal: true

require "rails_helper"

# Regenerating a key is the recovery path for a lost token. There is no other one: `ApiKey` stores
# a SHA-256 digest, so the plaintext is gone the moment the reveal-once flash is read, and the only
# thing SpecGuard can offer is a replacement.
#
# What these examples hold down is that a rotation is a REPLACEMENT and not an addition — the old
# token has to stop authenticating, on the same row, with the key's identity intact — and that the
# storage model is not quietly weakened to make the reveal easier.
RSpec.describe "Regenerating an API key", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  # The revealed token is read out of the rendered page rather than off the record, because the
  # record cannot tell you what was rendered — `raw_token` is nil on the instance the request
  # spec holds, which is the whole point of the storage model.
  def revealed_token = response.body[/sgk_[A-Za-z0-9_-]{20,}/]

  describe "the rotation itself" do
    it "retires the previous token and reveals a working replacement, once" do
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      post regenerate_repository_api_key_path(repository, api_key)
      follow_redirect!

      replacement = revealed_token
      expect(replacement).to be_present
      expect(replacement).not_to eq(retired)

      # Asserted through `authenticate`, the one thing a surviving old token would actually let
      # someone do. Comparing digest columns would pass with `authenticate` broken.
      expect(ApiKey.authenticate(retired)).to be_nil
      expect(ApiKey.authenticate(replacement)).to eq(api_key)

      # Reveal-once still holds for the replacement: a reload has nothing to show.
      get repository_path(repository)
      expect(response.body).not_to include(replacement)
      expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
    end

    it "rejects the retired token at the API and accepts the replacement" do
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      post regenerate_repository_api_key_path(repository, api_key)
      follow_redirect!
      replacement = revealed_token

      # The end the feature exists for, exercised through the real Bearer path rather than through
      # `ApiKey.authenticate` alone: a leaked key stops opening the door.
      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{retired}" }
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{replacement}" }
      expect(response).to have_http_status(:ok)
    end

    it "rotates the existing key instead of minting a second one" do
      minter = create_user(github_uid: "4242", github_handle: "minter")
      api_key = repository.api_keys.create!(name: "CI — main", created_by_user: minter)

      expect {
        post regenerate_repository_api_key_path(repository, api_key)
      }.not_to change(ApiKey, :count)

      # Provenance is not recoverable once lost — a rotation that dropped it would read as a key
      # nobody minted. `created_at` too: rotation is an event on this key, not a new key.
      reloaded = api_key.reload
      expect(reloaded.name).to eq("CI — main")
      expect(reloaded.created_by_user).to eq(minter)
      expect(reloaded.created_at).to eq(api_key.created_at)
    end

    it "stores no plaintext, on the row or anywhere else" do
      api_key = repository.api_keys.create!(name: "CI")

      post regenerate_repository_api_key_path(repository, api_key)
      follow_redirect!
      replacement = revealed_token

      # The hard constraint: regenerate must not become the reason a plaintext column appears.
      expect(ApiKey.column_names).not_to include("token")
      expect(api_key.reload.token_digest).to eq(ApiKey.digest(replacement))
      expect(ApiKey.pluck(:token_digest)).not_to include(replacement)
    end

    it "moves the key's hint onto the replacement token" do
      api_key = repository.api_keys.create!(name: "CI")
      retired_hint = api_key.token_hint

      post regenerate_repository_api_key_path(repository, api_key)
      follow_redirect!

      # The hint is how the table names a key. Left on the retired token it would fingerprint a
      # credential that no longer authenticates.
      expect(api_key.reload.token_hint).not_to eq(retired_hint)
      expect(response.body).to include(api_key.token_hint)
      expect(response.body).not_to include(retired_hint)
    end
  end

  describe "the reveal panel" do
    def reveal_panel
      Capybara.string(response.body).find("[data-controller='copy-text'][data-copy-text-auto-copy-value]")
    end

    before do
      @api_key = repository.api_keys.create!(name: "Staging")
      post regenerate_repository_api_key_path(repository, @api_key)
      follow_redirect!
    end

    it "says the token is a replacement and that the old one has stopped working" do
      expect(response.body).to include("Your regenerated API key: Staging")
      expect(response.body).to include("previous token has stopped working")
      expect(response.body).to include("This is the only time this token is shown")
    end

    it "asks the browser to copy the token without waiting to be told" do
      expect(reveal_panel["data-copy-text-auto-copy-value"]).to eq("true")

      # Both outcomes are supplied, because the copy is genuinely allowed to fail: a clipboard
      # write needs transient user activation the redirect does not carry. A panel wired with only
      # the success message would report a copy that never happened.
      expect(reveal_panel["data-copy-text-copied-message-value"]).to include("Copied to your clipboard")
      expect(reveal_panel["data-copy-text-copy-failed-message-value"]).to include("did not allow")
    end

    it "starts the status line on the claim that is true with no JavaScript" do
      status = reveal_panel.find("[data-copy-text-target='status']")

      # The rendered text is what a reader with JS disabled — or with the controller failing to
      # connect — is left holding, so it must not assert a copy.
      expect(status.text.strip).to eq("Copy it before you leave this page.")

      # Announced, because this line is the only report that the automatic copy was REFUSED and it
      # is swapped in after load. Without a live region a screen reader keeps the sentence above and
      # never hears that the token is still uncopied.
      expect(status["role"]).to eq("status")
    end

    it "offers a one-time download named after the key" do
      download = reveal_panel.find("button[data-action='copy-text#download']", text: "Download as a file")

      # Explicitly `type="button"`. UI::ButtonComponent defaults to `submit`, which is inert here
      # only because this panel happens not to be inside a form — a fact no one downstream owes us.
      expect(download["type"]).to eq("button")
      expect(reveal_panel["data-copy-text-download-filename-value"]).to eq("specguard-staging-api-key.txt")
    end

    it "keeps the copy source holding the bare token and nothing else" do
      # The Stimulus controller copies `textContent` verbatim for both the clipboard and the file,
      # so any decoration inside this element lands in the user's password manager.
      #
      # WHICH element that is is not simply "the first source in the panel". `sourceTarget` is
      # singular and scope-resolved: `Scope#containsElement` is
      # `element.closest(controllerSelector) === this.element`, so a source inside a NESTED
      # copy-text scope — the ready-to-run curl added by SPGD-353 — belongs to that controller and
      # is invisible here. This re-derives the panel controller's own source the way Stimulus does
      # rather than trusting document order, so reordering the panel cannot quietly hand auto-copy
      # the curl, and nesting this snippet cannot quietly leave the panel with no source at all.
      panel = reveal_panel.native
      own_sources = panel.css("[data-copy-text-target='source']").reject do |node|
        node.ancestors.take_while { |ancestor| ancestor != panel }
            .any? { |ancestor| ancestor["data-controller"].to_s.split.include?("copy-text") }
      end

      # Exactly one: at zero, `sourceTarget` is missing and auto-copy and Download both throw on
      # the one panel whose job is getting this value off the page; above one, document order picks.
      expect(own_sources.size).to eq(1)
      expect(own_sources.first.text.strip).to match(/\Asgk_[A-Za-z0-9_-]{20,}\z/)
    end

    # The panel claims in bold that this is the only time the token is shown. Turbo Drive would
    # falsify that on its own: it snapshots the live DOM when the reader navigates away and repaints
    # it on Back, plaintext included, and `connect()` fires on a restored snapshot exactly as on a
    # fresh render — so auto-copy would re-run too, over a clipboard the reader has since used.
    #
    # Asserted as the meta and not `data-turbo-cache="false"` on the panel because the element-level
    # attribute does not exist in turbo-rails 2.0.23 — `PageSnapshot#clone` only resets selects,
    # blanks password inputs and drops `<noscript>`, and `getSetting("cache-control")` reads exactly
    # this tag. An example asserting the attribute would pass while the token stayed in the cache.
    it "keeps the render carrying the token out of Turbo's snapshot cache" do
      cache_control = Capybara.string(response.body).find("meta[name='turbo-cache-control']", visible: :all)

      expect(cache_control["content"]).to eq("no-cache")
    end
  end

  # Paired with the example above: that one alone would also pass if the meta were parked in the
  # layout for every page, which would quietly cost the whole app its snapshot cache. This is what
  # makes the assertion about THIS render rather than about the application template.
  it "leaves the snapshot cache alone on a page with no token on it" do
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(revealed_token).to be_nil
    expect(response.body).not_to include("turbo-cache-control")
  end

  describe "a freshly minted key" do
    it "gets the same auto-copy and download treatment, without the rotation warning" do
      # The reveal path is shared on purpose — a newly minted token is exactly as unrecoverable as
      # a regenerated one. This is the control that keeps the UX from landing on rotation only.
      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }
      follow_redirect!

      expect(response.body).to include("Your new API key: Staging")
      expect(response.body).to include("data-copy-text-auto-copy-value=\"true\"")
      expect(response.body).to include("copy-text#download")
      expect(response.body).not_to include("previous token has stopped working")
    end
  end

  describe "the key list" do
    it "offers a Regenerate control alongside Revoke, warning that the current token dies" do
      api_key = repository.api_keys.create!(name: "CI")

      get repository_path(repository)
      row = Capybara.string(response.body).find("#api-keys table tbody tr", text: "CI")

      expect(row).to have_css("form[action='#{regenerate_repository_api_key_path(repository, api_key)}']")
      expect(row).to have_button("Regenerate")
      expect(row).to have_button("Revoke")
      expect(row.find("form[action='#{regenerate_repository_api_key_path(repository, api_key)}']")["data-turbo-confirm"])
        .to include("token stops working immediately")
    end
  end

  describe "authorisation" do
    let(:repository) { create_repository(user: create_user(github_uid: "7777", github_handle: "owner")) }

    def sign_in_as_member(permissions)
      member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      create_membership(repository: repository, user: member, permissions: permissions)
    end

    it "lets a member holding 'keys.manage' rotate a key" do
      sign_in_as_member(%w[view keys.manage])
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      post regenerate_repository_api_key_path(repository, api_key)

      expect(response).to redirect_to(repository_path(repository))
      expect(ApiKey.authenticate(retired)).to be_nil
    end

    it "refuses a member without 'keys.manage', leaving the token working" do
      sign_in_as_member(%w[view])
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      post regenerate_repository_api_key_path(repository, api_key)

      # 403 rather than 404: they can already see the repository, so pretending it is missing lies.
      expect(response).to have_http_status(:forbidden)
      # A gate that returned 403 *after* rotating would be a denial of service dressed as a denial.
      expect(ApiKey.authenticate(retired)).to eq(api_key)
    end

    it "refuses a signed-in stranger, leaving the token working" do
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      post regenerate_repository_api_key_path(repository, api_key)

      expect(response).to have_http_status(:not_found)
      expect(ApiKey.authenticate(retired)).to eq(api_key)
    end

    it "refuses to rotate a key belonging to a different repository" do
      other = create_repository(user: @user, github_full_name: "acme/other")
      api_key = repository.api_keys.create!(name: "CI")
      retired = api_key.raw_token

      # The id is real and the caller owns the repository in the path — only the scoping of the
      # lookup to that repository's own keys stops this reaching another tenant's credential.
      post regenerate_repository_api_key_path(other, api_key)

      expect(response).to have_http_status(:not_found)
      expect(ApiKey.authenticate(retired)).to eq(api_key)
    end
  end
end
