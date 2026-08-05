# frozen_string_literal: true

# Deliberately plain builders rather than a factory gem — the Phase-1 schema is four tables and
# a fixture DSL would be more machinery than the models justify.
module Builders
  def create_user(github_uid: "1001", github_handle: "octocat")
    User.create!(github_uid: github_uid, github_handle: github_handle)
  end

  def create_repository(user: create_user, github_full_name: "acme/billing-service")
    user.repositories.create!(github_full_name: github_full_name)
  end

  def create_spec_intent(repository:, file_path: "spec/models/invoice_spec.rb", line_number: 12, **attrs)
    repository.spec_intents.create!(
      {
        file_path: file_path,
        line_number: line_number,
        entity: "Invoice",
        action: "finalize",
        behavior: "locks the line items",
        layer: "unit"
      }.merge(attrs)
    )
  end
end

# Builders that go through the app over HTTP rather than straight to the model, so they are only
# meaningful where a request is available.
module RequestBuilders
  # Registers a repository the way a user does — through RepositoriesController#create. Kept as a
  # real round-trip on purpose: swapping it for `create_repository` would silently drop the callers'
  # coverage of the create action.
  def register_repository(full_name = "acme/billing-service")
    post repositories_path, params: { repository: { github_full_name: full_name } }
    Repository.find_by!(github_full_name: full_name)
  end
end

RSpec.configure do |config|
  config.include Builders
  config.include RequestBuilders, type: :request
end
