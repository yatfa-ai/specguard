# frozen_string_literal: true

require "rails_helper"

# The public administration guide (SPGD-762), and the two claims it makes that could otherwise only
# be asserted in prose: that the registration request it publishes is one the server accepts, and
# that the precondition it finally states in advance is the one the server actually enforces.
#
# == Why the request body is read back off the RENDERED PAGE
#
# The reasoning is `spec/requests/integration_guide_spec.rb`'s and is deliberately inherited rather
# than re-argued: posting `AdministrationGuideHelper::EXAMPLE_REQUEST_BODY` directly would prove
# that a Ruby constant satisfies the endpoint, while the thing a reader actually copies is the HTML.
# The two come apart the moment the template stops rendering that constant — an interpolation edited
# into a literal, a block that stops being emitted, an escaping change `JSON.parse` refuses. Each of
# those leaves the constant valid and the DOCUMENT wrong.
#
# So every example below GETs the guide as a signed-out visitor, pulls the JSON out of the response
# body by element id, and posts the result to the live endpoint.
#
# The corollary, for whoever edits the guide next: if you change what this page publishes about the
# registration request, this file is where you find out whether the server agrees. Where the two
# disagree, the guide is wrong — the server is not adjusted to match a document.
#
# == Nothing here signs in except where signing in is the subject
#
# The endpoint must reach for no session; a spec that established one everywhere could not tell an
# implementation reading `current_user` apart from one that does not. The reachability example that
# signs in does so to assert the ABSENCE of a redirect, which is a different property.
RSpec.describe "The public administration guide", type: :request do
  # So this file names the endpoint the same single way the page does, rather than re-spelling
  # `root_url.sub(...)` locally — which would keep passing if the helper's own stripping broke.
  include AdministrationGuideHelper

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  # The `<code>` block inside the wrapper div the template stamps the shared id onto. Scoped to the
  # wrapper rather than matched on the whole page because the guide renders several copyable blocks
  # and only this one is the fixture.
  #
  # ⚠️ Reads `response`, so it is only meaningful while the guide IS the response. Every caller
  # below captures it once, in a `before`, and then works from that value — because the examples go
  # on to POST, and after that `response` is the endpoint's JSON. Calling this afterwards does not
  # fail in an obvious way; it looks for a `<code>` block in a JSON body and reports the fixture as
  # missing, which reads like a template regression rather than an ordering mistake in the spec.
  def published_request_body
    id = AdministrationGuideHelper::EXAMPLE_REQUEST_ELEMENT_ID
    node = Capybara.string(response.body).find(:css, "##{id} code")

    JSON.parse(node.text)
  end

  # The worked `201` body, read back off the rendered page.
  #
  # Carries the same ⚠️ as `published_request_body`: only meaningful while the guide IS the response.
  def published_response_body
    id = AdministrationGuideHelper::EXAMPLE_RESPONSE_ELEMENT_ID
    node = Capybara.string(response.body).find(:css, "##{id} code")

    JSON.parse(node.text)
  end

  def page_text = Capybara.string(response.body).text.gsub(/\s+/, " ")

  describe "reachability" do
    # The audience includes an agent handed nothing but the URL — and, more sharply than on the
    # integration guide, a reader who has just been refused by a 400 and needs to learn why. A
    # redirect to sign-in is that reader failing to reach the explanation.
    it "renders for a visitor with no session at all" do
      get administration_guide_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Administration guide")
    end

    # `PagesController#home` redirects a signed-in visitor to their repositories. This action
    # deliberately does not: the person holding an `sgu_` key is signed in, and they are the reader
    # this page is most written for.
    it "renders for a signed-in visitor too" do
      sign_in_via_github

      get administration_guide_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Administration guide")
    end
  end

  describe "the published registration request" do
    let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
    let(:user_api_key) { create_user_api_key(user: person) }

    # Captured ONCE, here, while the guide is still the response — see `#published_request_body`.
    # Every example below POSTs, and the reader cannot find a `<code>` block in the JSON that comes
    # back afterwards.
    before do
      get administration_guide_path
      @published_body = published_request_body
    end

    attr_reader :published_body

    # The name the PAGE publishes, read out of the rendered fixture rather than written here. A
    # literal would let the page drift to a different repository while this spec kept registering
    # the one it remembered — green, and no longer about the document.
    def published_full_name = published_body.fetch("github_full_name")

    def grant_for_published_name(**options)
      create_registration_grant(user: person, registrable: [published_full_name], **options)
    end

    def register_as_published(token: user_api_key.raw_token)
      post "/api/v1/repositories",
           params: published_body.to_json,
           headers: bearer(token).merge("Content-Type" => "application/json")
    end

    # SPGD-762 criterion 2. The example that decides the ticket: the document, against the server.
    it "publishes a body the registration endpoint accepts" do
      grant_for_published_name

      expect { register_as_published }.to change(Repository, :count).by(1)

      expect(response).to have_http_status(:created), lambda {
        "the guide publishes a body the endpoint refuses: #{response.parsed_body["message"].inspect}"
      }
      expect(response.parsed_body.dig("repository", "full_name"))
        .to eq(published_full_name)
    end

    # "Carries a usable ingest token", asserted by USING it rather than by matching its shape — the
    # only evidence that what came back is the real credential and not a plausible-looking string.
    # The page hands the reader to the integration guide to wire CI with this token, so a token that
    # did not authenticate would make that handoff a dead end.
    it "hands back a token that actually authenticates against the ingest surface" do
      grant_for_published_name
      register_as_published

      token = response.parsed_body.dig("api_key", "token")
      expect(token).to be_present

      get "/api/v1/repository", headers: bearer(token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("repository", "full_name"))
        .to eq(published_full_name)
    end

    # The page prints a `201` body and calls its field names the contract. This pins that claim on
    # the REAL response, so a field renamed on the server fails here rather than silently outliving
    # the documentation of it. Asserted as the exact key sets, because the failure being guarded is
    # a field going missing or being added unannounced, which no single-key assertion would catch.
    it "documents the 201 body the server really sends" do
      grant_for_published_name
      register_as_published

      expect(response.parsed_body.keys).to match_array(%w[repository api_key])
      expect(response.parsed_body.fetch("repository").keys)
        .to match_array(%w[id full_name name registered_at])
      expect(response.parsed_body.fetch("api_key").keys)
        .to match_array(%w[name token hint created_at])
    end

    # The page names the minted key by its literal string ("Default CI Key" today). Pinned against
    # the constant the server mints from so the two cannot drift.
    it "names the minted key the same thing the server names it" do
      grant_for_published_name
      register_as_published

      expect(response.parsed_body.dig("api_key", "name"))
        .to eq(Api::V1::UserRepositoriesController::FIRST_KEY_NAME)
      expect(page_text).to include(Api::V1::UserRepositoriesController::FIRST_KEY_NAME)
    end

    # The page's headline warning, as an assertion rather than a sentence: `api_key.token` is the
    # only copy that will ever exist. A future endpoint that started echoing the plaintext into a
    # column would make the page's strongest claim false, and nothing else here would notice.
    it "works the claim that the revealed token is stored nowhere" do
      grant_for_published_name
      register_as_published
      token = response.parsed_body.dig("api_key", "token")

      row = ApiKey.last
      expect(row.attributes.values.map(&:to_s)).not_to include(a_string_including(token))
    end

    # The precondition, from the reader's side. The page says a registration attempted without a
    # current recording comes back as a 400 carrying that particular sentence; this is that
    # sentence, produced by the server, on the body the page publishes.
    it "gets the refusal the page describes when there is no current grant" do
      expect { register_as_published }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    # The other half of the same precondition, and the half the page puts a NUMBER on: a grant past
    # the bound redeems nothing. Without this, the page could publish any duration at all and only
    # the never-had-one case would be checked.
    it "gets that same refusal for a grant past the bound the page publishes" do
      grant_for_published_name(captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)

      expect { register_as_published }.not_to change(Repository, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"])
        .to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    # The control the example above needs: without it a bound of zero would satisfy it, and the page
    # would be free to publish a duration nothing enforces.
    it "still registers on a grant that is old but inside that bound" do
      grant_for_published_name(captured_at: GithubRegistrationGrant::MAX_AGE.ago + 1.hour)

      expect { register_as_published }.to change(Repository, :count).by(1)
      expect(response).to have_http_status(:created)
    end
  end

  # SPGD-762 criterion 3. The seven must be DERIVED, and this is what makes that a fact rather than
  # a claim about the template.
  describe "the grant expiry the page publishes" do
    # Deliberately NOT `expect(page_text).to include(GithubRegistrationGrant::MAX_AGE.inspect)`.
    # That assertion is derived from the very thing it pins: it passes against a template that
    # renders the constant AND against one whose author typed today's value by hand, because both
    # produce the same string while `MAX_AGE` is 7 days. It would therefore go on passing through
    # exactly the edit it exists to catch.
    #
    # Changing the constant and re-rendering is the only way to tell those two templates apart. A
    # page that follows the constant reports the new figure; a page with a numeral typed into it
    # keeps reporting seven, and fails here.
    it "follows the constant rather than restating today's value" do
      stub_const("GithubRegistrationGrant::MAX_AGE", 3.days)

      get administration_guide_path

      expect(page_text).to include("3 days")
      expect(page_text).not_to include("7 days"),
                               "the guide has the current expiry typed into it rather than derived " \
                               "from GithubRegistrationGrant::MAX_AGE"
    end

    # The positive half, so the example above cannot be satisfied by a page that has stopped
    # publishing the bound at all.
    it "publishes the real bound when nothing is stubbed" do
      get administration_guide_path

      expect(page_text).to include(GithubRegistrationGrant::MAX_AGE.inspect)
    end
  end

  # SPGD-762 criterion 4. Both guide URLs are route-helper built, and a hand-written path is the
  # drift that makes a document outlive the page it points at.
  describe "the links it emits" do
    before { get administration_guide_path }

    it "links the integration guide at the address the router gives it" do
      expect(response.body).to include("href=\"#{integration_guide_path}\"")
    end

    it "links the account page at the address the router gives it" do
      expect(response.body).to include("href=\"#{account_path}\"")
    end
  end

  describe "what the page must not stop saying" do
    before { get administration_guide_path }

    # The finding this whole ticket closes, asserted rather than assumed: the browser step and the
    # expiry, stated in ADVANCE. A page that lost this paragraph would still pass every endpoint
    # example above and would have given up its entire reason for existing.
    it "states the browser-and-expiry precondition before the failure" do
      expect(page_text).to match(/browser/i)
      expect(page_text).to include(GithubRegistrationGrant::MAX_AGE.inspect)
      expect(page_text).to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
    end

    it "names both credentials and the endpoints each one answers" do
      expect(page_text).to include("sgu_")
      expect(page_text).to include("sgk_")
      expect(page_text).to include("#{administration_guide_endpoint}/api/v1/repositories")
    end

    # Reveal-once and replace-rather-than-rotate, the two properties of this credential a reader
    # cannot discover by probing and will otherwise assume from the repository key, which DOES
    # rotate.
    it "says the personal key is shown once and is replaced rather than rotated" do
      expect(page_text).to match(/never again|once/i)
      expect(page_text).to match(/no.{0,20}rotation|rather than rotated/i)
    end

    # The page prints a token and a `hint` side by side and then asserts in prose that the hint "is
    # not the credential and cannot be used as one". These are the two properties that sentence
    # rests on, pinned against the values the TEMPLATE publishes rather than against the constants
    # they are built from — a pin read from what it pins would pass while the page showed anything.
    #
    # The published pair once said the opposite of the prose: the hint was the last three characters
    # of the token beside it, so the example taught exactly the misreading the paragraph denies —
    # that a hint is a truncation of the credential. A reader who trusted the example would try to
    # recognise a key by comparing the hint to a stored token's tail and would never match anything.
    it "publishes a hint that is a fingerprint of the token rather than a piece of it" do
      api_key = published_response_body.fetch("api_key")
      token = api_key.fetch("token")
      hint = api_key.fetch("hint")

      # The load-bearing one: not a suffix, and not findable anywhere in the credential.
      expect(token).not_to end_with(hint.delete_prefix("#{ApiKey::TOKEN_PREFIX}…"))
      expect(token).not_to include(hint.delete_prefix("#{ApiKey::TOKEN_PREFIX}…"))

      # And it is the hint the SERVER would produce for that token, so the shape a reader learns
      # here — prefix, ellipsis, six characters of the digest — is the shape they will meet in the
      # key list. Derived from `ApiKey.digest` so it follows a change to `#token_hint`.
      expect(hint).to eq("#{ApiKey::TOKEN_PREFIX}…#{ApiKey.digest(token).last(6)}")
    end

    # The non-goals, as an assertion. The guide's charter is that it promises no capability the API
    # does not currently have, and the two nearest unlanded surfaces are key management over the API
    # and the MCP tools. This is the fence that stops a later edit describing either as available.
    it "does not advertise capabilities the API does not have" do
      expect(page_text).not_to match(/DELETE .{0,40}api\/v1/i)
      expect(page_text).not_to include("specguard-mcp")
    end
  end

  # SPGD-762 criterion 6. The account page is where an `sgu_` key is minted, so it is the surface a
  # person is on at the moment this guide becomes relevant to them.
  describe "the account page's pointer to it" do
    it "links the guide from the page the key is minted on" do
      sign_in_via_github

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("href=\"#{administration_guide_path}\"")
    end

    # The empty-state sentence, which described the credential as read-only. True when written and
    # an undercount since registering over the API landed — the one thing a person deciding whether
    # to mint a key most needs to know about what it can do.
    #
    # Scoped to the `EmptyStateComponent`'s own description rather than to the page. Matching
    # /register/i against the whole document passed against the UNCORRECTED sentence: the layout's
    # own "Register a repository" nav link satisfies it, and so does the guide caption THIS ticket
    # added a few lines above — so the guard's sibling change guaranteed its own match and it could
    # not fail through the edit it exists to catch. A guard's reach is its selector.
    #
    # Both limbs are needed and neither is redundant. The positive says the sentence now names what
    # the credential does; the negative is the claim the ticket actually makes — that it no longer
    # describes it as read-only — which no positive assertion can express, since a sentence can name
    # registering and still carry the old read-only wording beside it.
    it "does not describe the credential as read-only where there are no keys yet" do
      sign_in_via_github

      get account_path

      empty_state = Capybara.string(response.body)
                            .find(:css, "p.max-w-prose").text.gsub(/\s+/, " ")

      expect(empty_state).to match(/register/i)
      expect(empty_state).not_to match(/read the repositories/i)
    end
  end
end
