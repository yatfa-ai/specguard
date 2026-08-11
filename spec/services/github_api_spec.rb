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

  def repo_payload(full_name, admin: true, private: false, archived: false)
    { "full_name" => full_name, "private" => private, "archived" => archived,
      "permissions" => { "admin" => admin, "push" => true, "pull" => true } }
  end

  def with_responses(*responses)
    fake = FakeHttp.new(responses)
    allow(Net::HTTP).to receive(:start).and_yield(fake)
    fake
  end

  # The suite-wide fake is installed for every example (spec/support/github_api.rb); this file is
  # about the real client, so it is built directly rather than through `GithubApi.for`.
  subject(:client) { described_class.new("gho_token") }

  describe "#repository" do
    it "reports GitHub's own permission verdict for the caller" do
      with_responses(http_response(Net::HTTPOK, body: repo_payload("acme/billing", admin: true).to_json))

      repo = client.repository("acme/billing")

      expect(repo.full_name).to eq("acme/billing")
      expect(repo).to be_admin
    end

    # An absent `permissions` block is an unknown permission level, and an unknown permission level
    # is not a grant. `false`, never `nil` — a nil reaching a policy check is a truthiness bug
    # waiting to happen.
    it "treats a missing permissions block as no admin rather than as unknown" do
      with_responses(http_response(Net::HTTPOK, body: { "full_name" => "acme/billing" }.to_json))

      repo = client.repository("acme/billing")

      expect(repo.admin).to be(false)
      expect(repo).not_to be_admin
    end

    it "authenticates with the stored token and pins the API version" do
      fake = with_responses(http_response(Net::HTTPOK, body: repo_payload("acme/billing").to_json))

      client.repository("acme/billing")

      request = fake.requests.first
      expect(request["Authorization"]).to eq("Bearer gho_token")
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

    it "names the rate limit when GitHub's 403 is one" do
      with_responses(http_response(Net::HTTPForbidden, code: "403",
                                   headers: { "x-ratelimit-remaining" => "0" }))

      expect { client.repository("acme/billing") }
        .to raise_error(GithubApi::Forbidden, /rate limit/)
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
    it "asks for every affiliation the user could register from" do
      fake = with_responses(http_response(Net::HTTPOK, body: [repo_payload("acme/billing")].to_json))

      client.repositories

      query = Rack::Utils.parse_query(fake.requests.first.uri.query)
      expect(query["affiliation"]).to eq("owner,collaborator,organization_member")
      expect(query["per_page"]).to eq(GithubApi::PER_PAGE.to_s)
      expect(query["page"]).to eq("1")
    end

    # A short page is GitHub saying "that was the last one", so a second request would be a wasted
    # round trip on every render of the registration form.
    it "stops at the first short page" do
      fake = with_responses(http_response(Net::HTTPOK, body: [repo_payload("acme/billing")].to_json))

      listing = client.repositories

      expect(listing.repos.map(&:full_name)).to eq(["acme/billing"])
      expect(listing).not_to be_truncated
      expect(fake.requests.length).to eq(1)
    end

    it "follows pages while each one comes back full" do
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      fake = with_responses(
        http_response(Net::HTTPOK, body: full_page.to_json),
        http_response(Net::HTTPOK, body: [repo_payload("acme/last")].to_json)
      )

      listing = client.repositories

      expect(listing.repos.length).to eq(GithubApi::PER_PAGE + 1)
      expect(fake.requests.length).to eq(2)
      expect(Rack::Utils.parse_query(fake.requests.last.uri.query)["page"]).to eq("2")
    end

    # The cap is a bound on one page render, not a claim about anyone's account — so it is reported
    # rather than applied silently. The picker says so; the verification path does not read this
    # list at all, so a repository past the cap is still registerable.
    it "reports truncation when the page cap is reached" do
      full_page = Array.new(GithubApi::PER_PAGE) { |i| repo_payload("acme/repo-#{i}") }
      responses = Array.new(GithubApi::MAX_PAGES) { http_response(Net::HTTPOK, body: full_page.to_json) }
      fake = with_responses(*responses)

      listing = client.repositories

      expect(listing).to be_truncated
      expect(fake.requests.length).to eq(GithubApi::MAX_PAGES)
    end
  end

  describe ".for" do
    it "binds a client to the user's stored token" do
      described_class.factory = ->(token) { token }

      expect(described_class.for(create_user(github_access_token: "gho_stored"))).to eq("gho_stored")
    end

    # "Has not connected GitHub yet" is an ordinary state of the world on every page that offers to
    # connect it, not an exception — and it is also what a key rotation looks like from here.
    it "returns nil rather than raising when there is no token to bind" do
      expect(described_class.for(create_user(github_access_token: nil))).to be_nil
      expect(described_class.for(nil)).to be_nil
    end
  end
end
