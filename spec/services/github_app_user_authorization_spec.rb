# frozen_string_literal: true

require "rails_helper"

# The install-time code exchange — the only thing standing between the setup URL and a forged
# `?installation_id=`. Nothing else in the suite exercises it: `spec/support/github_api.rb` keeps
# every other spec off the wire, and the controller spec goes through this class rather than
# through GitHub. So this file is the one place its behaviour is pinned — what it sends, what it
# reads back, and, above all, which answers it refuses to treat as proof.
#
# `Net::HTTP.start` is intercepted rather than the class's own private methods, so the exchange
# request is built for real: the form it posts, the host it posts to, and the token it then reads
# with are exercised rather than assumed.
RSpec.describe GithubAppUserAuthorization do
  # Records every request and answers with the queued responses, in order. A recorder rather than a
  # message expectation because several examples here are about the *sequence* of requests — the
  # exchange, then the walk — which a `have_received` count cannot describe. Named apart from the
  # copy in `github_api_spec.rb` because `class` inside a `describe` block defines a top-level
  # constant, and two files reopening one recorder is a coupling neither of them asked for.
  class FakeAuthHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift || raise("FakeAuthHttp: unexpected request for #{req.path}")
    end
  end

  def http_response(klass, body: "{}", code: "200", headers: {})
    response = klass.new("1.1", code, "OK")
    headers.each { |key, value| response[key] = value }
    allow(response).to receive(:body).and_return(body)
    response
  end

  def with_responses(*responses)
    fake = FakeAuthHttp.new(responses)
    allow(Net::HTTP).to receive(:start).and_yield(fake)
    fake
  end

  def exchange_response(body = { "access_token" => "ghu_user_token", "token_type" => "bearer" }.to_json)
    http_response(Net::HTTPOK, body: body)
  end

  # `GET /user` — GitHub's answer to "whose token is this". Every journey through `authorize` makes
  # this call before it reads anything, so it and the exchange travel together as `opening`.
  def identity_response(id = 1001)
    http_response(Net::HTTPOK, body: { "id" => id, "login" => "octocat" }.to_json)
  end

  def opening(uid = 1001) = [exchange_response, identity_response(uid)]

  def installation_payload(id, login: "acme")
    { "id" => id, "account" => { "login" => login } }
  end

  # `GET /user/installations` answers with an OBJECT rather than a bare array. Wrapping it here, in
  # the one file that speaks this wire format, is what stops the rest of the suite having to know.
  def installations_response(payloads)
    http_response(Net::HTTPOK,
                  body: { "total_count" => payloads.length, "installations" => payloads }.to_json)
  end

  def full_page(offset) = Array.new(GithubAppUserAuthorization::PER_PAGE) { |i| installation_payload(offset + i + 1) }

  before do
    allow(SpecGuard::GithubApp).to receive_messages(configured?: true, client_id: "Iv1.client",
                                                    client_secret: "s3cret")
  end

  describe ".authorize" do
    # Two hosts, deliberately: the exchange happens on github.com, which is where OAuth lives, and
    # the read happens on api.github.com. A single-host client would silently post the App's client
    # secret to the wrong one.
    # @intent: { entity: "GithubAppUserAuthorization", action: "exchange the code for a user token", behavior: "the exchange POSTs to github.com while all later reads go to api.github.com carrying the token just obtained", layer: "unit" }
    it "exchanges the code on github.com and then reads the API with the token it got back" do
      fake = with_responses(*opening, installations_response([installation_payload(5001)]))

      described_class.authorize(code: "abc123", github_uid: "1001")

      exchange, identity, read = fake.requests
      expect(exchange).to be_a(Net::HTTP::Post)
      expect(exchange.uri.host).to eq("github.com")
      expect(exchange.uri.path).to eq("/login/oauth/access_token")
      expect(identity.uri.path).to eq("/user")
      expect(read).to be_a(Net::HTTP::Get)
      expect(read.uri.host).to eq("api.github.com")
      expect(read.uri.path).to eq("/user/installations")
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "post the App credentials", behavior: "the exchange request is a urlencoded form carrying exactly client_id, client_secret and the code", layer: "unit" }
    it "posts the App's own client credentials alongside the code" do
      fake = with_responses(*opening, installations_response([]))

      described_class.authorize(code: "abc123", github_uid: "1001")

      form = Rack::Utils.parse_query(fake.requests.first.body)
      expect(form).to eq("client_id" => "Iv1.client", "client_secret" => "s3cret", "code" => "abc123")
      expect(fake.requests.first.content_type).to eq("application/x-www-form-urlencoded")
    end

    # The exchanged token is what makes the answer trustworthy: GitHub is being asked "what does
    # THIS person hold", and it can only answer that if the request carries the person's own token.
    # @intent: { entity: "GithubAppUserAuthorization", action: "read installations as the user", behavior: "subsequent API reads carry a Bearer header with the user-scoped token rather than an App credential", layer: "unit" }
    it "reads the installations as the user, not as the App" do
      fake = with_responses(*opening, installations_response([]))

      described_class.authorize(code: "abc123", github_uid: "1001")

      read = fake.requests.last
      expect(read["Authorization"]).to eq("Bearer ghu_user_token")
      expect(read["Accept"]).to eq("application/vnd.github+json")
      expect(read["X-GitHub-Api-Version"]).to eq("2022-11-28")
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "return the installations", behavior: "each installation payload becomes a struct exposing its id and account login exactly as GitHub reported them", layer: "unit" }
    it "returns what GitHub says the user holds, naming each connected account" do
      with_responses(*opening,
                     installations_response([installation_payload(5001, login: "acme"),
                                             installation_payload(6002, login: "octocat")]))

      installations = described_class.authorize(code: "abc123", github_uid: "1001").installations

      expect(installations.map(&:installation_id)).to eq([5001, 6002])
      expect(installations.map(&:account_login)).to eq(%w[acme octocat])
    end

    # The login rides along because this endpoint already carries it, so a payload that omits it is
    # "GitHub did not say" rather than a reason to fail or to invent a name — `display_name` on the
    # row falls back to the id for exactly this.
    # @intent: { entity: "GithubAppUserAuthorization", action: "map an omitted account login", behavior: "a payload without an account login yields a nil account_login instead of a fabricated or defaulted name", layer: "unit" }
    it "reads a missing account login as withheld rather than inventing one" do
      with_responses(*opening, installations_response([{ "id" => 5001 }]))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations.first.account_login).to be_nil
    end

    # A user who authorized the App but selected no repositories — or who cancelled out of the
    # picker — legitimately holds nothing. Treating that as a failure would show an error page to
    # somebody who did nothing wrong.
    # @intent: { entity: "GithubAppUserAuthorization", action: "answer an empty installation list", behavior: "an empty installations array returns an empty list rather than raising or reporting an error", layer: "unit" }
    it "treats an empty list as a real answer rather than a failure" do
      with_responses(*opening, installations_response([]))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations).to eq([])
    end
  end

  # The reason this class exists. `installation_id` arrives as a query parameter on a GET that
  # anyone can type with anyone else's id in it, and the `code` is the only thing that settles who
  # is actually standing there.
  describe "refusing a code that proves nothing" do
    # The one that matters most. GitHub answers **200** — not 401 — with `{"error": …}` for a code
    # that is expired, already used, or simply invented. A client that read the status line alone
    # would take a forged setup-URL callback for a completed installation flow and go on to record
    # a stranger's installation.
    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse an error body", behavior: "a 200 exchange body containing an error raises Unauthorized naming that error and triggers no follow-up request", layer: "unit" }
    it "refuses a 200 that carries an error instead of a token" do
      fake = with_responses(exchange_response({ "error" => "bad_verification_code",
                                                "error_description" => "The code passed is incorrect or expired." }.to_json))

      expect { described_class.authorize(code: "invented", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /bad_verification_code/)

      # And it stops there: no user token was obtained, so nothing was read as that user.
      expect(fake.requests.length).to eq(1)
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a tokenless body", behavior: "a 200 body with neither error nor token raises Unauthorized and makes no further requests", layer: "unit" }
    it "refuses a 200 that carries neither an error nor a token" do
      fake = with_responses(exchange_response({ "token_type" => "bearer" }.to_json))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
      expect(fake.requests.length).to eq(1)
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse an empty token", behavior: "a blank access_token is treated the same as a missing one: Unauthorized, one request only", layer: "unit" }
    it "refuses an empty access token" do
      fake = with_responses(exchange_response({ "access_token" => "" }.to_json))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
      expect(fake.requests.length).to eq(1)
    end

    # A JSON ARRAY is a member of the same class as the two above — it carries neither an error nor
    # a token — but it used to be the one member that CRASHED instead of being refused. `decode`
    # passes arrays through untouched (the installation and repository walks need that), so this is
    # a body `exchange` can really be handed, and `["error"]` on an Array raises a TypeError, which
    # is not a `GithubApi::Error` and so escapes the callback's rescue as a 500. Refused here as
    # what it is: a 200 that proves nothing.
    ["[]", '["x"]'].each do |body|
      # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a JSON array body", behavior: "an array exchange body is rejected as proving nothing rather than raising a TypeError outside the error hierarchy", layer: "unit" }
      it "refuses a 200 whose body is the JSON array #{body}" do
        fake = with_responses(exchange_response(body))

        expect { described_class.authorize(code: "abc123", github_uid: "1001") }
          .to raise_error(GithubApi::Unauthorized, /no access token/)
        expect(fake.requests.length).to eq(1)
      end
    end

    # A callback that arrives with no code at all is the plain forgery: someone typed the setup URL
    # with an installation id on it. It is settled here, without asking GitHub anything.
    [nil, "", "   "].each do |value|
      # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a blank code offline", behavior: "a nil, empty or whitespace code raises Unauthorized before any HTTP request is attempted", layer: "unit" }
      it "refuses #{value.inspect} without asking GitHub anything" do
        fake = with_responses

        expect { described_class.authorize(code: value, github_uid: "1001") }
          .to raise_error(GithubApi::Unauthorized, /no authorization code/)
        expect(fake.requests).to be_empty
      end
    end
  end

  # An unconfigured instance cannot verify anything, so it must verify nothing — never fall through
  # to "well, the id looked fine". `NotConfigured` is a subclass of `GithubApi::Unavailable`, so the
  # controller's existing rescue already fails closed on it.
  # @intent: { entity: "GithubAppUserAuthorization", action: "refuse on an unconfigured instance", behavior: "when the App is unconfigured authorize raises NotConfigured without touching the network", layer: "unit" }
  it "refuses to verify at all when the App is not configured on this instance" do
    allow(SpecGuard::GithubApp).to receive(:configured?).and_return(false)
    fake = with_responses

    expect { described_class.authorize(code: "abc123", github_uid: "1001") }
      .to raise_error(GithubApi::NotConfigured, /not configured/)
    expect(fake.requests).to be_empty
  end

  # The token is RETURNED, and that is a deliberate reversal of an earlier draft which discarded it
  # after one call on the principle that a credential should not outlive its usefulness. It turned
  # out to be useful for longer: it is the only credential that can answer "which of these
  # repositories does this user administer", so the caller keeps it — in the user's session, for the
  # length of that session, and nowhere else. What must not happen is it reaching a database column,
  # which is `GithubUserSession`'s claim to hold rather than this one's.
  # @intent: { entity: "GithubAppUserAuthorization", action: "return the token to the caller", behavior: "the caller receives the user token together with the installations as Installation value structs", layer: "unit" }
  it "returns the credential the caller will read repositories with" do
    with_responses(*opening, installations_response([installation_payload(5001)]))

    authorization = described_class.authorize(code: "abc123", github_uid: "1001")

    expect(authorization.token).to eq("ghu_user_token")
    expect(authorization.installations).to all(be_a(described_class::Installation))
    expect(described_class::Installation.members).to eq(%i[installation_id account_login])
  end

  # Expiry is treated as arriving a minute early, so a token that runs out while a request is in
  # flight is read as expired BEFORE it is used rather than after GitHub rejects it.
  # @intent: { entity: "GithubAppUserAuthorization", action: "report the stated expiry", behavior: "expires_at is set a minute before GitHub's stated expires_in so a token running out mid-request reads as expired first", layer: "unit" }
  it "reports GitHub's own expiry, brought forward for the flight time" do
    with_responses(exchange_response({ "access_token" => "ghu_user_token", "expires_in" => 28_800 }.to_json),
                   identity_response, installations_response([]))

    expect(described_class.authorize(code: "abc123", github_uid: "1001").expires_at)
      .to be_within(5.seconds).of(Time.current + 28_800.seconds - 60.seconds)
  end

  # An App with "expire user authorization tokens" turned OFF returns no `expires_in` at all, and
  # the token then never expires on GitHub's side. Holding one in a session for a week by omission
  # is not a decision anybody would have made on purpose, so an hour is assumed and the cost of
  # being wrong is one invisible redirect.
  # @intent: { entity: "GithubAppUserAuthorization", action: "assume a default TTL", behavior: "a response with no expires_in yields an expiry of DEFAULT_TTL minus the same flight-time margin", layer: "unit" }
  it "assumes an hour when GitHub names no expiry" do
    with_responses(*opening, installations_response([]))

    expect(described_class.authorize(code: "abc123", github_uid: "1001").expires_at)
      .to be_within(5.seconds).of(Time.current + described_class::DEFAULT_TTL - 60.seconds)
  end

  # THE reason `authorize` takes a `github_uid` at all. The callback is a GET, so Rails applies no
  # CSRF check and `state` is a return path rather than a nonce — a signed-in user can be MADE to
  # arrive carrying a code an attacker minted in their own browser for their own GitHub account and
  # left unredeemed. Without this the exchange succeeds and the victim's session is handed a
  # credential, and installations, belonging to somebody else.
  describe "binding the authorization to the signed-in identity" do
    # @intent: { entity: "GithubAppUserAuthorization", action: "read the token owner's identity", behavior: "the second request is GET /user authorized with the just-exchanged user token", layer: "unit" }
    it "asks GitHub whose token it just received, with that token" do
      fake = with_responses(*opening, installations_response([]))

      described_class.authorize(code: "abc123", github_uid: "1001")

      identity = fake.requests[1]
      expect(identity.uri.path).to eq("/user")
      expect(identity["Authorization"]).to eq("Bearer ghu_user_token")
    end

    # The planted-code attack, refused. Everything about the code is valid — it exchanges, it yields
    # a real token, that token reaches real installations — and it belongs to somebody else.
    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a planted code", behavior: "a token belonging to a different GitHub account raises Unauthorized before any installation is read", layer: "unit" }
    it "refuses a code minted for a different GitHub account, before reading anything" do
      fake = with_responses(exchange_response, identity_response(999_999),
                            installations_response([installation_payload(5001)]))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /different account/)

      # And it stopped there: the installations were never read, so nothing about the attacker's
      # account was even fetched, let alone recorded.
      expect(fake.requests.length).to eq(2)
    end

    # "GitHub did not say who this is" is not "GitHub said it is you". The whole point of the call is
    # to be told.
    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a nameless identity", behavior: "an identity response without an id is refused as failing the binding rather than read as the signed-in user", layer: "unit" }
    it "refuses when GitHub names no account at all" do
      with_responses(exchange_response, http_response(Net::HTTPOK, body: {}.to_json),
                     installations_response([]))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /different account/)
    end

    # A caller cannot forget the binding: there is no default, and a blank one is refused before
    # GitHub is asked anything.
    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a blank identity offline", behavior: "a blank github_uid raises Unauthorized before any HTTP request is attempted", layer: "unit" }
    it "refuses without a signed-in identity to bind to, without asking GitHub anything" do
      fake = with_responses

      [nil, "", "  "].each do |value|
        expect { described_class.authorize(code: "abc123", github_uid: value) }
          .to raise_error(GithubApi::Unauthorized, /No signed-in identity/)
      end

      expect(fake.requests).to be_empty
    end
  end

  describe "walking the pages" do
    # @intent: { entity: "GithubAppUserAuthorization", action: "request the largest page first", behavior: "the installations walk asks for PER_PAGE items on page 1", layer: "unit" }
    it "asks for the largest page GitHub allows, starting at the first" do
      fake = with_responses(*opening, installations_response([]))

      described_class.authorize(code: "abc123", github_uid: "1001")

      query = Rack::Utils.parse_query(fake.requests.last.uri.query)
      expect(query["per_page"]).to eq(described_class::PER_PAGE.to_s)
      expect(query["page"]).to eq("1")
    end

    # A short page is GitHub saying "that was the last one", so a second request would be a wasted
    # round trip on every trip through the installation flow.
    # @intent: { entity: "GithubAppUserAuthorization", action: "stop at a short page", behavior: "a page with fewer than PER_PAGE items terminates pagination after that page", layer: "unit" }
    it "stops at the first short page" do
      fake = with_responses(*opening, installations_response([installation_payload(5001)]))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations.map(&:installation_id)).to eq([5001])
      expect(fake.requests.length).to eq(3)
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "follow full pages", behavior: "a full page causes a page-2 request and the items of both pages are returned together", layer: "unit" }
    it "follows pages while each one comes back full" do
      fake = with_responses(*opening,
                            installations_response(full_page(0)),
                            installations_response([installation_payload(999)]))

      installations = described_class.authorize(code: "abc123", github_uid: "1001").installations

      expect(installations.length).to eq(described_class::PER_PAGE + 1)
      expect(installations.last.installation_id).to eq(999)
      expect(Rack::Utils.parse_query(fake.requests.last.uri.query)["page"]).to eq("2")
    end

    # Nobody is reachable by five hundred installations. The ceiling is here so a pagination
    # response that keeps claiming to be full cannot spin the request forever.
    # @intent: { entity: "GithubAppUserAuthorization", action: "stop at the page ceiling", behavior: "perpetually full pages stop the walk after MAX_PAGES requests instead of looping forever", layer: "unit" }
    it "stops at the page ceiling rather than walking forever" do
      responses = Array.new(described_class::MAX_PAGES) { |page| installations_response(full_page(page * 100)) }
      fake = with_responses(*opening, *responses)

      described_class.authorize(code: "abc123", github_uid: "1001")

      expect(fake.requests.length).to eq(described_class::MAX_PAGES + 2)
    end

    # A body of an unexpected shape ends the walk rather than raising a NoMethodError several frames
    # up in the controller.
    # @intent: { entity: "GithubAppUserAuthorization", action: "stop at a malformed body", behavior: "a 200 body lacking the installations wrapper is read as an empty final page rather than raising mid-walk", layer: "unit" }
    it "treats a body that is not the promised object as an empty page" do
      fake = with_responses(*opening, http_response(Net::HTTPOK, body: { "total_count" => 0 }.to_json))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations).to eq([])
      expect(fake.requests.length).to eq(3)
    end
  end

  describe "filtering what GitHub sends back" do
    # The result is used to write rows against a unique index. A duplicate would be an avoidable
    # failure halfway through recording, over something GitHub is entitled to repeat across pages.
    # @intent: { entity: "GithubAppUserAuthorization", action: "de-duplicate installation ids", behavior: "the same installation id appearing twice in the listing yields a single entry in the result", layer: "unit" }
    it "de-duplicates by installation id" do
      with_responses(*opening,
                     installations_response([installation_payload(5001, login: "acme"),
                                             installation_payload(5001, login: "acme"),
                                             installation_payload(6002, login: "octocat")]))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations.map(&:installation_id)).to eq([5001, 6002])
    end

    # An id that is not a positive number is not an installation, and `GithubInstallation.record`
    # would refuse it anyway — dropping it here means the caller's list is entirely recordable.
    # @intent: { entity: "GithubAppUserAuthorization", action: "drop invalid installation ids", behavior: "ids that are not positive numbers are excluded so every returned installation is recordable", layer: "unit" }
    it "drops entries whose id is not a positive number" do
      with_responses(*opening,
                     installations_response([{ "id" => 0 }, { "id" => -1 }, { "id" => nil },
                                             { "id" => "not-a-number" }, installation_payload(5001)]))

      expect(described_class.authorize(code: "abc123", github_uid: "1001").installations.map(&:installation_id)).to eq([5001])
    end
  end

  describe "error mapping" do
    {
      Net::HTTPUnauthorized => [GithubApi::Unauthorized, "401"],
      Net::HTTPForbidden => [GithubApi::Forbidden, "403"],
      Net::HTTPNotFound => [GithubApi::NotFound, "404"],
      Net::HTTPInternalServerError => [GithubApi::Unavailable, "500"]
    }.each do |http_class, (error_class, code)|
      # @intent: { entity: "GithubAppUserAuthorization", action: "map exchange HTTP errors", behavior: "a 401, 403, 404 or 500 on the exchange surfaces as the matching typed GithubApi error class", layer: "unit" }
      it "turns #{code} on the code exchange into #{error_class.name}" do
        with_responses(http_response(http_class, code: code))

        expect { described_class.authorize(code: "abc123", github_uid: "1001") }.to raise_error(error_class)
      end

      # @intent: { entity: "GithubAppUserAuthorization", action: "map identity HTTP errors", behavior: "the same HTTP statuses on the identity read map to the same typed error classes", layer: "unit" }
      it "turns #{code} on the identity read into #{error_class.name}" do
        with_responses(exchange_response, http_response(http_class, code: code))

        expect { described_class.authorize(code: "abc123", github_uid: "1001") }.to raise_error(error_class)
      end
    end

    # Every transport failure is the same fact to a caller — GitHub could not be reached — and none
    # of them should escape as a Net::HTTP or OpenSSL exception the controller has to enumerate.
    # @intent: { entity: "GithubAppUserAuthorization", action: "wrap a transport failure", behavior: "a connection refusal escapes as GithubApi::Unavailable rather than as a raw socket exception", layer: "unit" }
    it "wraps a transport failure rather than letting it escape" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unavailable, /GitHub request failed/)
    end

    # @intent: { entity: "GithubAppUserAuthorization", action: "wrap a non-JSON body", behavior: "an HTML body on the exchange raises GithubApi::Unavailable noting that the body is not JSON", layer: "unit" }
    it "wraps a body that is not the JSON GitHub promised" do
      with_responses(http_response(Net::HTTPOK, body: "<html>maintenance</html>"))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unavailable, /not JSON/)
    end

    # A body that parses but is a bare scalar is not an answer either; reading `["error"]` off a
    # String would raise a TypeError rather than the `GithubApi::Error` the caller rescues.
    # @intent: { entity: "GithubAppUserAuthorization", action: "refuse a bare JSON scalar", behavior: "a bare scalar body is rejected as an exchange payload rather than triggering a TypeError", layer: "unit" }
    it "does not mistake a bare JSON scalar for an exchange payload" do
      with_responses(http_response(Net::HTTPOK, body: '"unexpected"'))

      expect { described_class.authorize(code: "abc123", github_uid: "1001") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
    end
  end
end
