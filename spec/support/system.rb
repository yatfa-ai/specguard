# frozen_string_literal: true

require "capybara/rspec"
require "selenium-webdriver"

# Browser-driven system specs — the layer that exists because the other layers cannot see JavaScript.
#
# ## Why this is here at all
#
# A request spec renders the response body inside the test process and asserts on the string it
# produced. That is the right tool for almost everything in this suite, and it is structurally blind
# to one class of defect: a response the SERVER produced correctly and the BROWSER then refuses to
# act on. Turbo Drive is the live example — it requires a redirect in reply to a form submission and
# silently drops a 200 that renders a body, so a page can be green in a request spec, register
# everything it was asked to, and show the user nothing (SPGD-355). Nothing below this layer can
# catch that.
#
# So: use a request spec by default. Reach for a system spec when the claim is specifically about
# what a browser does — Turbo navigation, a Stimulus controller, a form that must round-trip.
# They cost seconds rather than milliseconds, so they earn their place one at a time.
#
# ## The driver
#
# Headless Chromium, driven through the chromedriver already on the box rather than through Selenium
# Manager, which would try to reach the network to download a driver it does not need. Both paths are
# overridable by env var so this is not pinned to one image's layout.
#
# `--no-sandbox` is required because the suite runs as root in a container, where Chromium's sandbox
# refuses to start. That is a statement about the test environment and not a setting anything in
# production shares.
module SystemSpecBrowser
  CHROMIUM = ENV.fetch("CHROMIUM_BINARY", "/usr/bin/chromium")
  CHROMEDRIVER = ENV.fetch("CHROMEDRIVER_BINARY", "/usr/bin/chromedriver")

  # System specs are the only part of this suite with a dependency outside the bundle, and a missing
  # Chromium must not read as a broken application.
  def self.available? = File.executable?(CHROMIUM) && File.executable?(CHROMEDRIVER)

  def self.missing_message
    "no Chromium at #{CHROMIUM} or chromedriver at #{CHROMEDRIVER} — install them, or set " \
      "CHROMIUM_BINARY / CHROMEDRIVER_BINARY, to run the browser-driven examples"
  end
end

Capybara.register_driver :headless_chromium do |app|
  options = Selenium::WebDriver::Chrome::Options.new(binary: SystemSpecBrowser::CHROMIUM)
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-gpu")
  options.add_argument("--window-size=1400,1400")

  service = Selenium::WebDriver::Service.chrome(path: SystemSpecBrowser::CHROMEDRIVER)

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options, service: service)
end

# Silent so a failing example's output is the failure rather than a page of Puma logging.
Capybara.server = :puma, { Silent: true }
Capybara.default_max_wait_time = 5

module SystemAuthHelpers
  # Signs in through the real OmniAuth callback, in the browser, so the session lives in the
  # browser's cookie jar rather than in an integration session the browser cannot see.
  #
  # OmniAuth is in test mode for the whole suite (spec/support/omniauth.rb), so the callback reads
  # `OmniAuth.config.mock_auth[:github]` and never leaves the process. The request phase is POST-only
  # here, which is why this visits the callback directly rather than clicking the sign-in button.
  def sign_in_via_github_in_browser(overrides = {})
    mock_github_auth(overrides)
    visit "/auth/github/callback"
    User.find_by(github_uid: OmniAuth.config.mock_auth[:github]["uid"].to_s)
  end
end

RSpec.configure do |config|
  config.include OmniAuthHelpers, type: :system
  config.include SystemAuthHelpers, type: :system

  # PENDING rather than skipped when there is no browser, so a run on a box without Chromium says
  # out loud that the Turbo claim went unchecked instead of printing a green dot for an example that
  # never ran. `pending` needs the example to actually fail, hence the raise.
  config.before(:each, type: :system) do
    unless SystemSpecBrowser.available?
      pending(SystemSpecBrowser.missing_message)
      raise SystemSpecBrowser.missing_message
    end

    driven_by :headless_chromium
  end

  config.after(type: :system) do
    OmniAuth.config.mock_auth[:github] = nil
  end
end
