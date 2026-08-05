# frozen_string_literal: true

require "rails_helper"

# The Phase-1 smoke test: the app boots and answers a request. If this is red, nothing else
# in the suite means anything.
RSpec.describe "Application smoke", type: :request do
  it "answers the health check" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end

  it "renders the signed-out landing page through the inherited design system" do
    get "/"

    expect(response).to have_http_status(:ok)
    # Proves the layout, the token system and the UI::* component library all render.
    expect(response.body).to include('data-theme="dark"')
    expect(response.body).to include("bg-app-background")
    expect(response.body).to include("SpecGuard")
  end
end
