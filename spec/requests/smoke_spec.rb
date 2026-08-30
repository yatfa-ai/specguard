# frozen_string_literal: true

require "rails_helper"

# The Phase-1 smoke test: the app boots and answers a request. If this is red, nothing else
# in the suite means anything.
RSpec.describe "Application smoke", type: :request do
  # @intent: {"entity": "GET /up", "action": "answer health check", "behavior": "A GET to /up answers 200 OK, proving the app booted and can serve a request at all.", "layer": "request"}
  it "answers the health check" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end

  # @intent: {"entity": "GET /", "action": "render landing page", "behavior": "GET / returns 200 and renders the signed-out root through the inherited design system, with data-theme dark, the bg-app-background class, and the SpecGuard name in the body.", "layer": "request"}
  it "renders the signed-out landing page through the inherited design system" do
    get "/"

    expect(response).to have_http_status(:ok)
    # Proves the layout, the token system and the UI::* component library all render.
    expect(response.body).to include('data-theme="dark"')
    expect(response.body).to include("bg-app-background")
    expect(response.body).to include("SpecGuard")
  end
end
