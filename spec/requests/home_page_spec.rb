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

  it "answers with the two availability panels" do
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("What SpecGuard answers today")
    expect(response.body).to include("What SpecGuard is being built to answer")
  end

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
  it "names no api/v1 path that the router does not serve" do
    advertised = response.body.scan(%r{/api/v1/[a-z0-9_-]+}).uniq

    # Without this the example passes on a page that mentions no endpoint at all — including a page
    # that failed to render.
    expect(advertised).to match_array(%w[/api/v1/ingest /api/v1/repository])

    mounted = Rails.application.routes.routes.map { |route| route.path.spec.to_s.chomp("(.:format)") }
    expect(advertised - mounted).to be_empty
  end

  it "labels the answers it cannot give yet as unavailable, on the panel that lists them" do
    roadmap_panel = response.body[/What SpecGuard is being built to answer.*?\z/m]

    expect(roadmap_panel).to be_present
    expect(roadmap_panel).to include("Not available yet")
    # The claim that dates fastest: it is true only while nothing writes a per-test row. Whoever
    # builds that write path is meant to land here.
    expect(roadmap_panel).to include("stores nothing about individual tests")
  end
end
