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

  # Shares an existing repository with a user who does not own it. `permissions` are the stored
  # strings, e.g. %w[view keys.manage] — see RepositoryMembership::PERMISSIONS.
  def create_membership(repository:, user:, permissions: [RepositoryMembership::VIEW])
    RepositoryMembership.create!(repository: repository, user: user, permissions: permissions)
  end

  # One ingested CI run. `total_specs_count` is the whole-suite figure ingestion derives from the
  # payload (every spec, annotated or not — see Ingest::Payload#test_run_attributes), so a run built
  # here with the default `annotated_specs_count: 0` is a faithful zero-annotation suite rather than
  # an impossible state. `commit_sha` is the only attribute TestRun validates.
  def create_test_run(repository:, commit_sha: "feedfacecafebabe", total_specs_count: 0, **attrs)
    repository.test_runs.create!(
      { commit_sha: commit_sha, total_specs_count: total_specs_count }.merge(attrs)
    )
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

  # --- /api/v1/ingest request bodies -------------------------------------------------------
  # Built as plain hashes rather than through the model, on purpose: these describe the *wire*
  # contract, and a builder that went through SpecIntent would encode the model's rules instead
  # of the envelope's — which is exactly the pair this endpoint has to keep separate.

  def ingest_payload(commit_sha: "a1b2c3d", specs: [annotated_spec], **attrs)
    { commit_sha: commit_sha, specs: specs }.merge(attrs)
  end

  # `behavior` is deliberately over the schema's 15-character floor; shorten it in a caller to
  # exercise the 400 path.
  #
  # The five fields beyond the envelope's own four — `id`, `spec_file_path`, `name`, `duration`,
  # `outcome` — are here because the shipped formatter sends nine fields per example and this
  # builder used to send four, which meant the whole ingest suite was green against a payload
  # shape no real client produces. Each is overridable per caller: `id` so a caller can put
  # several examples on one `(file_path, line_number)` the way a table-driven loop does,
  # `spec_file_path` so a caller can model a shared example group, `duration`/`outcome` so a
  # caller can send nulls the way the client does for an example that never ran.
  def annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12,
                     id: nil, spec_file_path: nil, name: nil, duration: 0.42, outcome: "passed",
                     **intent)
    {
      id: id || "./#{file_path}[1:#{line_number}]",
      spec_file_path: spec_file_path || file_path,
      file_path: file_path,
      line_number: line_number,
      name: name || "Invoice finalize locks the line items",
      duration: duration,
      outcome: outcome,
      status: "annotated",
      intent: {
        entity: "Invoice",
        action: "finalize",
        behavior: "locks the line items once the invoice is finalized",
        layer: "unit"
      }.merge(intent)
    }
  end

  def unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 12,
                       id: nil, spec_file_path: nil, name: nil, duration: 0.11, outcome: "passed")
    {
      id: id || "./#{file_path}[1:#{line_number}]",
      spec_file_path: spec_file_path || file_path,
      file_path: file_path,
      line_number: line_number,
      name: name || "User is valid with a handle",
      duration: duration,
      outcome: outcome,
      status: "unannotated",
      intent: nil
    }
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
