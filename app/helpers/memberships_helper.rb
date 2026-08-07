# frozen_string_literal: true

module MembershipsHelper
  # What each stored permission string actually buys, for the add-a-member checkbox grid. The raw
  # strings are the labels — they are what the members table renders and what the API will name — so
  # this is the sentence underneath, not a prettier name that would make the two pages disagree.
  #
  # `view` is described as the thing it does NOT decide, because it doesn't: membership itself grants
  # access to the repository (see RepositoryPolicy#can?), so a member with every box unticked can
  # still open it. Describing it as "can open the repository" would tell the owner that unticking it
  # locks the colleague out, which is the one thing it cannot do.
  #
  # `members.manage` names four doors because it opens four: the members page, the add form, the
  # edit form and Revoke — every action on MembershipsController gates on it. It described only the
  # members page and Revoke for a while, because nothing failed when the add and edit doors moved
  # onto it; repository_members_spec now reads this sentence back off the rendered form and
  # exercises all four in the same example, so the next such move cannot land silently. Do not name
  # a sibling permission string in any caption here: both forms assert their rendered body does NOT
  # contain `repo.delete` or `keys.manage` when the viewer may not grant them.
  PERMISSION_DESCRIPTIONS = {
    RepositoryMembership::VIEW => "Open the repository. Implied by membership — a member can " \
                                  "always reach it, ticked or not.",
    RepositoryMembership::KEYS_MANAGE => "See, mint and revoke this repository's API keys.",
    RepositoryMembership::MEMBERS_MANAGE => "See who can reach this repository, add and remove " \
                                            "members, and change what each one holds.",
    RepositoryMembership::REPO_DELETE => "Delete the repository, and every key, run and intent on it."
  }.freeze

  def permission_description(permission) = PERMISSION_DESCRIPTIONS.fetch(permission)

  # Both halves of the same disclosure: what the owner is told *before* they revoke someone, and
  # what they are told *after*. They live together because they make the same claim about the same
  # number, and a fix applied to only one of them is a contradiction the owner reads in sequence.
  #
  # Neither is reached unless the viewer holds `keys.manage` — `MembershipsController#keys_minted_by`
  # is the single gate, and it hands these a count of zero for anyone else, which is exactly the
  # "say nothing" path a member who minted nothing already takes.

  # The copy in the revoke confirm dialog.
  #
  # Revoking a membership deliberately does not touch the API keys that member minted (see
  # `User has_many :created_api_keys, dependent: :nullify`), so when there are any, the dialog has
  # to name that consequence *before* the click rather than let the owner discover it later. A
  # member who minted nothing keeps the original one-sentence question verbatim — a dialog that
  # mentions keys that do not exist is noise, and would train the owner to skim it.
  def revoke_confirmation(repository, handle, keys_minted)
    question = "Revoke #{handle}'s access to #{repository.github_full_name}?"
    return question if keys_minted.zero?

    keys, _verb, object = minted_keys_agreement(keys_minted)
    "#{question} The #{keys} they minted will keep authenticating until you revoke #{object}."
  end

  # The counterpart after the click, called from `MembershipsController#destroy`. It points at the
  # lever rather than pulling it: whether a departing colleague's CI key should survive them is the
  # owner's judgement, because only they know what it authenticates.
  def revoke_notice(handle, keys_minted)
    return "Revoked #{handle}'s access." if keys_minted.zero?

    keys, verb, object = minted_keys_agreement(keys_minted)
    "Revoked #{handle}'s access. #{keys} they minted #{verb} still live — " \
      "review #{object} in the API keys panel."
  end

  private

  # The one place number agreement is decided for both sentences above. `pluralize` covers the noun
  # phrase; the verb and the pronoun have no such helper, and hand-rolling those per call site is
  # how two surfaces quoting the same count drift into disagreeing about it.
  def minted_keys_agreement(count)
    singular = count == 1

    [pluralize(count, "API key"), singular ? "is" : "are", singular ? "it" : "them"]
  end
end
