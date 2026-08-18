# frozen_string_literal: true

require "rails_helper"

# The credential reveal, driven in a real browser.
#
# == Why this file exists, and why nothing below it could stand in for it
#
# The reveal has always been correct at the request level and has three request specs pinning it
# (one written expressly as a control against the feature landing on mint and not on rotate). What
# it has never had is a browser. Every one of those specs renders the response body in the test
# process and asserts on the string it produced — which is structurally incapable of noticing that
# the string arrived *outside the viewport*.
#
# That is the failure this file is about. `repositories#show` is a tall template: the control that
# mints or rotates a key sits near its bottom, the reveal renders near its top, and Turbo Drive
# preserves scroll position across the visit that follows the redirect. So the panel can render
# perfectly, contain the right token, satisfy every request spec — and the person who pressed the
# button sees the page they were already looking at, unchanged.
#
# It is not a polish item. Only a SHA-256 digest is stored, so the plaintext exists for exactly one
# flash-backed render. A reveal that is missed cannot be repeated; the only recovery is a rotation,
# which breaks whatever was still carrying the old value.
#
# == The viewport is asked for, not assumed
#
# `driven_by :headless_chromium` opens a 1400x1400 window, which is tall enough that a short page
# might fit entirely inside it — and an example that cannot fail is worse than no example. So each
# one resizes to a realistic laptop viewport and then ASSERTS that the page is genuinely taller than
# it, and that reaching the control actually scrolled. Those two guards are what make the assertion
# afterwards mean something.
#
# Position is read from `getBoundingClientRect`, never from a pixel constant: this template is long
# and still growing, and anything keyed to a known offset would rot with the next panel.
#
# == These examples do not reproduce the cause, and were falsified rather than trusted
#
# The ticket that produced this file states the viewport explanation as a hypothesis and asks for
# the OUTCOME to be fixed rather than the cause to be reproduced first. That is the right call, and
# it is also unavoidable: the cause does not reproduce here. Headless Chromium scrolls to the top of
# the page on the visit that follows the redirect, and the reveal is the first panel on that page,
# so it lands on screen by coincidence — with the fix removed entirely, every example below still
# passed.
#
# An example that cannot fail is worth nothing, so these were falsified against the hypothesis
# instead of against the environment. Driven with a scroll-restoring listener temporarily added to
# the layout — `turbo:before-visit` saves `window.scrollY`, `turbo:load` puts it back, which is what
# the report describes — the two viewport examples FAIL with the fix removed, still FAIL with only
# the URL fragment restored, and PASS once `scroll_into_view_controller.js` is back. So what they
# assert is load-bearing, and it is the controller rather than the fragment that carries it.
#
# What they therefore guard, day to day, is the outcome: that the reveal ends up on screen however
# the page is composed. Moving the panel down the page, dropping the controller, or adding something
# that preserves scroll all break them.
RSpec.describe "Revealing an API key", type: :system do
  # Narrower and much shorter than the driver's own window, so the trigger at the bottom of the page
  # and the reveal at the top of it cannot share a screen. This is the condition the defect needs;
  # picking it here rather than relying on the default is what stops a future page-length change
  # from quietly disarming every example in this file.
  VIEWPORT = [1280, 700].freeze

  before do
    @user = sign_in_via_github_in_browser
    page.current_window.resize_to(*VIEWPORT)
  end

  def scroll_offset = page.evaluate_script("window.scrollY")

  def page_height = page.evaluate_script("document.documentElement.scrollHeight")

  def viewport_height = page.evaluate_script("window.innerHeight")

  # Whether the reveal panel is on screen — its top inside the viewport and something of it visible.
  # `nil` when the panel is not rendered at all, so a missing panel fails as a missing panel rather
  # than as an off-screen one.
  def reveal_position
    page.evaluate_script(<<~JS)
      (() => {
        const panel = document.querySelector("#revealed-key");
        if (!panel) return null;
        const rect = panel.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom, viewport: window.innerHeight };
      })()
    JS
  end

  # Puts the reader at the bottom of the page, where both controls that reach the reveal actually
  # live, and asserts on the way that the scenario is real: the page must be TALLER than the window,
  # and the scroll must have MOVED us. Either check alone would let a trivially-passing example
  # through — a page that fits on one screen cannot deliver a reveal off it, and an example that
  # cannot fail is worse than no example.
  #
  # Called BEFORE the click rather than after it: afterwards the reveal has landed and the offset is
  # the panel's own position near the top, so a guard read there would be measuring the fix instead
  # of the condition the fix is for.
  def scroll_to_where_the_controls_are
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")

    expect(page_height).to be > viewport_height
    expect(scroll_offset).to be > 0
  end

  def expect_the_reveal_to_be_on_screen
    position = reveal_position

    expect(position).not_to be_nil, "the reveal panel did not render at all"
    expect(position["top"]).to be >= 0
    expect(position["top"]).to be < position["viewport"]
  end

  # The never-had-one case. The reveal owner reported this one as showing nothing at all, and an
  # empty keys table is the shorter of the two pages — so if the two cases were ever going to
  # diverge, they would diverge here.
  it "puts a first key on screen without the owner scrolling to find it" do
    repository = create_repository(user: @user)

    visit repository_path(repository)
    expect(page).to have_css("#api-keys")
    scroll_to_where_the_controls_are

    click_button "New API key"

    expect(page).to have_css("#revealed-key")
    expect(page).to have_content("This is the only time this token is shown")
    expect_the_reveal_to_be_on_screen

    # And it is the real credential that is on screen, not merely the panel — a panel scrolled into
    # view with the token below the fold would satisfy every geometric assertion above.
    expect(page).to have_text(/sgk_[A-Za-z0-9_-]{20,}/)
  end

  # The already-had-several case, and the reason it is a separate example rather than a second
  # assertion in the one above: a populated keys table is taller than an empty state, so the two
  # differ in exactly the dimension this whole file is about. The owner's report distinguished them
  # — nothing on a first mint, a visible value on a later rotate — which is precisely what two
  # different page heights would produce.
  it "puts a rotated key on screen with a table full of existing keys above it" do
    repository = create_repository(user: @user)
    %w[CI Nightly Staging Release].each do |name|
      repository.api_keys.create!(name: name, created_by_user: @user)
    end

    visit repository_path(repository)
    expect(page).to have_css("#api-keys")
    scroll_to_where_the_controls_are

    # `data-turbo-confirm` on the rotate button, so the dialog is part of the flow being driven.
    accept_confirm { first(:button, "Regenerate").click }

    expect(page).to have_css("#revealed-key")
    expect(page).to have_content("Your regenerated API key")
    expect_the_reveal_to_be_on_screen

    expect(page).to have_text(/sgk_[A-Za-z0-9_-]{20,}/)
  end

  # The one thing the reveal must not do, and the reason the scroll is bounded to one run per
  # controller instance: a reader who has scrolled away to read the wire-up prompt or the keys table
  # must not be dragged back. Asserted by scrolling away AFTER the reveal has landed and checking
  # that nothing pulls the page back.
  it "leaves the reader where they scroll to afterwards" do
    repository = create_repository(user: @user)

    visit repository_path(repository)
    click_button "New API key"
    expect(page).to have_css("#revealed-key")

    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    moved_to = scroll_offset
    expect(moved_to).to be > 0

    # A bounded wait rather than a Capybara matcher, because what is being asserted is that
    # NOTHING happens — there is no state to poll for, and a matcher that succeeds immediately
    # would give a stray re-scroll no chance to occur. Comfortably more than the one animation
    # frame the controller defers by.
    sleep 0.3

    expect(scroll_offset).to eq(moved_to)
  end
end
