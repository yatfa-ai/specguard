# frozen_string_literal: true

require "rails_helper"

# The landing page is the product's storefront, and until SPGD-248 it advertised
# `POST /api/v1/check-intent` as SpecGuard's *first* answer. That route has never been mounted, and
# the capability it named was demoted by the owner on 2026-08-06 ("prevention ... is explicitly not
# what the product is for"). So the page sold a feature that was both unbuilt and unwanted.
#
# What these examples pin is not the copy — copy should be free to change — but the two properties
# that made the old panel a defect:
#
#   1. nothing on the page names an `api/v1` surface the router does not serve, and
#   2. the answers the product cannot give yet are *labelled* as unavailable rather than listed
#      beside the ones it can.
#
# Both are written to fail loudly rather than vacuously. Per the *Vacuous Green* article, a bare
# `not_to include(...)` is the spec-side shape of that defect: it passes just as happily on a blank
# page, a 500, or a page whose panel someone deleted. Every negative assertion here is therefore
# paired with a positive one that proves the surface it is judging actually rendered.
RSpec.describe "The signed-out landing page", type: :request do
  before { get "/" }

  # The availability panel, asserted as a node rather than as a string anywhere in the body. The
  # second ("being built to answer") panel is retired — every row it listed now has an answer — so
  # its node must be absent too, which a body-wide string match could not distinguish from a
  # panel that merely lost its title.
  # @intent: {"entity": "GET /", "action": "render the availability panel", "behavior": "the landing page returns 200 and carries the #answers-today node titled What SpecGuard answers today and no #roadmap node", "layer": "request"}
  it "answers with the one availability panel and no roadmap panel" do
    expect(response).to have_http_status(:ok)

    page = Capybara.string(response.body)
    expect(page).to have_css("#answers-today", text: "What SpecGuard answers today")
    expect(page).to have_no_css("#roadmap")
    expect(page).to have_no_text("What SpecGuard is being built to answer")
  end

  # @intent: {"entity": "GET /", "action": "omit unmounted endpoint claims", "behavior": "with the answers panel proven present, the body contains neither the string check-intent nor any match of /prevention/i", "layer": "request"}
  it "does not sell prevention or the unmounted /check-intent endpoint" do
    # Non-vacuous guard: the panel that used to carry the claim has to be on the page for its
    # absence from that page to mean anything.
    expect(response.body).to include("What SpecGuard answers today")

    expect(response.body).not_to include("check-intent")
    expect(response.body).not_to match(/prevention/i)
  end

  # The general form of the bug: the storefront named a path the application would 404. Asserting
  # the absence of that one literal would not stop the next one, so this compares whatever the page
  # advertises against what the router actually serves.
  # @intent: {"entity": "GET /", "action": "advertise only mounted routes", "behavior": "every /api/v1 path the body advertises forms a non-empty set whose difference against the application route set is empty, so no advertised endpoint 404s", "layer": "request"}
  it "names no api/v1 path that the router does not serve" do
    advertised = response.body.scan(%r{/api/v1/[a-z0-9_-]+}).uniq

    # Non-vacuity ONLY. Without it the example passes on a page that names no endpoint at all,
    # including a page that failed to render. It is deliberately not a literal allowlist: pinning
    # `advertised` to an exact set decides the next assertion's answer in advance, which leaves the
    # route-set comparison below decorative and makes the literal the real guard — the opposite of
    # what this example is for. It would also fail the day `/check-intent` is legitimately mounted
    # AND advertised, and "a mounted path is advertised" is not a violation of this contract.
    expect(advertised).not_to be_empty

    mounted = Rails.application.routes.routes.map { |route| route.path.spec.to_s.chomp("(.:format)") }
    expect(advertised - mounted).to be_empty
  end

  # No "Not available yet" claim may remain that the page can now answer. Every row the retired
  # roadmap panel listed has moved into `#answers-today`, so neither the warning nor the "Needs ..."
  # rationales may survive anywhere on the page. Non-vacuous: `find("#answers-today")` raises if the
  # panel did not render, and the positive text assertions prove it carries the moved rows.
  # @intent: {"entity": "GET /", "action": "retire the unavailable-answers claims", "behavior": "the page carries no Not available yet warning and none of the Needs rationales, while #answers-today holds the two rows that used to be listed as unavailable", "layer": "request"}
  it "no longer claims the per-area layer answers are unavailable" do
    page = Capybara.string(response.body)
    answers = page.find("#answers-today")

    expect(answers).to have_text("What already exists for this area, and at which layers?")
    expect(answers).to have_text("Which of those duplicates is safe to collapse?")
    expect(answers).to have_text("latest_run.spec_directories")

    expect(response.body).not_to include("Not available yet")
    expect(response.body).not_to include("Needs the stored per-test layer rolled up per area")
    expect(response.body).not_to include("Needs the per-area layer rollup above")
    expect(response.body).not_to include("Needs a dashboard panel over the clustering")
    expect(response.body).not_to include("stores nothing about individual tests")
  end

  # The redundancy row moved panels when the repository page started rendering the stored census:
  # it is an answer a signed-in person can read off the dashboard today, so it belongs in
  # `#answers-today`. Asserted on the node — a body-wide string match would pass with the row in
  # the wrong panel — beside the two rows that moved with the per-area layer counts.
  # @intent: {"entity": "GET /", "action": "place the redundancy answer", "behavior": "the which-groups-of-tests-are-redundant row sits inside #answers-today", "layer": "request"}
  it "lists the redundancy question as answered today" do
    page = Capybara.string(response.body)

    expect(page.find("#answers-today")).to have_text("Which groups of tests are potentially redundant?")
  end

  # The sidebar renders on this page too and said the engine "lands later" while the census shipped.
  # @intent: {"entity": "GET /", "action": "agree with the shipped clustering", "behavior": "the sidebar no longer says the duplicate-detection engine lands later", "layer": "request"}
  it "does not tell visitors the duplicate-detection engine lands later" do
    expect(Capybara.string(response.body)).to have_css("aside", text: "Early access")
    expect(response.body).not_to include("lands later")
  end
end
