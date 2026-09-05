# frozen_string_literal: true

# THE AGENT KEY'S ANSWER TO THE REPOSITORY QUESTIONS — the policy protocol
# `RepositoryAuthorization` asks (`owner?` / `member?` / `can?`), answered for a principal that is
# a CREDENTIAL rather than a person.
#
# ## Why a second policy class
#
# `RepositoryPolicy` is the single authorization question for a repository — "may this USER do this
# to it?" — and its whole computation is user-shaped: `owner?` compares `repository.user_id` to the
# person, and `member?` looks up the person's `RepositoryMembership` row. An `AgentApiKey` answers
# neither question from a person: its member? is "is this repository in the set the key carries",
# and its `can?` reads the key's own permission array. Folding that branch into
# `RepositoryPolicy` would put a credential principal inside a class whose contract says `user` —
# so the protocol is shared and the computation is not. `Api::BaseController#build_repository_
# policy` is the one place the two classes are chosen between, which is the same file where the
# credential classes are already the subject.
#
# ## The rules that ARE shared, and where each lives
#
#   * The capability vocabulary — `RepositoryPolicy::CAPABILITIES`, read through the same
#     `fetch`-that-raises discipline, so an unknown capability fails on the first request rather
#     than silently locking the agent out, exactly as it does for a person.
#   * Owner-only is a wall, not a permission. No agent key is ever the owner (`owner?` is `false`
#     by construction: a machine credential is not `repositories.user_id`), so `:owner`-gated
#     verbs — renaming — can never pass here, whatever the permission array holds.
#   * READ IS IMPLIED BY THE SET, as read is implied by membership in `RepositoryPolicy#can?`:
#     a key granted to a repository can open it, and storing `view` explicitly stays valid but is
#     not what decides. This is the same rule one principal one level over; it is restated here,
#     with the original's reasoning cited, rather than extracted — the two policies share the
#     rule and the vocabulary, not the principal, and an extraction would have to parameterize on
#     exactly the thing that differs.
#
# ## What is deliberately NOT here
#
# `grantable_permissions`. A person may hand a subset of what they hold to somebody else; an
# agent key is the END of a grant chain, not a link in one — minting further credentials is a
# person act, done from `/account` by the person who holds the rights. There is no delegation
# from a machine credential to answer for.
class AgentApiKeyPolicy
  attr_reader :key, :repository

  def initialize(key, repository)
    @key = key
    @repository = repository
  end

  # A machine credential is never the owner, so owner-only verbs (rename) can never pass —
  # stated rather than implied, on `RepositoryPolicy::OWNER_ONLY`'s own rule that the sentinel
  # must stay distinguishable from a permission nobody holds.
  def owner?
    false
  end

  # The key's repository set IS the read boundary: a repository outside it is answered 404
  # (via the concern's fork) indistinguishable from a nonexistent one.
  def member?
    key.covers?(repository)
  end

  def can?(capability)
    permission = RepositoryPolicy::CAPABILITIES.fetch(capability.to_sym) do
      raise ArgumentError, "unknown repository capability #{capability.inspect}"
    end

    return false unless member?
    return false if permission == RepositoryPolicy::OWNER_ONLY

    # Read is implied by set membership — see the class header. A key granted to a repository
    # can open it whether or not `view` sits in its permission array, exactly as a member can.
    return true if permission == RepositoryMembership::VIEW

    key.grants?(permission)
  end
end
