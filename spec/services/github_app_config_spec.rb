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
    keys = %w[GITHUB_APP_SLUG GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET]
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
    configure(slug: "specguard", client_id: "Iv1.abc", client_secret: "shhh")
  end

  describe ".configured?" do
    # The suite's own baseline, and every developer machine's. If this ever came back true by
    # default, the specs that assert the connect UI explains itself would be asserting nothing.
    # @intent: { entity: "SpecGuard::GithubApp", action: "check App configuration", behavior: "with none of the three App ENV values set the class reports not configured", layer: "unit" }
    it "is false with nothing set" do
      expect(described_class).not_to be_configured
    end

    # @intent: { entity: "SpecGuard::GithubApp", action: "check App configuration", behavior: "slug, client id and client secret together make configured? true", layer: "unit" }
    it "is true once all three values are present" do
      configure_all

      expect(described_class).to be_configured
    end

    # Reporting "configured" on a subset would move the failure from a sentence on the connect page
    # to a 500 halfway through the flow — the install and authorize links need the slug, and reading
    # anything at all needs the client pair to exchange the code that comes back.
    %i[slug client_id client_secret].each do |missing|
      # @intent: { entity: "SpecGuard::GithubApp", action: "check App configuration", behavior: "removing any one of the three credentials alone drops configured? back to false", layer: "unit" }
      it "is false when #{missing} alone is missing" do
        configure_all
        ENV.delete("GITHUB_APP_#{missing.to_s.upcase}")

        expect(described_class).not_to be_configured
      end
    end
  end

  describe ".installation_url" do
    # @intent: { entity: "SpecGuard::GithubApp", action: "build the installation URL", behavior: "the URL is the App's own installations/new flow on github.com derived from the slug", layer: "unit" }
    it "points at the App's own installation flow on github.com" do
      configure(slug: "specguard")

      expect(described_class.installation_url)
        .to eq("https://github.com/apps/specguard/installations/new")
    end

    # `state` is GitHub's own round-trip parameter and is what returns the user to where they
    # started. Encoded rather than interpolated: it is a PATH, and an unencoded `/` or `?` in a
    # query value is a different URL.
    # @intent: { entity: "SpecGuard::GithubApp", action: "build the installation URL", behavior: "a state return path rides the query string percent-encoded so slashes cannot alter the URL", layer: "unit" }
    it "carries a return path through GitHub's state parameter, encoded" do
      configure(slug: "specguard")

      expect(described_class.installation_url(state: "/repositories/new"))
        .to eq("https://github.com/apps/specguard/installations/new?state=%2Frepositories%2Fnew")
    end

    # @intent: { entity: "SpecGuard::GithubApp", action: "build the installation URL", behavior: "a nil or empty state omits the parameter from the installation URL entirely", layer: "unit" }
    it "omits the parameter entirely when there is nothing to carry" do
      configure(slug: "specguard")

      expect(described_class.installation_url(state: nil)).not_to include("state")
      expect(described_class.installation_url(state: "")).not_to include("state")
    end

    # The slug reaches a URL path segment. It comes from configuration rather than from a user, so
    # this is defence in depth rather than a live threat — but a slug with a `/` in it silently
    # addressing another path on github.com is not a failure anybody would diagnose quickly.
    # @intent: { entity: "SpecGuard::GithubApp", action: "build the installation URL", behavior: "a slug containing slashes is percent-encoded so it cannot address a different github.com path", layer: "unit" }
    it "escapes the slug so it cannot reach another path on github.com" do
      configure(slug: "evil/../../settings")

      expect(described_class.installation_url)
        .to eq("https://github.com/apps/evil%2F..%2F..%2Fsettings/installations/new")
    end
  end

  # The smaller of the two ways out. It asks GitHub only for a credential that speaks for the
  # signed-in user, and for anyone who has authorized the App before GitHub renders no screen at all
  # — which is what makes it usable as the answer to "this session has nothing to read with".
  describe ".authorization_url" do
    # @intent: { entity: "SpecGuard::GithubApp", action: "build the authorization URL", behavior: "the URL targets GitHub's oauth authorize endpoint carrying the App's own client id", layer: "unit" }
    it "points at GitHub's user-authorization endpoint for the App's own client" do
      configure(client_id: "Iv1.abc")

      expect(described_class.authorization_url)
        .to eq("https://github.com/login/oauth/authorize?client_id=Iv1.abc")
    end

    # @intent: { entity: "SpecGuard::GithubApp", action: "build the authorization URL", behavior: "a state return path rides the authorize query string percent-encoded", layer: "unit" }
    it "carries a return path through GitHub's state parameter, encoded" do
      configure(client_id: "Iv1.abc")

      expect(described_class.authorization_url(state: "/repositories/new"))
        .to eq("https://github.com/login/oauth/authorize?client_id=Iv1.abc&state=%2Frepositories%2Fnew")
    end

    # @intent: { entity: "SpecGuard::GithubApp", action: "build the authorization URL", behavior: "a nil or empty state omits the parameter from the authorize URL entirely", layer: "unit" }
    it "omits the parameter entirely when there is nothing to carry" do
      configure(client_id: "Iv1.abc")

      expect(described_class.authorization_url(state: nil)).not_to include("state")
      expect(described_class.authorization_url(state: "")).not_to include("state")
    end

    # The App's OAuth client, NOT the sign-in App's. They are separate registrations on github.com
    # and mixing them up fails in a way that takes sign-in with it.
    # @intent: { entity: "SpecGuard::GithubApp", action: "build the authorization URL", behavior: "the client id comes from the App's registration even when the sign-in App publishes a different one", layer: "unit" }
    it "uses the App's own client id rather than the sign-in App's" do
      configure(client_id: "Iv1.app")
      allow(SpecGuard::GithubOauth).to receive(:client_id).and_return("sign-in-client")

      expect(described_class.authorization_url).to include("client_id=Iv1.app")
    end
  end
end
