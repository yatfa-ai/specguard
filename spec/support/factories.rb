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
  #
  # The record is resolved from where `create` redirected, never by re-querying the name that was
  # posted. Looking the name back up is the same order/identity-blind read this helper exists to
  # remove: `github_full_name` is unique across *all* users, so when another tenant already holds
  # the name, `create` renders 422 and a lookup hands back that tenant's repository — which then
  # 404s in `current_repository` and passes a `:not_found` example for the wrong reason. Reading
  # the redirect also survives `Repository#normalize_full_name` rewriting the posted value, and
  # turns a POST that never registered into an error here rather than a puzzle further down.
  def register_repository(full_name = "acme/billing-service")
    post repositories_path, params: { repository: { github_full_name: full_name } }

    unless response.redirect?
      raise "register_repository: expected RepositoriesController#create to redirect, got " \
            "#{response.status} for #{full_name.inspect}"
    end

    id = response.location[%r{/repositories/(\d+)}, 1]
    raise "register_repository: cannot read a repository id out of #{response.location.inspect}" if id.nil?

    Repository.find(id)
  end
end

RSpec.configure do |config|
  config.include Builders
  config.include RequestBuilders, type: :request
end
