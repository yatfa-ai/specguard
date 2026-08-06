# frozen_string_literal: true

# The Phase-1 protected endpoint. Its only job is to prove the credential works: a valid key
# resolves exactly one repository, and the client can echo it back to confirm which one.
class Api::V1::RepositoriesController < Api::BaseController
  def show
    render json: {
      repository: {
        id: current_repository.id,
        full_name: current_repository.github_full_name,
        name: current_repository.name,
        registered_at: current_repository.created_at.iso8601
      },
      api_key: {
        name: current_api_key.name,
        last_used_at: current_api_key.last_used_at&.iso8601
      }
    }
  end
end
