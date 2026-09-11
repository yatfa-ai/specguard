# frozen_string_literal: true

require "rails_helper"

# SPGD-1056's pin on the fail-closed branch. `Api::BaseController` answers 401 to EVERYTHING when
# the controller declares no accepted credential — that direction is already guarded by
# `credential_seam_spec.rb`, which walks the route table and fails, by class name, on any routed
# subclass that declares nothing. What was unpinned is the BODY that branch renders: the
# file-header fence says a misconfiguration must not be distinguishable from a bad key by anyone
# holding one, so the fail-closed 401 has to stay byte-identical to the generic body every other
# non-revoked cause renders. There is no routed endpoint to hit over HTTP — by the guard's own
# design — so this exercises the branch directly on a declaration-less controller.
RSpec.describe Api::BaseController, type: :controller do
  controller(Api::BaseController) do
    def index
      render json: {}
    end
  end

  # @intent: { entity: "credential declaration", action: "fail closed with the generic body", behavior: "a controller that declares no credential answers the generic 401 body to a request carrying a token, byte-identical to every other non-revoked 401", layer: "controller" }
  it "renders the generic unauthorized body, byte-identical to every other non-revoked 401" do
    request.headers["Authorization"] = "Bearer sgu_not-a-key-anywhere"

    get :index

    expect(response).to have_http_status(:unauthorized)
    # Stated whole, exactly as `credential_seam_spec.rb`'s `generic_unauthorized_body` pins it:
    # the same bytes, asserted at the branch the seam spec cannot reach over HTTP.
    expect(response.parsed_body).to eq(
      "error" => "unauthorized",
      "message" => "A valid Bearer API key is required."
    )
  end
end
