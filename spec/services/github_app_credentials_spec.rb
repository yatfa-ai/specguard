# frozen_string_literal: true

require "rails_helper"

# The minting half. Nothing else in the suite ever mints — `spec/support/github_api.rb` installs a
# fake through `GithubApi.factory`, and `GithubApi` resolves its credential lazily, so no other spec
# needs App credentials or a private key. That makes this file the one place the real thing is
# pinned: what it asks GitHub for, what it signs the request with, what it caches, and what each
# answer turns into for a caller.
#
# `Net::HTTP.start` is intercepted rather than the class's own private methods, so the request is
# built for real — and the JWT on it is a real signature this file verifies against a real public
# key, rather than a string an expectation agreed with.
RSpec.describe GithubAppCredentials do
  # Records every request and answers with the queued responses, in order. Named apart from the
  # copy in `github_api_spec.rb` because `class` inside a `describe` block defines a top-level
  # constant, and two files reopening one recorder is a coupling neither of them asked for.
  class FakeTokenHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift || raise("FakeTokenHttp: unexpected request for #{req.path}")
    end
  end

  def http_response(klass, body: "{}", code: "200", headers: {})
    response = klass.new("1.1", code, "OK")
    headers.each { |key, value| response[key] = value }
    allow(response).to receive(:body).and_return(body)
    response
  end

  def with_responses(*responses)
    fake = FakeTokenHttp.new(responses)
    allow(Net::HTTP).to receive(:start).and_yield(fake)
    fake
  end

  def token_response(token: "ghs_minted", expires_at: 1.hour.from_now)
    http_response(Net::HTTPOK,
                  body: { "token" => token, "expires_at" => expires_at&.iso8601 }.compact.to_json)
  end

  # A real 2048-bit key, generated once for the whole file. The signature checks below are only
  # worth anything against a key OpenSSL actually signed with, and generating one per example costs
  # more than the rest of the file put together.
  signing_key = OpenSSL::PKey::RSA.generate(2048)
  let(:key) { signing_key }

  before do
    allow(SpecGuard::GithubApp).to receive_messages(configured?: true, app_id: "123456",
                                                    private_key: key.to_pem)
  end

  # A JWT segment is base64url with the padding stripped; `urlsafe_decode64` wants it back before it
  # will decode.
  def decode_segment(segment)
    Base64.urlsafe_decode64(segment + ("=" * ((4 - (segment.length % 4)) % 4)))
  end

  # Mints once against a canned 200 and hands back the JWT that actually went out on the wire,
  # rather than one built by calling `app_jwt` alongside the code under test.
  def minted_jwt
    fake = with_responses(token_response)
    described_class.installation_token(42)
    fake.requests.first["Authorization"].delete_prefix("Bearer ")
  end

  describe ".installation_token" do
    it "mints at the installation's own endpoint and returns the token GitHub issued" do
      fake = with_responses(token_response(token: "ghs_abc123"))

      expect(described_class.installation_token(42)).to eq("ghs_abc123")

      request = fake.requests.first
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/app/installations/42/access_tokens")
      expect(request.uri.host).to eq("api.github.com")
    end

    # The App authenticates as *itself* here — with the private key, not with an installation token —
    # because minting an installation token is the one thing an installation token cannot do.
    it "authenticates as the App itself and pins the API version" do
      fake = with_responses(token_response)

      described_class.installation_token(42)

      request = fake.requests.first
      expect(request["Authorization"]).to start_with("Bearer ")
      expect(request["Authorization"].delete_prefix("Bearer ").split(".").length).to eq(3)
      expect(request["Accept"]).to eq("application/vnd.github+json")
      expect(request["X-GitHub-Api-Version"]).to eq("2022-11-28")
    end
  end

  # The JWT is written out here rather than taken from the `jwt` gem, so nothing outside this file
  # would notice if it stopped being a valid one. GitHub would — with a 401 that looks exactly like
  # a wrong private key — so the shape is checked here in full.
  describe "the App JWT" do
    it "is three base64url segments with no padding" do
      segments = minted_jwt.split(".")

      expect(segments.length).to eq(3)
      # `=` padding is not merely untidy: GitHub rejects a padded token outright.
      expect(segments).to all(match(/\A[A-Za-z0-9_-]+\z/))
    end

    it "declares itself an RS256 JWT in the header" do
      header = JSON.parse(decode_segment(minted_jwt.split(".").first))

      expect(header).to eq("typ" => "JWT", "alg" => "RS256")
    end

    # `iss` is the numeric App id, which is how GitHub knows whose public key to check the signature
    # against; a JWT that expires before it was issued is one GitHub rejects out of hand.
    it "claims the App id and expires after it was issued" do
      payload = JSON.parse(decode_segment(minted_jwt.split(".")[1]))

      expect(payload["iss"]).to eq("123456")
      expect(payload["exp"]).to be > payload["iat"]
      expect(payload["exp"] - payload["iat"]).to eq(described_class::JWT_TTL + described_class::JWT_CLOCK_SKEW)
    end

    # `iat` is backdated deliberately: a server clock a few seconds fast is otherwise a 401 that is
    # indistinguishable from a wrong key, and backdating is GitHub's own documented remedy.
    it "backdates the issued-at against clock skew" do
      payload = JSON.parse(decode_segment(minted_jwt.split(".")[1]))

      expect(payload["iat"]).to be <= Time.current.to_i - described_class::JWT_CLOCK_SKEW
    end

    # The whole point of the token: the signature has to verify against the App's public key. A
    # structural check alone would pass just as well against a JWT signed with nothing at all.
    it "carries a signature the App's public key verifies" do
      header, payload, signature = minted_jwt.split(".")

      expect(key.public_key.verify(OpenSSL::Digest.new("SHA256"),
                                   decode_segment(signature), "#{header}.#{payload}")).to be(true)
    end

    # And the verification above has to be capable of failing, or it proves nothing: a JWT whose
    # claims were edited after signing must not verify.
    it "does not verify once the claims are tampered with" do
      header, _payload, signature = minted_jwt.split(".")
      forged = Base64.urlsafe_encode64(JSON.generate(iss: "999999"), padding: false)

      expect(key.public_key.verify(OpenSSL::Digest.new("SHA256"),
                                   decode_segment(signature), "#{header}.#{forged}")).to be(false)
    end
  end

  # The cache exists because one page render can ask GitHub several questions and minting is itself
  # a round trip. It is in-process on purpose — a credential that reaches repository metadata does
  # not belong in a shared store — so this is where its behaviour is pinned.
  describe "caching" do
    it "answers a second call for the same installation without a round trip" do
      fake = with_responses(token_response(token: "ghs_cached"))

      expect(described_class.installation_token(42)).to eq("ghs_cached")
      expect(described_class.installation_token(42)).to eq("ghs_cached")
      expect(fake.requests.length).to eq(1)
    end

    # Keyed by installation, not global: two installations are two different credentials, and
    # handing one installation's token to another would be a read of somebody else's repositories.
    it "mints separately for a different installation" do
      fake = with_responses(token_response(token: "ghs_for_42"), token_response(token: "ghs_for_77"))

      expect(described_class.installation_token(42)).to eq("ghs_for_42")
      expect(described_class.installation_token(77)).to eq("ghs_for_77")
      expect(fake.requests.length).to eq(2)
      expect(fake.requests.map(&:path))
        .to eq(["/app/installations/42/access_tokens", "/app/installations/77/access_tokens"])
    end

    # A request that starts at 59:59 with a token taken from cache must not fail on arrival, so a
    # token inside the margin is treated as already spent even though GitHub still calls it live.
    it "re-mints a cached token that is close enough to expiry to be unsafe" do
      fake = with_responses(token_response(token: "ghs_expiring", expires_at: 2.minutes.from_now),
                            token_response(token: "ghs_fresh"))

      expect(described_class.installation_token(42)).to eq("ghs_expiring")
      expect(described_class.installation_token(42)).to eq("ghs_fresh")
      expect(fake.requests.length).to eq(2)
    end

    # An expiry that cannot be read must not be taken for "never expires" — that would cache a dead
    # token for the life of the process — nor for "already expired", which would mint on every call.
    # GitHub's documented hour is the safe reading, and it means the token is still cacheable.
    it "treats an unreadable expiry as GitHub's documented hour" do
      fake = with_responses(http_response(Net::HTTPOK,
                                          body: { "token" => "ghs_no_expiry", "expires_at" => "" }.to_json))

      expect(described_class.installation_token(42)).to eq("ghs_no_expiry")
      expect(described_class.installation_token(42)).to eq("ghs_no_expiry")
      expect(fake.requests.length).to eq(1)
    end

    it "drops everything on reset!" do
      fake = with_responses(token_response(token: "ghs_first"), token_response(token: "ghs_second"))

      expect(described_class.installation_token(42)).to eq("ghs_first")
      described_class.reset!

      expect(described_class.installation_token(42)).to eq("ghs_second")
      expect(fake.requests.length).to eq(2)
    end
  end

  describe "error mapping" do
    {
      Net::HTTPUnauthorized => [GithubApi::Unauthorized, "401"],
      Net::HTTPForbidden => [GithubApi::Forbidden, "403"],
      Net::HTTPNotFound => [GithubApi::NotFound, "404"],
      Net::HTTPInternalServerError => [GithubApi::Unavailable, "500"]
    }.each do |http_class, (error_class, code)|
      it "turns #{code} into #{error_class.name}" do
        with_responses(http_response(http_class, code: code))

        expect { described_class.installation_token(42) }.to raise_error(error_class)
      end
    end

    # A 404 on a mint is what an *uninstall* looks like from here — GitHub answers 404 for an
    # installation that is gone — and it is the ordinary way a stored row stops working, so it has
    # to stay distinguishable from "GitHub is down" rather than collapsing into it.
    it "reports a vanished installation as NotFound rather than an outage" do
      with_responses(http_response(Net::HTTPNotFound, code: "404"))

      expect { described_class.installation_token(42) }
        .to raise_error(GithubApi::NotFound, /uninstalled/)
    end

    # A 401 here is an operator's problem — wrong App id, or a key that is not this App's — and not
    # something a user can fix by re-authorizing, which is why it is worth its own class.
    it "names the App credentials when GitHub rejects the JWT" do
      with_responses(http_response(Net::HTTPUnauthorized, code: "401"))

      expect { described_class.installation_token(42) }
        .to raise_error(GithubApi::Unauthorized, /GITHUB_APP_ID/)
    end

    # None of the exceptions Net::HTTP can raise should escape as itself: the list goes stale
    # silently, and every one of them means the same thing to a caller.
    it "wraps a transport failure rather than letting it escape" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { described_class.installation_token(42) }
        .to raise_error(GithubApi::Unavailable, /token request failed/)
    end

    it "wraps a body that is not the JSON GitHub promised" do
      with_responses(http_response(Net::HTTPOK, body: "<html>maintenance</html>"))

      expect { described_class.installation_token(42) }
        .to raise_error(GithubApi::Unavailable, /not JSON/)
    end

    # A 200 carrying no token is not a token. Reading it as one would cache an empty string and
    # send `Authorization: Bearer ` on every subsequent read for the next hour.
    it "refuses a success that carries no token" do
      with_responses(http_response(Net::HTTPOK, body: { "expires_at" => 1.hour.from_now.iso8601 }.to_json))

      expect { described_class.installation_token(42) }
        .to raise_error(GithubApi::Unavailable, /no installation token/)
    end

    # Nothing usable can be cached from a failure, so the next call has to try again rather than
    # settle into a state where the failure is permanent for the life of the process.
    it "caches nothing from a failed mint" do
      fake = with_responses(http_response(Net::HTTPInternalServerError, code: "500"),
                            token_response(token: "ghs_recovered"))

      expect { described_class.installation_token(42) }.to raise_error(GithubApi::Unavailable)
      expect(described_class.installation_token(42)).to eq("ghs_recovered")
      expect(fake.requests.length).to eq(2)
    end
  end

  describe "when the App is not configured" do
    # Every developer machine and every CI run is in this state, so it is the default rather than a
    # stub: the suite-wide `SpecGuard::GithubApp` has none of its five values set.
    before { allow(SpecGuard::GithubApp).to receive(:configured?).and_return(false) }

    it "refuses to mint, and names what an operator has to set" do
      fake = with_responses

      expect { described_class.installation_token(42) }
        .to raise_error(described_class::NotConfigured, /GITHUB_APP_PRIVATE_KEY/)
      expect(fake.requests).to be_empty
    end

    # The load-bearing part. `NotConfigured` is a subclass of `Unavailable` so that every caller's
    # EXISTING rescue already fails CLOSED on it — an unconfigured instance registers nothing rather
    # than registering everything because a check it never heard of went missing.
    it "fails closed through a caller that only knows about Unavailable" do
      with_responses

      expect(described_class::NotConfigured.ancestors).to include(GithubApi::Unavailable, GithubApi::Error)

      caught = begin
        described_class.installation_token(42)
        :no_error
      rescue GithubApi::Unavailable => e
        e
      end

      expect(caught).to be_a(described_class::NotConfigured)
    end
  end

  # A PEM that OpenSSL cannot read is a configuration mistake rather than a GitHub outage, but it
  # still has to fail closed — and `NotConfigured` is exactly "this instance cannot talk to GitHub
  # as the App", so it must not surface as a raw OpenSSL error a caller has to enumerate.
  it "reports a private key that cannot be read as a configuration failure" do
    allow(SpecGuard::GithubApp).to receive(:private_key).and_return("-----BEGIN RSA PRIVATE KEY-----\nnope\n")
    fake = with_responses

    expect { described_class.installation_token(42) }
      .to raise_error(described_class::NotConfigured, /private key could not be read/)
    expect(fake.requests).to be_empty
  end

  # The id reaches this method from a row that was written from a query parameter. "Not a positive
  # integer" is settled here rather than by asking GitHub about `/app/installations/0/…`.
  describe "an installation id that is not usable" do
    [nil, 0, -1, "", "  ", "abc"].each do |value|
      it "reports #{value.inspect} as NotFound without asking GitHub" do
        fake = with_responses

        expect { described_class.installation_token(value) }
          .to raise_error(GithubApi::NotFound, /installation id is missing/)
        expect(fake.requests).to be_empty
      end
    end
  end
end
