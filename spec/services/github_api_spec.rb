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

  def repo_payload(full_name, private: false, archived: false, owner_type: "Organization", admin: true)
    { "full_name" => full_name, "private" => private, "archived" => archived,
      "owner" => { "login" => full_name.split("/").first, "type" => owner_type },
      "permissions" => { "admin" => admin, "push" => admin, "pull" => true } }
  end

  # `GET /user/installations/:id/repositories` answers with an OBJECT rather than a bare array.
  # Wrapping it here, in the one file that speaks the wire format, is what stops every other spec
  # having to know that.
  def repositories_payload(payloads)
    { "total_count" => payloads.length, "repository_selection" => "selected",
      "repositories" => payloads }.to_json
  end

  def with_responses(*responses)
    fake = FakeHttp.new(responses)
    allow(Net::HTTP).to receive(:start).and_yield(fake)
    fake
  end

  # The suite-wide fake is installed for every example (spec/support/github_api.rb); this file is
  # about the real client, so it is built directly rather than through `GithubApi.for_user`.
  subject(:client) { described_class.new("ghu_user_token", 4242) }

  describe "reading a repository" do
    # `admin` is the field the whole slice turns on: it is the user's OWN permission, and it is what
    # separates "somebody gave SpecGuard this repository" from "you may register it".
    it "reports what GitHub says about the repository AND about this user's access to it" do
      with_responses(http_response(Net::HTTPOK, body: repositories_payload(
        [repo_payload("acme/billing", private: true, admin: true)]
      )))

      repo = client.repositories.repos.first

      expect(repo.full_name).to eq("acme/billing")
      expect(repo).to be_private
      expect(repo).to be_organization
      expect(repo).to be_admin
    end

    # Absent fields are read as "GitHub did not say" rather than invented. `private?` and
    # `archived?` are false — both are claims the payload has to make — `organization?` is false,
    # which withholds rather than guessing a namespace's kind, and `admin?` is false, which FAILS
    # CLOSED: a payload with no permissions hash must not read as an administrator.
    it "reads absent fields as withheld rather than inventing them" do
      with_responses(http_response(Net::HTTPOK,
                                   body: repositories_payload([{ "full_name" => "acme/billing" }])))

      repo = client.repositories.repos.first

      expect(repo).not_to be_private
      expect(repo).not_to be_archived
      expect(repo).not_to be_organization
      expect(repo).not_to be_admin
    end

    it "authenticates as the user and pins the API version" do
      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload([])))

      client.repositories

      request = fake.requests.first
      expect(request["Authorization"]).to eq("Bearer ghu_user_token")
      expect(request["Accept"]).to eq("application/vnd.github+json")
      expect(request["X-GitHub-Api-Version"]).to eq("2022-11-28")
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

        expect { client.repositories }.to raise_error(error_class)
      end
    end

    # A rate limit clears by waiting and a refusal does not, so the reason has to survive as
    # something a caller can branch on. A message match would pass just as well against a client
    # that told every 403 the same story, which is the bug these pin.
    it "names the rate limit when GitHub's 403 is one" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-ratelimit-remaining" => "0" }))

      expect { client.repositories }
        .to raise_error(GithubApi::Forbidden, /rate limit/) { |e| expect(e.reason).to eq(:rate_limited) }
    end

    # An SSO header is no longer a reason of its own, and this pins that it is not quietly treated
    # as one: a user-to-server token reaches an organization through that organization's own
    # installation rather than through a SAML authorization of its own. A 403 carrying the header is
    # an ordinary refusal here, not a "get your org to approve SpecGuard" nobody can act on.
    it "reports a 403 that names no cause as a plain refusal" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-github-sso" => "required; organizations=abc" }))

      expect { client.repositories }
        .to raise_error(GithubApi::Forbidden) { |e| expect(e.reason).to eq(:refused) }
    end

    # A rate-limited response can carry other headers too. Exhaustion is the narrower and more
    # certain signal, and it is the only one that clears by waiting, so it wins.
    it "prefers the rate limit when a 403 carries both signals" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-ratelimit-remaining" => "0",
                                              "x-github-sso" => "required; organizations=abc" }))

      expect { client.repositories }
        .to raise_error(GithubApi::Forbidden) { |e| expect(e.reason).to eq(:rate_limited) }
    end

    # Every transport failure is the same fact to a caller — GitHub could not be reached — and none
    # of them should escape as a Net::HTTP or OpenSSL exception a rescue clause has to enumerate.
    it "wraps a transport failure rather than letting it escape" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { client.repositories }
        .to raise_error(GithubApi::Unavailable, /GitHub request failed/)
    end

    it "wraps a body that is not the JSON GitHub promised" do
      with_responses(http_response(Net::HTTPOK, body: "<html>maintenance</html>"))

      expect { client.repositories }
        .to raise_error(GithubApi::Unavailable, /not JSON/)
    end
  end

  describe "#repositories" do
    # THE endpoint, and the substance of the whole fix. Not `/user/repos`, which returned everything
    # the user could reach and needed the `repo` scope to do it; and not `/installation/repositories`,
    # which answers for the App and so answers identically for every member of an organization. This
    # one is scoped to the installation AND to the caller, which is what makes both conditions
    # checkable from one response.
    it "reads the installation's repositories AS THIS USER" do
      fake = with_responses(http_response(Net::HTTPOK, body: repositories_payload([repo_payload("acme/billing")])))

      client.repositories

      request = fake.requests.first
      expect(request.uri.path).to eq("/user/installations/4242/repositories")

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
    # reported rather than applied silently. The picker says so, and `InstallationRepositories`
    # refuses an absent name rather than reading our own page walk as GitHub's verdict.
    it "reports truncation when the page cap is reached" do
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      responses = Array.new(GithubApi::MAX_PAGES) { http_response(Net::HTTPOK, body: repositories_payload(full_page)) }
      fake = with_responses(*responses)

      listing = client.repositories

      expect(listing).to be_truncated
      expect(fake.requests.length).to eq(GithubApi::MAX_PAGES)
    end
  end

  describe ".for_user" do
    it "binds a client to the user's credential and one installation, taking a record or a bare id" do
      described_class.factory = ->(token, installation_id) { [token, installation_id] }
      installation = create_user.github_installations.first

      expect(described_class.for_user("ghu_t", installation)).to eq(["ghu_t", installation.installation_id])
      expect(described_class.for_user("ghu_t", 4242)).to eq(["ghu_t", 4242])
    end

    # Both are ordinary states of the world on a page that offers to fix them — no installation yet,
    # or a session with no credential — rather than exceptions.
    it "returns nil rather than raising when there is nothing to read with" do
      expect(described_class.for_user("ghu_t", nil)).to be_nil
      expect(described_class.for_user("ghu_t", 0)).to be_nil
      expect(described_class.for_user(nil, 4242)).to be_nil
      expect(described_class.for_user("  ", 4242)).to be_nil
    end

    # Building a client costs nothing and reaches nobody: a controller builds one on paths that may
    # never call GitHub, and it must not have paid for a round trip to find that out.
    it "does not call GitHub until the client is actually used" do
      described_class.factory = nil
      allow(Net::HTTP).to receive(:start)

      described_class.for_user("ghu_t", 4242)

      expect(Net::HTTP).not_to have_received(:start)
    end
  end
end
