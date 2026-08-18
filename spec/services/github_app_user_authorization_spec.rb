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

  describe ".installations" do
    # Two hosts, deliberately: the exchange happens on github.com, which is where OAuth lives, and
    # the read happens on api.github.com. A single-host client would silently post the App's client
    # secret to the wrong one.
    it "exchanges the code on github.com and then reads the API with the token it got back" do
      fake = with_responses(exchange_response, installations_response([installation_payload(5001)]))

      described_class.installations(code: "abc123")

      exchange, read = fake.requests
      expect(exchange).to be_a(Net::HTTP::Post)
      expect(exchange.uri.host).to eq("github.com")
      expect(exchange.uri.path).to eq("/login/oauth/access_token")
      expect(read).to be_a(Net::HTTP::Get)
      expect(read.uri.host).to eq("api.github.com")
      expect(read.uri.path).to eq("/user/installations")
    end

    it "posts the App's own client credentials alongside the code" do
      fake = with_responses(exchange_response, installations_response([]))

      described_class.installations(code: "abc123")

      form = Rack::Utils.parse_query(fake.requests.first.body)
      expect(form).to eq("client_id" => "Iv1.client", "client_secret" => "s3cret", "code" => "abc123")
      expect(fake.requests.first.content_type).to eq("application/x-www-form-urlencoded")
    end

    # The exchanged token is what makes the answer trustworthy: GitHub is being asked "what does
    # THIS person hold", and it can only answer that if the request carries the person's own token.
    it "reads the installations as the user, not as the App" do
      fake = with_responses(exchange_response, installations_response([]))

      described_class.installations(code: "abc123")

      read = fake.requests.last
      expect(read["Authorization"]).to eq("Bearer ghu_user_token")
      expect(read["Accept"]).to eq("application/vnd.github+json")
      expect(read["X-GitHub-Api-Version"]).to eq("2022-11-28")
    end

    it "returns what GitHub says the user holds, naming each connected account" do
      with_responses(exchange_response,
                     installations_response([installation_payload(5001, login: "acme"),
                                             installation_payload(6002, login: "octocat")]))

      installations = described_class.installations(code: "abc123")

      expect(installations.map(&:installation_id)).to eq([5001, 6002])
      expect(installations.map(&:account_login)).to eq(%w[acme octocat])
    end

    # The login rides along because this endpoint already carries it, so a payload that omits it is
    # "GitHub did not say" rather than a reason to fail or to invent a name — `display_name` on the
    # row falls back to the id for exactly this.
    it "reads a missing account login as withheld rather than inventing one" do
      with_responses(exchange_response, installations_response([{ "id" => 5001 }]))

      expect(described_class.installations(code: "abc123").first.account_login).to be_nil
    end

    # A user who authorized the App but selected no repositories — or who cancelled out of the
    # picker — legitimately holds nothing. Treating that as a failure would show an error page to
    # somebody who did nothing wrong.
    it "treats an empty list as a real answer rather than a failure" do
      with_responses(exchange_response, installations_response([]))

      expect(described_class.installations(code: "abc123")).to eq([])
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
    it "refuses a 200 that carries an error instead of a token" do
      fake = with_responses(exchange_response({ "error" => "bad_verification_code",
                                                "error_description" => "The code passed is incorrect or expired." }.to_json))

      expect { described_class.installations(code: "invented") }
        .to raise_error(GithubApi::Unauthorized, /bad_verification_code/)

      # And it stops there: no user token was obtained, so nothing was read as that user.
      expect(fake.requests.length).to eq(1)
    end

    it "refuses a 200 that carries neither an error nor a token" do
      fake = with_responses(exchange_response({ "token_type" => "bearer" }.to_json))

      expect { described_class.installations(code: "abc123") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
      expect(fake.requests.length).to eq(1)
    end

    it "refuses an empty access token" do
      fake = with_responses(exchange_response({ "access_token" => "" }.to_json))

      expect { described_class.installations(code: "abc123") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
      expect(fake.requests.length).to eq(1)
    end

    # A callback that arrives with no code at all is the plain forgery: someone typed the setup URL
    # with an installation id on it. It is settled here, without asking GitHub anything.
    [nil, "", "   "].each do |value|
      it "refuses #{value.inspect} without asking GitHub anything" do
        fake = with_responses

        expect { described_class.installations(code: value) }
          .to raise_error(GithubApi::Unauthorized, /no authorization code/)
        expect(fake.requests).to be_empty
      end
    end
  end

  # An unconfigured instance cannot verify anything, so it must verify nothing — never fall through
  # to "well, the id looked fine". `NotConfigured` is a subclass of `GithubApi::Unavailable`, so the
  # controller's existing rescue already fails closed on it.
  it "refuses to verify at all when the App is not configured on this instance" do
    allow(SpecGuard::GithubApp).to receive(:configured?).and_return(false)
    fake = with_responses

    expect { described_class.installations(code: "abc123") }
      .to raise_error(GithubAppCredentials::NotConfigured, /not configured/)
    expect(fake.requests).to be_empty
  end

  # The token exists for the length of one method call. It is the one credential in the app that
  # speaks for a *person*, so the public surface has to be incapable of handing it out — not merely
  # in the habit of not doing so.
  it "never hands the user token back to the caller" do
    with_responses(exchange_response, installations_response([installation_payload(5001)]))

    installations = described_class.installations(code: "abc123")

    expect(installations).to all(be_a(described_class::Installation))
    expect(described_class::Installation.members).to eq(%i[installation_id account_login])
    expect(installations.map(&:to_h).to_s).not_to include("ghu_user_token")
    expect(described_class).not_to respond_to(:exchange)
  end

  describe "walking the pages" do
    it "asks for the largest page GitHub allows, starting at the first" do
      fake = with_responses(exchange_response, installations_response([]))

      described_class.installations(code: "abc123")

      query = Rack::Utils.parse_query(fake.requests.last.uri.query)
      expect(query["per_page"]).to eq(described_class::PER_PAGE.to_s)
      expect(query["page"]).to eq("1")
    end

    # A short page is GitHub saying "that was the last one", so a second request would be a wasted
    # round trip on every trip through the installation flow.
    it "stops at the first short page" do
      fake = with_responses(exchange_response, installations_response([installation_payload(5001)]))

      expect(described_class.installations(code: "abc123").map(&:installation_id)).to eq([5001])
      expect(fake.requests.length).to eq(2)
    end

    it "follows pages while each one comes back full" do
      fake = with_responses(exchange_response,
                            installations_response(full_page(0)),
                            installations_response([installation_payload(999)]))

      installations = described_class.installations(code: "abc123")

      expect(installations.length).to eq(described_class::PER_PAGE + 1)
      expect(installations.last.installation_id).to eq(999)
      expect(Rack::Utils.parse_query(fake.requests.last.uri.query)["page"]).to eq("2")
    end

    # Nobody is reachable by five hundred installations. The ceiling is here so a pagination
    # response that keeps claiming to be full cannot spin the request forever.
    it "stops at the page ceiling rather than walking forever" do
      responses = Array.new(described_class::MAX_PAGES) { |page| installations_response(full_page(page * 100)) }
      fake = with_responses(exchange_response, *responses)

      described_class.installations(code: "abc123")

      expect(fake.requests.length).to eq(described_class::MAX_PAGES + 1)
    end

    # A body of an unexpected shape ends the walk rather than raising a NoMethodError several frames
    # up in the controller.
    it "treats a body that is not the promised object as an empty page" do
      fake = with_responses(exchange_response, http_response(Net::HTTPOK, body: { "total_count" => 0 }.to_json))

      expect(described_class.installations(code: "abc123")).to eq([])
      expect(fake.requests.length).to eq(2)
    end
  end

  describe "filtering what GitHub sends back" do
    # The result is used to write rows against a unique index. A duplicate would be an avoidable
    # failure halfway through recording, over something GitHub is entitled to repeat across pages.
    it "de-duplicates by installation id" do
      with_responses(exchange_response,
                     installations_response([installation_payload(5001, login: "acme"),
                                             installation_payload(5001, login: "acme"),
                                             installation_payload(6002, login: "octocat")]))

      expect(described_class.installations(code: "abc123").map(&:installation_id)).to eq([5001, 6002])
    end

    # An id that is not a positive number is not an installation, and `GithubInstallation.record`
    # would refuse it anyway — dropping it here means the caller's list is entirely recordable.
    it "drops entries whose id is not a positive number" do
      with_responses(exchange_response,
                     installations_response([{ "id" => 0 }, { "id" => -1 }, { "id" => nil },
                                             { "id" => "not-a-number" }, installation_payload(5001)]))

      expect(described_class.installations(code: "abc123").map(&:installation_id)).to eq([5001])
    end
  end

  describe "error mapping" do
    {
      Net::HTTPUnauthorized => [GithubApi::Unauthorized, "401"],
      Net::HTTPForbidden => [GithubApi::Forbidden, "403"],
      Net::HTTPNotFound => [GithubApi::NotFound, "404"],
      Net::HTTPInternalServerError => [GithubApi::Unavailable, "500"]
    }.each do |http_class, (error_class, code)|
      it "turns #{code} on the code exchange into #{error_class.name}" do
        with_responses(http_response(http_class, code: code))

        expect { described_class.installations(code: "abc123") }.to raise_error(error_class)
      end

      it "turns #{code} on the installations read into #{error_class.name}" do
        with_responses(exchange_response, http_response(http_class, code: code))

        expect { described_class.installations(code: "abc123") }.to raise_error(error_class)
      end
    end

    # Every transport failure is the same fact to a caller — GitHub could not be reached — and none
    # of them should escape as a Net::HTTP or OpenSSL exception the controller has to enumerate.
    it "wraps a transport failure rather than letting it escape" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { described_class.installations(code: "abc123") }
        .to raise_error(GithubApi::Unavailable, /GitHub request failed/)
    end

    it "wraps a body that is not the JSON GitHub promised" do
      with_responses(http_response(Net::HTTPOK, body: "<html>maintenance</html>"))

      expect { described_class.installations(code: "abc123") }
        .to raise_error(GithubApi::Unavailable, /not JSON/)
    end

    # A body that parses but is a bare scalar is not an answer either; reading `["error"]` off a
    # String would raise a TypeError rather than the `GithubApi::Error` the caller rescues.
    it "does not mistake a bare JSON scalar for an exchange payload" do
      with_responses(http_response(Net::HTTPOK, body: '"unexpected"'))

      expect { described_class.installations(code: "abc123") }
        .to raise_error(GithubApi::Unauthorized, /no access token/)
    end
  end
end
