# frozen_string_literal: true

# WHICH REPOSITORIES THE PERSON BEHIND THIS TOKEN MAY OPEN — the first endpoint that answers to a
# `sgu_` user key, and the one endpoint this slice ships to prove that credential works.
#
# ## Why this is not an action on `Api::V1::RepositoriesController`
#
# That controller serves `GET /api/v1/repository`, singular, which answers to a `sgk_` repository
# key and is a report about the ONE repository that key names. This answers to a different
# credential and returns a set. Two surfaces that share a noun and nothing else: the same class
# would carry two `accepts_*_credential` declarations, which the seam has no way to express and no
# reason to.
#
# ## The authorization rule is not reinvented here
#
# `Repository.accessible_by` is this application's read-side boundary — owned UNION shared-through-a
# -membership — and it lives on the model so that every surface asking "which repositories may this
# person see" asks the same place. The dashboard's repository list reads it; so does this. A
# repository the person neither owns nor is a member of is not filtered out of this response, it
# never enters it, so nothing here can leak the fact that it exists.
#
# ## Ordering
#
# `github_full_name` — stable, and the only column on this list a client could page or diff against
# without SpecGuard promising an id ordering it has not designed. `accessible_by` returns a relation
# precisely so a caller can chain this without landing in the scope (see the note there).
class Api::V1::UserRepositoriesController < Api::BaseController
  # THIS ENDPOINT NEEDS A PERSON. A `sgk_` repository key resolves no user and gets 401 — which is
  # the direction of the seam that is easy to get wrong, because a repository key IS a valid
  # credential and this list would otherwise have to invent an answer for one. See
  # `Api::BaseController`.
  accepts_user_credential

  def index
    repositories = Repository.accessible_by(current_api_user).order(:github_full_name)

    render json: {
      repositories: repositories.map { |repository| serialize(repository) }
    }
  end

  private

  # Deliberately the same four fields, under the same names, that `Api::V1::RepositoriesController`
  # serves in its own `repository` block. A client that has read one of them knows how to read the
  # other, and the two cannot drift into naming the same facts differently.
  #
  # `role` is the one field this surface adds, and it earns its place: the list mixes repositories
  # the person owns with repositories somebody shared with them, and no other field distinguishes
  # them. Without it a client cannot tell which of these it may expect to administer once the
  # mutating endpoints land, and would have to guess.
  def serialize(repository)
    {
      id: repository.id,
      full_name: repository.github_full_name,
      name: repository.name,
      registered_at: repository.created_at.iso8601,
      role: repository.user_id == current_api_user.id ? "owner" : "member"
    }
  end
end
