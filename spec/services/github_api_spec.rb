# frozen_string_literal: true

require "rails_helper"

# The transport half. Everything else in the suite runs against `FakeGithubApi` through
# `GithubApi.factory`, which is what keeps specs off the wire — so this file is the one place the
# real client's own behaviour is pinned: what it asks for, how it pages, and what each GitHub
# response turns into for a caller.
#
# `Net::HTTP.start` is intercepted rather than the client's private methods, so request
# construction (URL, query, auth header) is exercised rather than assumed.
RSpec.describe GithubApi do
  # Records every request and answers with the queued responses, in order. A recorder rather than a
  # message expectation: several examples are about the *sequence* of requests (pagination), which
  # a `have_received` count cannot describe.
  class FakeHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift || raise("FakeHttp: unexpected request for #{req.path}")
    end
  end

  def http_response(klass, body: "[]", code: "200", headers: {})
    response = klass.new("1.1", code, "OK")
    headers.each { |key, value| response[key] = value }
    allow(response).to receive(:body).and_return(body)
    response
  end

  def repo_payload(full_name, private: false, archived: false, owner_type: "Organization")
    { "full_name" => full_name, "private" => private, "archived" => archived,
      "owner" => { "login" => full_name.split("/").first, "type" => owner_type } }
  end

  # `GET /installation/repositories` answers with an OBJECT rather than the bare array the
  # user-token endpoint it replaces returned. Wrapping it here, in the one file that speaks the wire
  # format, is what stops every other spec having to know that.
  def repositories_payload(payloads)
    { "total_count" => payloads.length, "repositories" => payloads }.to_json
  end

  def with_responses(*responses)
    fake = FakeHttp.new(responses)
    allow(Net::HTTP).to receive(:start).and_yield(fake)
    fake
  end

  # The suite-wide fake is installed for every example (spec/support/github_api.rb); this file is
  # about the real client, so it is built directly rather than through `GithubApi.for_installation`.
  # A bare String stands in for the credential — the client accepts either that or an object
  # answering `#token`, and the minting half is `GithubAppCredentials`' own spec to pin.
  subject(:client) { described_class.new("ghs_installation_token") }

  describe "#repository" do
    # Reaching a repository at all is the answer: an installation credential can only see what the
    # installation covers, so a `Repo` coming back IS "yes, this is registerable". There is no
    # permission field to read, which is the whole of what this slice changed.
    it "reports a repository the installation covers" do
      with_responses(http_response(Net::HTTPOK, body: repo_payload("acme/billing", private: true).to_json))

      repo = client.repository("acme/billing")

      expect(repo.full_name).to eq("acme/billing")
      expect(repo).to be_private
      expect(repo).to be_organization
    end

    # Absent fields are read as "GitHub did not say" rather than invented. `private?` and
    # `archived?` are false — both are claims the payload has to make — and `organization?` is
    # false, which withholds rather than guessing a namespace's kind.
    it "reads absent fields as withheld rather than inventing them" do
      with_responses(http_response(Net::HTTPOK, body: { "full_name" => "acme/billing" }.to_json))

      repo = client.repository("acme/billing")

      expect(repo).not_to be_private
      expect(repo).not_to be_archived
      expect(repo).not_to be_organization
    end

    it "authenticates as the installation and pins the API version" do
      fake = with_responses(http_response(Net::HTTPOK, body: repo_payload("acme/billing").to_json))

      client.repository("acme/billing")

      request = fake.requests.first
      expect(request["Authorization"]).to eq("Bearer ghs_installation_token")
      expect(request["Accept"]).to eq("application/vnd.github+json")
      expect(request["X-GitHub-Api-Version"]).to eq("2022-11-28")
      expect(request.path).to eq("/repos/acme/billing")
    end

    # The value reaches this method straight off a form field. A segment carrying its own `/` must
    # not become a path separator and address a different endpoint.
    it "escapes each path segment so a crafted name cannot reach another endpoint" do
      fake = with_responses(http_response(Net::HTTPOK, body: repo_payload("a/b").to_json))

      client.repository("acme/billing/../../user")

      expect(fake.requests.first.path).to eq("/repos/acme/billing%2F..%2F..%2Fuser")
    end
  end

  describe "error mapping" do
    {
      Net::HTTPUnauthorized => GithubApi::Unauthorized,
      Net::HTTPForbidden => GithubApi::Forbidden,
      Net::HTTPNotFound => GithubApi::NotFound,
      Net::HTTPInternalServerError => GithubApi::Unavailable
    }.each do |http_class, error_class|
      it "turns #{http_class.name.demodulize} into #{error_class.name}" do
        with_responses(http_response(http_class, code: "500"))

        expect { client.repository("acme/billing") }.to raise_error(error_class)
      end
    end

    # A rate limit clears by waiting and a refusal does not, so the reason has to survive as
    # something a caller can branch on. A message match would pass just as well against a client
    # that told every 403 the same story, which is the bug these pin.
    it "names the rate limit when GitHub's 403 is one" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-ratelimit-remaining" => "0" }))

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Forbidden, /rate limit/) { |e| expect(e.reason).to eq(:rate_limited) }
    end

    # An SSO header is no longer a reason of its own, and this pins that it is not quietly treated
    # as one: SAML SSO authorization is a property of a USER token, and an installation is
    # authorized by the organization that installed it. A 403 carrying the header is an ordinary
    # refusal here, not a "get your org to approve SpecGuard" the user can do nothing with.
    it "reports a 403 that names no cause as a plain refusal" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-github-sso" => "required; organizations=abc" }))

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Forbidden) { |e| expect(e.reason).to eq(:refused) }
    end

    # A rate-limited response can carry other headers too. Exhaustion is the narrower and more
    # certain signal, and it is the only one that clears by waiting, so it wins.
    it "prefers the rate limit when a 403 carries both signals" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-ratelimit-remaining" => "0",
                                              "x-github-sso" => "required; organizations=abc" }))

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Forbidden) { |e| expect(e.reason).to eq(:rate_limited) }
    end

    # Every transport failure is the same fact to a caller — GitHub could not be reached — and none
    # of them should escape as a Net::HTTP or OpenSSL exception a rescue clause has to enumerate.
    it "wraps a transport failure rather than letting it escape" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Unavailable, /GitHub request failed/)
    end

    it "wraps a body that is not the JSON GitHub promised" do
      with_responses(http_response(Net::HTTPOK, body: "<html>maintenance</html>"))

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Unavailable, /not JSON/)
    end
  end

  describe "#repositories" do
    # The installation endpoint, not `/user/repos`. That is the substance of the change rather than
    # a detail: `/user/repos` returned everything the user could reach and needed the `repo` scope
    # to do it, where this returns exactly what somebody deliberately installed the App on.
    it "reads the installation's own repositories" do
      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload([repo_payload("acme/billing")])))

      client.repositories

      request = fake.requests.first
      expect(request.uri.path).to eq("/installation/repositories")

      query = Rack::Utils.parse_query(request.uri.query)
      expect(query["per_page"]).to eq(GithubApi::PER_PAGE.to_s)
      expect(query["page"]).to eq("1")
    end

    # GitHub offers no `sort` on this endpoint, so the order is applied here — and it has to be,
    # because the picker is rendered from it and a list that reshuffles between renders is one
    # people stop trusting.
    it "sorts the listing by name rather than leaving GitHub's order" do
      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload(
        [repo_payload("acme/zebra"), repo_payload("acme/Apple"), repo_payload("acme/mango")]
      )))

      expect(client.repositories.repos.map(&:full_name)).to eq(%w[acme/Apple acme/mango acme/zebra])
      expect(fake.requests.length).to eq(1)
    end

    # A body of an unexpected shape ends the walk rather than raising a NoMethodError several frames
    # up in a controller.
    it "treats a body that is not the promised object as an empty page" do
      with_responses(http_response(Net::HTTPOK, body: { "total_count" => 0 }.to_json))

      expect(client.repositories.repos).to be_empty
    end

    # A short page is GitHub saying "that was the last one", so a second request would be a wasted
    # round trip on every render of the registration form.
    it "stops at the first short page" do
      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload([repo_payload("acme/billing")])))

      listing = client.repositories

      expect(listing.repos.map(&:full_name)).to eq(["acme/billing"])
      expect(listing).not_to be_truncated
      expect(fake.requests.length).to eq(1)
    end

    it "follows pages while each one comes back full" do
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      fake = with_responses(
        http_response(Net::HTTPOK, body: repositories_payload(full_page)),
        http_response(Net::HTTPOK, body: repositories_payload([repo_payload("acme/last")]))
      )

      listing = client.repositories

      expect(listing.repos.length).to eq(GithubApi::PER_PAGE + 1)
      expect(fake.requests.length).to eq(2)
      expect(Rack::Utils.parse_query(fake.requests.last.uri.query)["page"]).to eq("2")
    end

    # The cap is a bound on one page render, not a claim about anyone's installation — so it is
    # reported rather than applied silently. The picker says so, and `InstallationRepositories` asks
    # GitHub about a name individually rather than refusing it for a property of our own page walk.
    it "reports truncation when the page cap is reached" do
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      responses = Array.new(GithubApi::MAX_PAGES) { http_response(Net::HTTPOK, body: repositories_payload(full_page)) }
      fake = with_responses(*responses)

      listing = client.repositories

      expect(listing).to be_truncated
      expect(fake.requests.length).to eq(GithubApi::MAX_PAGES)
    end
  end

  describe ".for_installation" do
    it "binds a client to the installation, taking a record or a bare id" do
      described_class.factory = ->(credential) { credential.installation_id }
      installation = create_user.github_installations.first

      expect(described_class.for_installation(installation)).to eq(installation.installation_id)
      expect(described_class.for_installation(4242)).to eq(4242)
    end

    # "Has not installed the App yet" is an ordinary state of the world on every page that offers to
    # install it, not an exception.
    it "returns nil rather than raising when there is no installation to bind" do
      expect(described_class.for_installation(nil)).to be_nil
      expect(described_class.for_installation(0)).to be_nil
    end

    # The credential is resolved on the first REQUEST, not when the client is built. A controller
    # builds one on paths that may never call GitHub, and minting is itself a round trip — so a page
    # that renders without asking GitHub anything must not have paid for a token.
    it "does not mint a token until the client is actually used" do
      # The suite installs the fake through this same seam, so it has to be stood down for the two
      # examples that are about the REAL client's credential handling.
      described_class.factory = nil
      allow(GithubAppCredentials).to receive(:installation_token).and_return("ghs_minted")

      client = described_class.for_installation(4242)
      expect(GithubAppCredentials).not_to have_received(:installation_token)

      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload([])))
      client.repositories

      expect(GithubAppCredentials).to have_received(:installation_token).with(4242).once
      expect(fake.requests.first["Authorization"]).to eq("Bearer ghs_minted")
    end

    # One client, one mint, however many pages it walks.
    it "mints once for a client that walks several pages" do
      described_class.factory = nil
      allow(GithubAppCredentials).to receive(:installation_token).and_return("ghs_minted")
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      with_responses(
        http_response(Net::HTTPOK, body: repositories_payload(full_page)),
        http_response(Net::HTTPOK, body: repositories_payload([repo_payload("acme/last")]))
      )

      described_class.for_installation(4242).repositories

      expect(GithubAppCredentials).to have_received(:installation_token).once
    end
  end
end
