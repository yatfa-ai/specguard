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

  # Both panels, asserted as nodes rather than as two strings anywhere in the body: the split is the
  # product change, so "one panel that happens to contain both titles" has to fail here.
  # @intent: {"entity": "GET /", "action": "render availability panels", "behavior": "the landing page returns 200 and carries two distinct nodes, #answers-today titled What SpecGuard answers today and #roadmap titled What SpecGuard is being built to answer", "layer": "request"}
  it "answers with the two availability panels" do
    expect(response).to have_http_status(:ok)

    page = Capybara.string(response.body)
    expect(page).to have_css("#answers-today", text: "What SpecGuard answers today")
    expect(page).to have_css("#roadmap", text: "What SpecGuard is being built to answer")
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

  # The warning is only worth anything if it sits WITH the rows it qualifies, so the window has to
  # be the panel itself. An earlier revision cut the window out of the response body with
  # `/What SpecGuard is being built to answer.*?\z/m` — lazy, but anchored at `\z`, so the engine is
  # forced to consume to the end of the document and the "panel" was really the whole tail of the
  # page. Verified: move the alert out of the panel and down the page and that version stays green,
  # because the string is still somewhere in the tail.
  #
  # The fix is not a better regex. Containment is a structural property, and a text window cannot
  # express it at any length — so this selects the panel's own DOM node (`id:` + `Capybara.string`,
  # the convention `repositories_spec.rb` uses) and the scoping is guaranteed by the parser rather
  # than by where the panel happens to sit on the page. `find` raises if `#roadmap` is missing, so
  # there is no vacuous path: the node has to render for the assertions to mean anything.
  # @intent: {"entity": "GET /", "action": "label unavailable answers", "behavior": "the #roadmap node says Not available yet and no longer claims it stores nothing about individual tests, a sentence false since the per-test write path shipped", "layer": "request"}
  it "labels the answers it cannot give yet as unavailable, on the panel that lists them" do
    panel = Capybara.string(response.body).find("#roadmap")

    expect(panel).to have_text("Not available yet")
    # This line used to assert the panel SAID "stores nothing about individual tests" — true when
    # written, and false from the moment `Ingest::ObservationRecorder` shipped the per-test write
    # path. Asserting the sentence is what held the falsehood green: the guard meant to catch the
    # drift was pinning it instead, so the storefront stayed wrong across a green suite.
    #
    # So what is pinned here is the CONTRACT rather than the copy. The panel is free to describe
    # what is still unbuilt however it likes; what it may not do is go on telling visitors that
    # per-test data is unstored, because it is stored, and both the JSON API and the repository
    # page read those rows. Deliberately uncounted, for the reason given at :50: a numeral here
    # would size a roster this spec never observes, so it would have to be revised the day another
    # key or panel is added — re-arming, one line below its own description of it, exactly the trap
    # :77-80 describes. Non-vacuous per the rule at :17-20 — `find` raises if `#roadmap` is missing
    # and the positive assertion above proves the panel rendered with its own content, so this
    # negative cannot pass on a blank page, a 500, or a deleted panel.
    expect(panel).not_to have_text("stores nothing about individual tests")
  end
end
