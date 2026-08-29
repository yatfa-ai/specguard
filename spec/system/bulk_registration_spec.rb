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

  # @intent: { entity: "BulkOrganizationRegistration", action: "submit the repository picker form", behavior: "the rendered non-redirect summary reaches the browser and the picker form is gone, with both repositories registered", layer: "system" }
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
  # @intent: { entity: "BulkOrganizationRegistration", action: "register a stale mixed batch", behavior: "the summary shown to the user distinguishes the skipped already-registered row with its reason from the one registered", layer: "system" }
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
  # @intent: { entity: "BulkOrganizationRegistration", action: "use select-all-shown with an active search filter", behavior: "only the filtered-in repository is checked and registered while the hidden one is left alone", layer: "system" }
  it "selects only the rows the search box is currently showing" do
    visit bulk_repositories_path(organization: "acme")

    fill_in "Search acme", with: "api"
    check "Select all shown"

    click_button "Register selected repositories"

    expect(page).to have_content("Registered 1 repository.")
    expect(Repository.pluck(:github_full_name)).to eq(%w[acme/api])
  end

  # SPGD-818, criterion 1, driven the way the person in the ticket actually hits it: a solo
  # developer whose repositories are ALL in their own namespace, starting from the chooser rather
  # than from a hand-built `?organization=` URL.
  #
  # Every layer below this already passes for a personal namespace, and that is exactly why the
  # browser example is worth having — the bug was never in the machinery. It was that the page did
  # not offer the card, so the flow could not be STARTED. This walks the whole flow through the two
  # clicks a user makes, which is the only place that failure was ever visible.
  context "when every repository is in the user's own namespace" do
    before do
      stub_github(repos: [github_repo("octocat/api", owner_type: "User"),
                          github_repo("octocat/blog", owner_type: "User")])
    end

    # @intent: { entity: "BulkOrganizationRegistration", action: "start from the chooser with only user-owned repositories", behavior: "the personal-namespace card is offered and a two-repository batch registers through it", layer: "system" }
    it "offers the personal namespace and registers a batch from it" do
      visit bulk_repositories_path

      # The chooser is reachable at all — this is the assertion that used to be impossible. Before
      # the filter came out, this page rendered the "not for you" empty state and offered exactly
      # one button: register them one at a time.
      expect(page).to have_no_content("No repositories to register in a batch")
      expect(page).to have_content("Personal")

      click_link "octocat"

      # The picker for octocat has genuinely ARRIVED before anything is ticked.
      #
      # This is the only navigation in the system suite followed by interaction — every other
      # example reaches its page with `visit`, which blocks until the load completes. `click_link`
      # does not: it returns as soon as the click is dispatched, and Turbo Drive then replaces
      # `<body>` asynchronously. So `check` below could find its node on the OUTGOING chooser and
      # act on it after the swap had detached it, which chromedriver reports as
      # `Node with given id does not belong to the document` (SPGD-834).
      #
      # `have_button` waits for a control that exists only on the picker, so the swap is complete
      # before the first `check` looks for anything. It is also a real assertion rather than a
      # sleep: the chooser link must actually lead to a registerable picker.
      expect(page).to have_button("Register selected repositories")

      check "octocat/api"
      check "octocat/blog"
      click_button "Register selected repositories"

      expect(page).to have_content("Registered 2 repositories.")
      expect(Repository.pluck(:github_full_name)).to match_array(%w[octocat/api octocat/blog])
    end
  end

  # SPGD-806, in the one place it can actually be checked: the tokens reaching a real browser.
  #
  # The request spec beside this asserts the plaintext is in `response.body`, which is a claim about
  # the RENDER. This is the claim about the PAGE — that the summary carrying N live credentials is
  # what the person who pressed the button ends up looking at. The two are not the same assertion
  # here, for the reason this whole file exists: `#create` answers with a rendered 200 rather than a
  # redirect, and the failure mode if the picker ever stops opting out of Turbo is that the
  # repositories are registered, the request spec still sees the tokens in the body it rendered
  # itself, and the user watches the picker sit there — with the only copy of two credentials
  # discarded in a response the browser dropped on the floor.
  # @intent: { entity: "BulkOrganizationRegistration", action: "register a two-repository batch", behavior: "both one-time plaintext tokens render on the delivered page with the reveal-once warning visible to the user", layer: "system" }
  it "shows every newly registered repository's key on the summary, in the browser" do
    visit bulk_repositories_path(organization: "acme")

    check "acme/api"
    check "acme/web"

    click_button "Register selected repositories"

    expect(page).to have_content("Registered 2 repositories.")
    # The panel's own heading, which carries the count and the reveal-once claim in one sentence.
    expect(page).to have_content("2 API keys — this is the only time they are shown")

    # Both tokens genuinely rendered, read off the PAGE rather than out of the database: only a
    # SHA-256 digest is stored, so by now the plaintext exists nowhere except on this screen.
    shown = page.text.scan(/sgk_[A-Za-z0-9_-]+/).uniq
    expect(shown.length).to eq(2)

    # The refresh hazard is stated where the reader is, rather than left to be discovered by
    # refreshing and finding the tokens gone.
    expect(page).to have_content("Reloading this page will not bring them back")
  end
end
