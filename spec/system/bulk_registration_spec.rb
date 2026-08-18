# frozen_string_literal: true

require "rails_helper"

# Bulk registration, driven in a real browser.
#
# This file exists for ONE claim that the request spec beside it cannot make: that the summary the
# server renders actually reaches the person who pressed the button.
#
# `#create` answers a form submission with a rendered 200 rather than a redirect — a deliberate
# choice, because a twenty-row result with a reason per row is not flash material (see the
# controller's class comment). Turbo Drive refuses exactly that: a non-redirect reply to a form
# submission is dropped with "Form responses must redirect to another location" logged to the
# console and nothing shown. The picker therefore opts out of Turbo, and the failure mode if it ever
# stops doing so is the worst one available — the repositories ARE registered, the request spec
# still sees the summary in `response.body`, and the user watches the picker sit there unchanged and
# presses the button again.
#
# A request spec renders the body itself, so it is structurally incapable of noticing. This is the
# example that notices.
RSpec.describe "Bulk organization registration", type: :system do
  before do
    stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
    @user = sign_in_via_github_in_browser
  end

  it "shows the summary after registering, rather than leaving the picker untouched" do
    visit bulk_repositories_path(organization: "acme")

    check "acme/api"
    check "acme/web"

    click_button "Register selected repositories"

    # The summary reached the browser. Under Turbo this assertion is what fails: the page would
    # still be the picker, and the repositories would be registered regardless.
    expect(page).to have_content("Registration summary")
    expect(page).to have_content("Registered 2 repositories.")

    # And the picker is genuinely gone — a summary rendered into a still-visible form would be a
    # different bug wearing the same passing assertion above.
    expect(page).to have_no_button("Register selected repositories")

    expect(Repository.pluck(:github_full_name)).to match_array(%w[acme/api acme/web])
  end

  # The other half of the honest-summary requirement: a mixed batch names what it skipped and why,
  # and the two numbers add up to what was submitted.
  #
  # Driven through a STALE PAGE, because that is the only way a browser can actually submit a
  # mixed batch: the picker refuses to offer an already-registered repository, so the mix has to
  # arrive the way it does in life — the page was rendered when both were free, and one of them was
  # registered before the button was pressed. That is also the case where a dishonest summary would
  # hurt most, since the user has every reason to believe both were registered.
  it "reports skips alongside registrations in the browser" do
    visit bulk_repositories_path(organization: "acme")

    check "acme/api"
    check "acme/web"

    # Registered behind the open page's back, exactly as a concurrent batch would.
    create_repository(user: @user, github_full_name: "acme/web")

    click_button "Register selected repositories"

    expect(page).to have_content("Registered 1 repository.")
    expect(page).to have_content("Skipped 1.")
    expect(page).to have_content("Already registered (1)")
    expect(page).to have_content("acme/web is already registered in SpecGuard.")
  end

  # The picker's Stimulus controller is the other thing on this page that only exists in a browser.
  # "Select all shown" must reach exactly the rows the search box is currently showing — a control
  # that quietly reached past the narrowing would register repositories the user had filtered out
  # of view.
  it "selects only the rows the search box is currently showing" do
    visit bulk_repositories_path(organization: "acme")

    fill_in "Search acme", with: "api"
    check "Select all shown"

    click_button "Register selected repositories"

    expect(page).to have_content("Registered 1 repository.")
    expect(Repository.pluck(:github_full_name)).to eq(%w[acme/api])
  end
end
