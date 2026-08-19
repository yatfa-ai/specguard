# frozen_string_literal: true

# THE ONE GATE EVERY WRITE OF `repositories.github_full_name` PASSES THROUGH, in a form that does
# not require a browser session.
#
# This is `RepositoriesController#save_with_verified_ownership` lifted out of the controller so a
# second caller can reach it. What it is NOT is a controller concern, and that distinction is the
# whole design:
#
#   * The web tree's gate reads `current_user`, `github_user_token` and `github_sources` — a person
#     holding a browser session, the credential in that session, and a live read made with it.
#   * `Api::BaseController` has none of the three. It exposes `current_api_user`, and it does so
#     under a name deliberately different from `current_user` because it is a different thing
#     arrived at a different way: a person named by a token, with no session anywhere near it.
#
# So a concern shared between the two trees would be a `NoMethodError` on every API request, and a
# shared `current_user` contract would be inventing a session where there is none. This takes its
# principal's evidence as a PARAMETER instead, and never says `current_user` at all.
#
# ## The verifier
#
# `verifier` answers one question — `#verdict_for(full_name) => InstallationRepositories::Verdict`
# — and there are two of them:
#
#   * {LiveVerifier} asks GitHub, now, with the user's session token. The web path.
#   * {GrantVerifier} reads a {GithubRegistrationGrant}: what GitHub said while a session still
#     held a token. The API path, which has no way to ask.
#
# Both return the SAME `Verdict`, built from the same `InstallationRepositories::MESSAGES`, so the
# two surfaces refuse in one vocabulary rather than two that drift.
#
# ## The order is load-bearing, and it is a SAVE rather than a `before_action`
#
# `repository_params` has two callers in the web tree — `#create` and `#update` — so a check bolted
# onto one action leaves the other writing the identity column unverified, and squatting would
# simply have moved from POST /repositories to PATCH /repositories/:id.
#
#   1. `valid?` FIRST, so a slug that is not `org/repo` — or one already registered — is refused
#      from the record's own rules and never becomes a GitHub round trip. It also runs
#      `normalize_full_name`, so step 2 asks about the value that would actually be STORED rather
#      than about whatever was pasted.
#   2. Ownership, and only when the identity is actually CHANGING. A rename form submitted
#      unchanged must not re-ask GitHub, and must not fail closed on a GitHub outage for a write
#      that changes nothing.
#   3. `save`.
#
# Fails closed at every step: a verdict that is not `verified?` — including "GitHub could not be
# reached" and "there is no grant to redeem" — does not save.
class RepositoryRegistration
  # The verdict this attempt collected, or `nil` when it never asked (the name was unchanged, or
  # the record was invalid on its own rules). Read by the web views, which offer an install button
  # instead of an error when the fix is installing the App rather than picking something else.
  attr_reader :verdict

  def initialize(repository:, verifier:)
    @repository = repository
    @verifier = verifier
    @verdict = nil
  end

  def save
    return false unless @repository.valid?
    return false unless verified_ownership?

    @repository.save
  end

  private

  # Records the refusal on the attribute it is ABOUT, so a form shows it under the field the person
  # has to change — exactly as a format or uniqueness failure does — and so an API response can
  # serve `errors.full_messages` without knowing which kind of refusal it is holding.
  def verified_ownership?
    return true unless @repository.will_save_change_to_github_full_name?

    @verdict = @verifier.verdict_for(@repository.github_full_name)
    return true if @verdict.verified?

    @repository.errors.add(:github_full_name, @verdict.message)
    false
  end
end
