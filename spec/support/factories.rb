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

RSpec.configure { |config| config.include Builders }
