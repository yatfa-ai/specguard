# frozen_string_literal: true

require "rails_helper"

# The App's identity and where a user goes to install it.
#
# Nothing here talks to GitHub — it is resolution and URL construction — but it decides whether the
# connect flow is offered at all, so the absent-credentials behaviour is the part worth pinning:
# development, test and CI never have real App credentials, and the app has to boot, the suite has
# to run, and the UI has to explain itself rather than dead-ending anyone.
RSpec.describe SpecGuard::GithubApp do
  # ENV is process-wide and these examples set values a later example would inherit, so each one
  # gets a clean slate rather than depending on the order it ran in.
  around do |example|
    keys = %w[GITHUB_APP_ID GITHUB_APP_SLUG GITHUB_APP_PRIVATE_KEY
              GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET]
    saved = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    keys.each { |key| ENV.delete(key) }

    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def configure(**values)
    values.each { |key, value| ENV["GITHUB_APP_#{key.to_s.upcase}"] = value }
  end

  def configure_all
    configure(id: "123456", slug: "specguard", private_key: "-----BEGIN KEY-----",
              client_id: "Iv1.abc", client_secret: "shhh")
  end

  describe ".configured?" do
    # The suite's own baseline, and every developer machine's. If this ever came back true by
    # default, the specs that assert the connect UI explains itself would be asserting nothing.
    it "is false with nothing set" do
      expect(described_class).not_to be_configured
    end

    it "is true once all five values are present" do
      configure_all

      expect(described_class).to be_configured
    end

    # Reporting "configured" on a subset would move the failure from a sentence on the connect page
    # to a 500 halfway through the flow — the install link needs the slug, the callback needs the
    # client pair, and reading repositories needs the app id and private key.
    %i[id slug private_key client_id client_secret].each do |missing|
      it "is false when #{missing} alone is missing" do
        configure_all
        ENV.delete("GITHUB_APP_#{missing.to_s.upcase}")

        expect(described_class).not_to be_configured
      end
    end
  end

  describe ".private_key" do
    it "returns the PEM as given when it carries real newlines" do
      pem = "-----BEGIN KEY-----\nabc\n-----END KEY-----"
      configure(private_key: pem)

      expect(described_class.private_key).to eq(pem)
    end

    # A private key routed through a secrets manager or a CI variable frequently arrives with its
    # newlines escaped. Left alone, it fails inside OpenSSL with a message that says nothing about
    # line endings — a key that differs from the real one only in how it was transported.
    it "restores newlines escaped as \\n on the way through a secrets manager" do
      configure(private_key: '-----BEGIN KEY-----\nabc\n-----END KEY-----')

      expect(described_class.private_key).to eq("-----BEGIN KEY-----\nabc\n-----END KEY-----")
    end

    it "reports the placeholder when nothing is set" do
      expect(described_class.private_key).to eq(described_class::PLACEHOLDER)
    end
  end

  describe ".installation_url" do
    it "points at the App's own installation flow on github.com" do
      configure(slug: "specguard")

      expect(described_class.installation_url)
        .to eq("https://github.com/apps/specguard/installations/new")
    end

    # `state` is GitHub's own round-trip parameter and is what returns the user to where they
    # started. Encoded rather than interpolated: it is a PATH, and an unencoded `/` or `?` in a
    # query value is a different URL.
    it "carries a return path through GitHub's state parameter, encoded" do
      configure(slug: "specguard")

      expect(described_class.installation_url(state: "/repositories/new"))
        .to eq("https://github.com/apps/specguard/installations/new?state=%2Frepositories%2Fnew")
    end

    it "omits the parameter entirely when there is nothing to carry" do
      configure(slug: "specguard")

      expect(described_class.installation_url(state: nil)).not_to include("state")
      expect(described_class.installation_url(state: "")).not_to include("state")
    end

    # The slug reaches a URL path segment. It comes from configuration rather than from a user, so
    # this is defence in depth rather than a live threat — but a slug with a `/` in it silently
    # addressing another path on github.com is not a failure anybody would diagnose quickly.
    it "escapes the slug so it cannot reach another path on github.com" do
      configure(slug: "evil/../../settings")

      expect(described_class.installation_url)
        .to eq("https://github.com/apps/evil%2F..%2F..%2Fsettings/installations/new")
    end
  end
end
