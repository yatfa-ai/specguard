# frozen_string_literal: true

module MembershipsHelper
  # What each stored permission string actually buys. ONE glossary, read by both ends of a grant:
  # the owner ticking the box on the member forms, and the colleague reading the "Your access" row
  # on repositories#show to find out what they were handed. Two copies would be two sentences about
  # one permission that can drift, and the person on the receiving end is precisely the one with no
  # way to notice they had — so the shared derivation is extracted here rather than duplicated.
  #
  # The raw strings are the labels — they are what the members table renders, what the checkbox grid
  # prints above each caption, what the "Your access" row lists and what the API will name — so this
  # is the sentence underneath, not a prettier name that would make the pages disagree.
  #
  # Kept to what the permission LETS SOMEBODY DO, in the second person, so one sentence works read
  # as "tick this and they may…" and as "you may…". Anything true only beside a checkbox belongs in
  # `GRANT_NOTES` below, not here.
  #
  # `members.manage` names four doors because it opens four: the members page, the add form, the
  # edit form and Revoke — every action on MembershipsController gates on it. It described only the
  # members page and Revoke for a while, because nothing failed when the add and edit doors moved
  # onto it; repository_members_spec now reads this sentence back off the rendered form and
  # exercises all four in the same example, so the next such move cannot land silently. Do not name
  # a sibling permission string in any caption here: both forms assert their rendered body does NOT
  # contain `repo.delete` or `keys.manage` when the viewer may not grant them.
  PERMISSION_DESCRIPTIONS = {
    RepositoryMembership::VIEW => "Open the repository.",
    RepositoryMembership::KEYS_MANAGE => "See, mint and revoke this repository's API keys.",
    RepositoryMembership::MEMBERS_MANAGE => "See who can reach this repository, add and remove " \
                                            "members, and change what each one holds.",
    RepositoryMembership::REPO_DELETE => "Delete the repository, and every key, run and intent on it."
  }.freeze

  # The half of a caption that means something only to the person doing the ticking, split out of
  # the glossary above rather than the glossary being reworded per surface.
  #
  # `view` is the whole of it, and it is here because that box does not decide what it appears to
  # decide: membership itself grants access to the repository (see RepositoryPolicy#can?), so a
  # member with every box unticked can still open it. An owner not told that reads unticking it as
  # locking the colleague out, which is the one thing it cannot do — so the note has to reach them.
  # It must NOT reach the colleague: "ticked or not" is about a checkbox they never see, and how
  # their access arrived does not change what it is.
  GRANT_NOTES = {
    RepositoryMembership::VIEW => "Implied by membership — a member can always reach it, ticked or not."
  }.freeze

  # What the permission buys, said the same way whoever is reading.
  def permission_description(permission) = PERMISSION_DESCRIPTIONS.fetch(permission)

  # The caption printed under each checkbox on the add and edit member forms (`_permission_fields`)
  # — the shared sentence plus the grant-side note, when there is one.
  def grant_permission_description(permission)
    [permission_description(permission), GRANT_NOTES[permission]].compact.join(" ")
  end

  # The colleague's end of that same glossary: the sentence under the "Your access" row on
  # repositories#show, saying what the viewer holds in the words the grant side uses.
  #
  # `permissions` is `RepositoryPolicy#grantable_permissions`, which derives the set from `can?`
  # rather than reading `membership.permissions`. That is what makes this true for a row storing
  # only "keys.manage": membership itself grants view, so the first thing they read is still "Open
  # the repository" — the effective answer, not the stored one. It also fixes the order, since that
  # reader selects over `RepositoryMembership::PERMISSIONS`, so two members holding the same set
  # read the same sentence whatever order their rows happen to store.
  #
  # The closing sentence is the reason the row exists at all. repositories#show renders no control
  # its viewer does not hold — correct, and it leaves ABSENCE as the only signal, which cannot tell
  # "never granted" from "granted but broken" from "SpecGuard does not do this". Naming the set as
  # complete turns that absence into something stated. It renders in every case, including for a
  # member holding all four: it is a claim about the list above it, not about how long the list is.
  def held_access_description(permissions)
    closing = "That is everything you hold here — a control this page does not show you is one " \
              "you have not been granted, not one that is broken or missing."

    permissions.map { |permission| permission_description(permission) }.push(closing).join(" ")
  end

  # Both halves of the same disclosure: what the owner is told *before* they revoke someone, and
  # what they are told *after*. They live together because they make the same claim about the same
  # number, and a fix applied to only one of them is a contradiction the owner reads in sequence.
  #
  # Neither is reached unless the viewer holds `keys.manage` — `MintedKeyCounts#keys_minted_by`
  # (the extracted reader, shared with the Leave surface below) is the single gate, and it hands
  # these a count of zero for anyone else, which is exactly the "say nothing" path a member who
  # minted nothing already takes.

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

  # The leaver's own halves of the same disclosure — the Leave dialog on repositories#show, and
  # the flash after it. They exist because leaving is `#destroy`'s self-revoke arm made
  # self-served: the act is the same (a membership row destroyed, API keys untouched), so the
  # warnings have to be the same act's warnings, revoiced in the second person for the one person
  # whose access it is.
  #
  # Unlike the revoke pair, whose callers pre-gate on `keys.manage`, `leave_confirmation` is
  # reached by every member of a repository — the control is not gated, because ending your own
  # access is not a permission — but `keys_minted_by` remains the single gate and hands a count of
  # zero to anyone without `keys.manage`, so a `view`-only leaver's dialog and notice mention keys
  # not at all. That is not merely tolerated but required: a member who minted nothing is being
  # warned about keys that do not exist, and the viewer who may not know the number is the one the
  # gate exists to keep ignorant.
  #
  # Both go through `minted_keys_agreement` — "two surfaces quoting the same count" is now four,
  # and they cannot drift about it.

  # The copy in the Leave confirm dialog. Two differences from the revoke question, both
  # substantive rather than phrasing: the consequence is immediate and unilateral (no owner is
  # asked), and the lever changes hands — "until an owner revokes them", not "until you revoke
  # them", because the moment the row is gone the leaver can no longer open the panel the revoke
  # pair points at. Telling them to review a panel they just 404'd themselves out of would be the
  # affordance-that-lands-nowhere shape `keys_minted_by`'s gate exists to prevent.
  def leave_confirmation(repository, keys_minted)
    question = "Leave #{repository.github_full_name}? You will lose access immediately, and only " \
               "an owner can add you back."
    return question if keys_minted.zero?

    keys, _verb, object = minted_keys_agreement(keys_minted)
    "#{question} The #{keys} you minted will keep authenticating until an owner revokes #{object}."
  end

  # The counterpart after the click, called from `MembershipsController#leave`. It keeps, verbatim,
  # the sentence `#destroy`'s self-revoke arm has always shown — leaving and being revoked are the
  # same end state and must read as one sentence — and adds the same keys-are-still-live line the
  # owner's revoke notice carries, rerouted at the person who now holds the only lever there is:
  # asking an owner to revoke them, from outside a repository they can no longer open.
  def leave_notice(repository, keys_minted)
    base = "You no longer have access to #{repository.github_full_name}."
    return base if keys_minted.zero?

    keys, verb, object = minted_keys_agreement(keys_minted)
    "#{base} The #{keys} you minted #{verb} still live — ask an owner to revoke #{object} in the " \
      "repository's API keys panel."
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
