# frozen_string_literal: true

# Base class for every machine-facing endpoint.
#
# Auth is a Bearer API key: `Authorization: Bearer sgk_…`. The token is hashed and looked up on the
# unique digest index, so a valid key resolves its repository in one indexed read; anything else is
# a flat 401 with no detail about why.
class Api::BaseController < ActionController::API
  before_action :authenticate_api_key!

  private

  # Private on purpose: a public method on a controller is a routable action.
  attr_reader :current_api_key, :current_repository

  def authenticate_api_key!
    @current_api_key = ApiKey.authenticate(bearer_token)

    return render_unauthorized if @current_api_key.nil?

    @current_repository = @current_api_key.repository
    @current_api_key.touch_last_used!
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    match = header.match(/\ABearer\s+(?<token>.+)\z/i)

    match && match[:token].strip
  end

  def render_unauthorized
    render json: { error: "unauthorized", message: "A valid Bearer API key is required." },
           status: :unauthorized
  end
end
