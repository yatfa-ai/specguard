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
# Nothing is any more. `grantable_permissions` USED to be the entry on this list: the class header
# argued that an agent key is the END of a grant chain, not a link in one, because minting further
# credentials was a person act. SPGD-973 reverses exactly that much, deliberately amending
# SPGD-952's read-only stance: an agent key holding `members.manage` may now edit members, and
# `keys.manage` may mint `sgk_` keys — so a key that can act on a grant chain needs the same
# "what may this principal hand out" bound the person policy has always answered. The bound is the
# key's OWN permission set (plus the `view` that set membership implies — `can?`'s rule), never
# the owner's rights: the owner bounded the key at mint, and the key bounds what it grants now.
# `owner?` stays `false` by construction, so renaming stays a person verb and `:owner` never
# enters any grantable set here.
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

  # What this key may hand to somebody else — the agent credential's own grant bound, derived
  # from `can?` on the same rule `RepositoryPolicy#grantable_permissions` derives the person's
  # from, so "what a grant may contain" stays one rule across memberships, agent-key mints and
  # member grants made BY an agent key. It is the key's OWN permission set (membership itself
  # contributing `view`, exactly as it does for a person), read in-memory — `can?` asks
  # `covers?` and `grants?`, neither of which queries — so the bound a request is measured
  # against costs nothing on top of the authorization the action already paid for.
  #
  # This is the SECOND bound a member write under an agent credential passes through. The FIRST
  # is the mint-time one, re-stamped by naming the owner as the grantor
  # (`Api::BaseController#attributed_user`), which keeps `RepositoryMembership#grantor_holds_
  # every_granted_permission` measuring the OWNER. Neither implies the other: the owner bound is
  # computed against the owner's rights and the key bound against the key's set, and a key is
  # narrower than its owner by construction — which is exactly the widening
  # `AgentApiKey#owner_holds_every_granted_permission` forbids at mint, refused here at use with
  # a message in the same register as both.
  def grantable_permissions
    RepositoryMembership::PERMISSIONS.select do |permission|
      can?(RepositoryPolicy::CAPABILITY_BY_PERMISSION.fetch(permission))
    end
  end
end
